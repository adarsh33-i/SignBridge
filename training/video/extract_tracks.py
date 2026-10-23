#!/usr/bin/env python3
"""Turn signer clips into normalised hand-landmark tracks.

Each clip becomes one `.npz` holding a fixed-width feature sequence, the
timestamps it was sampled at, and the clip metadata. The features are the same
21-point hand skeleton MediaPipe exposes on Android, expressed in a body frame
so the track does not depend on where the signer stood or how far the camera
was:

    x, y        landmark in shoulder-width units, origin at shoulder midpoint
    spread      mean fingertip distance from the wrist, hand-size normalised
    roll        palm-rotation unit vector (sin, cos)
    present     1.0 when this hand slot was detected in this frame

With `--no-pose` there are no shoulders, which is the situation the phone is in:
the origin becomes the mean wrist and the unit of length 2.6 * the mean
wrist-to-middle-knuckle of the hands that pass the palm sanity check. Pass that
check on a single hand's own proportions, so the frame stays camera-distance
independent either way.

Per hand: 21 * 2 + 4 = 46 floats, two hands = 92, plus pose-present and
detected-hand-count = 94 floats per frame.

    python3 training/video/extract_tracks.py --jobs 6 --delete-after
"""

from __future__ import annotations

import argparse
import json
import multiprocessing as mp
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from video_corpus import MIN_PALM_FRACTION

VIDEO_DIR = Path(__file__).resolve().parent
MODELS = VIDEO_DIR / "models"
DATA = VIDEO_DIR / "data"
CLIPS = DATA / "clips"
TRACKS = DATA / "tracks"
INDEX = DATA / "tracks_index.jsonl"
REJECTS = DATA / "tracks_rejected.jsonl"

TARGET_FPS = 10.0
MAX_FRAMES = 90
MIN_TRACKED_FRAMES = 4
FEATURES_PER_FRAME = 94
WRIST, INDEX_MCP, MIDDLE_MCP, PINKY_MCP, THUMB_TIP = 0, 5, 9, 17, 4
FINGERTIPS = (8, 12, 16, 20)
SHOULDER_L, SHOULDER_R = 11, 12
MODEL_BASE = "https://storage.googleapis.com/mediapipe-models"
MODEL_URLS = {
    "hand_landmarker": f"{MODEL_BASE}/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task",
    "pose_landmarker_lite": (
        f"{MODEL_BASE}/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task"
    ),
}


def ensure_models() -> None:
    """Fetch the free on-device MediaPipe models if this is a clean clone."""
    import urllib.request

    MODELS.mkdir(parents=True, exist_ok=True)
    for name, url in MODEL_URLS.items():
        target = MODELS / f"{name}.task"
        if target.is_file() and target.stat().st_size > 1_000_000:
            continue
        print(f"downloading {name}")
        with urllib.request.urlopen(url, timeout=120) as response:
            target.write_bytes(response.read())


@dataclass(frozen=True)
class ClipResult:
    key: str
    ok: bool
    reason: str
    frames: int
    tracked: int
    width: int
    height: int
    src_fps: float


def _make(kind: str):
    """A fresh landmarker per clip: VIDEO mode keeps tracking state and rejects
    timestamps that do not increase, so instances cannot be shared across clips."""
    from mediapipe.tasks import python as mp_python
    from mediapipe.tasks.python import vision

    model_name = "hand_landmarker" if kind == "hand" else "pose_landmarker_lite"
    base = mp_python.BaseOptions(model_asset_path=str(MODELS / f"{model_name}.task"))
    if kind == "hand":
        return vision.HandLandmarker.create_from_options(
            vision.HandLandmarkerOptions(
                base_options=base,
                running_mode=vision.RunningMode.VIDEO,
                num_hands=2,
                min_hand_detection_confidence=0.3,
                min_tracking_confidence=0.2,
            )
        )
    return vision.PoseLandmarker.create_from_options(
        vision.PoseLandmarkerOptions(
            base_options=base,
            running_mode=vision.RunningMode.VIDEO,
            min_pose_detection_confidence=0.3,
        )
    )


def _palm(hand) -> float:
    return float(np.hypot(hand[MIDDLE_MCP].x - hand[WRIST].x, hand[MIDDLE_MCP].y - hand[WRIST].y))


def _span(hand) -> float:
    wrist = hand[WRIST]
    return float(np.mean([np.hypot(hand[t].x - wrist.x, hand[t].y - wrist.y) for t in FINGERTIPS]))


def _body_frame(pose_landmarks, slots):
    """Return (centre, scale, present) for this frame, or None when nothing anchors it.

    `slots` is the left and right hand already, either of which may be None, and
    `present` says which of them may be written into the row. With pose the
    shoulders anchor every detected hand. Without them the origin is the mean of
    the wrists and the unit of length is 2.6 * the mean palm of exactly the hands
    that get written, because a hand dropped from the row must not quietly set the
    ruler for the one that stays. A hand whose middle knuckle collapsed onto its
    wrist is dropped: the test compares two distances inside that one hand, so it
    says the same thing at any camera distance. `video_corpus.wrist_frame` applies
    the same rule to tracks extracted here with pose, so both branches describe
    the one frame the phone can build.
    """
    detected = [hand is not None for hand in slots]
    if pose_landmarks:
        left = pose_landmarks[SHOULDER_L]
        right = pose_landmarks[SHOULDER_R]
        centre = np.array([(left.x + right.x) / 2, (left.y + right.y) / 2])
        width = float(np.hypot(left.x - right.x, left.y - right.y))
        if width > 0.02:
            return centre, width, detected
    palms = [_palm(hand) if hand is not None else 0.0 for hand in slots]
    present = [
        ok and palm > 0 and palm >= MIN_PALM_FRACTION * _span(hand)
        for ok, hand, palm in zip(detected, slots, palms)
    ]
    if not any(present):
        return None
    wrists = [np.array([hand[WRIST].x, hand[WRIST].y]) for hand, ok in zip(slots, present) if ok]
    scale = 2.6 * float(np.mean([palm for palm, ok in zip(palms, present) if ok]))
    return np.mean(wrists, axis=0), scale, present


def _slots(hands, handedness) -> list:
    """Place detected hands in their left and right slot, last report winning."""
    slots: list = [None, None]
    for hand, label in zip(hands, handedness):
        slots[0 if label.lower().startswith("left") else 1] = hand
    return slots


def _hand_block(hand, centre, scale, slot_present: float) -> np.ndarray:
    block = np.zeros(46, dtype=np.float32)
    if hand is None:
        return block
    points = np.array([[lm.x, lm.y] for lm in hand], dtype=np.float32)
    normalised = (points - centre.astype(np.float32)) / np.float32(scale)
    block[:42] = normalised.reshape(-1)
    wrist = normalised[WRIST]
    tips = normalised[list(FINGERTIPS)]
    hand_scale = float(np.hypot(*(normalised[MIDDLE_MCP] - wrist))) or 1e-3
    block[42] = float(np.mean(np.linalg.norm(tips - wrist, axis=1))) / hand_scale
    across = normalised[INDEX_MCP] - normalised[PINKY_MCP]
    angle = float(np.arctan2(across[1], across[0]))
    block[43] = np.sin(angle)
    block[44] = np.cos(angle)
    block[45] = slot_present
    return block


def extract(
    clip: Path, use_pose: bool, dtype=np.float16
) -> tuple[np.ndarray, np.ndarray, ClipResult] | ClipResult:
    import cv2
    import mediapipe as mp

    key = f"{clip.parent.name}/{clip.name}"
    capture = cv2.VideoCapture(str(clip))
    src_fps = capture.get(cv2.CAP_PROP_FPS) or 30.0
    width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
    step = max(1, int(round(src_fps / TARGET_FPS)))
    hand_marker = _make("hand")
    pose_marker = _make("pose") if use_pose else None

    rows: list[np.ndarray] = []
    stamps: list[int] = []
    tracked = 0
    frame_index = 0
    while frame_index < MAX_FRAMES * step:
        ok, image_bgr = capture.read()
        if not ok:
            break
        if frame_index % step == 0:
            rgb = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2RGB)
            stamp = int(frame_index * 1000 / src_fps)
            image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
            hands: list = []
            handedness: list = []
            hand_result = hand_marker.detect_for_video(image, stamp)
            if hand_result is not None:
                hands = list(hand_result.hand_landmarks)
                handedness = [entry[0].category_name for entry in hand_result.handedness]
            pose_points = None
            pose_present = 0.0
            if pose_marker is not None:
                pose_result = pose_marker.detect_for_video(image, stamp)
                if pose_result and pose_result.pose_landmarks:
                    pose_points = pose_result.pose_landmarks[0]
                    pose_present = 1.0
            slots = _slots(hands, handedness)
            frame = _body_frame(pose_points, slots)
            row = np.zeros(FEATURES_PER_FRAME, dtype=np.float32)
            if frame is not None:
                centre, scale, usable = frame
                present = [1.0 if ok else 0.0 for ok in usable]
                left_block = _hand_block(slots[0] if usable[0] else None, centre, scale, present[0])
                right_block = _hand_block(slots[1] if usable[1] else None, centre, scale, present[1])
                row[:46] = left_block
                row[46:92] = right_block
                row[92] = pose_present
                row[93] = float(sum(present))
                tracked += 1 if sum(present) else 0
            rows.append(row)
            stamps.append(stamp)
        frame_index += 1
    capture.release()
    hand_marker.close()
    if pose_marker is not None:
        pose_marker.close()

    if len(rows) < MIN_TRACKED_FRAMES or tracked < MIN_TRACKED_FRAMES:
        return ClipResult(key, False, "no usable hand track", len(rows), tracked, width, height, src_fps)
    return np.asarray(rows, dtype=dtype), np.asarray(stamps, dtype=np.int32), ClipResult(
        key, True, "", len(rows), tracked, width, height, src_fps
    )


def worker(clip: Path) -> ClipResult:
    try:
        outcome = extract(clip, worker.use_pose, worker.dtype)
    except Exception as error:  # a broken clip must not stop the corpus
        return ClipResult(
            f"{clip.parent.name}/{clip.name}", False, f"{type(error).__name__}: {error}", 0, 0, 0, 0, 0.0
        )
    if isinstance(outcome, ClipResult):
        return outcome
    features, stamps, result = outcome
    worker.tracks.mkdir(parents=True, exist_ok=True)
    target = worker.tracks / f"{result.key.replace('/', '__')[:-4]}.npz"
    # Write-then-rename: train_match.py reads this directory while it is still
    # being filled, and a half-written zip raises in the middle of a run.
    partial = target.with_suffix(".part.npz")
    np.savez_compressed(
        partial,
        features=features,
        stamps=stamps,
        key=np.array(result.key),
        fps=np.array(TARGET_FPS),
    )
    partial.replace(target)
    if worker.delete_after:
        clip.unlink(missing_ok=True)
    return result


def _init(use_pose: bool, delete_after: bool, tracks: Path, dtype=np.float16) -> None:
    """Everything the workers need arrives as an argument.

    macOS starts pools with `spawn`, so a module global reassigned in main()
    would still hold its import-time value in the child - which quietly wrote
    variant tracks over the real corpus.
    """
    worker.use_pose = use_pose
    worker.delete_after = delete_after
    worker.tracks = Path(tracks)
    worker.dtype = dtype


def pending_clips(langs: tuple[str, ...], limit: int) -> list[Path]:
    done = set()
    if INDEX.is_file():
        for line in INDEX.read_text(encoding="utf-8").splitlines():
            if line.strip():
                done.add(json.loads(line)["key"])
    todo: list[Path] = []
    for lang in langs:
        root = CLIPS / lang
        if not root.is_dir():
            continue
        for clip in sorted(root.glob("*.mp4")):
            key = f"{lang}/{clip.name}"
            if key in done:
                continue
            todo.append(clip)
            if limit and len(todo) >= limit:
                return todo
    return todo


def main(argv: list[str] | None = None) -> int:
    global TRACKS, INDEX, REJECTS, CLIPS

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=max(1, (mp.cpu_count() or 4) // 2))
    parser.add_argument("--lang", choices=("asl", "isl", "both"), default="both")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--no-pose", action="store_true", help="skip the body frame")
    parser.add_argument(
        "--float32",
        action="store_true",
        help="store float32 features; only for a precision check, the corpus ships as float16",
    )
    parser.add_argument("--delete-after", action="store_true", help="unlink clips once extracted")
    parser.add_argument(
        "--tracks-dir",
        type=Path,
        default=None,
        help="write tracks and index here instead of data/tracks (for a second variant)",
    )
    parser.add_argument(
        "--clips-dir",
        type=Path,
        default=None,
        help="read clips from here instead of data/clips",
    )
    args = parser.parse_args(argv)
    dtype = np.float32 if args.float32 else np.float16

    if args.tracks_dir is not None:
        TRACKS = args.tracks_dir
        INDEX = TRACKS.parent / f"{TRACKS.name}_index.jsonl"
        REJECTS = TRACKS.parent / f"{TRACKS.name}_rejected.jsonl"
    if args.clips_dir is not None:
        CLIPS = args.clips_dir

    langs = ("asl", "isl") if args.lang == "both" else (args.lang,)
    clips = pending_clips(langs, args.limit)
    print(f"{len(clips)} clips to extract with {args.jobs} workers, pose={'off' if args.no_pose else 'on'}")
    if not clips:
        return 0

    TRACKS.mkdir(parents=True, exist_ok=True)
    ensure_models()
    started = time.perf_counter()
    ok = failed = frames_total = 0
    index_handle = INDEX.open("a", encoding="utf-8")
    reject_handle = REJECTS.open("a", encoding="utf-8")
    with mp.Pool(args.jobs, initializer=_init, initargs=(not args.no_pose, args.delete_after, TRACKS, dtype)) as pool:
        for count, result in enumerate(pool.imap_unordered(worker, clips, chunksize=4), 1):
            if result.ok:
                ok += 1
                frames_total += result.frames
                index_handle.write(json.dumps(vars(result)) + "\n")
            else:
                failed += 1
                reject_handle.write(json.dumps(vars(result)) + "\n")
            index_handle.flush()
            reject_handle.flush()
            if count % 200 == 0 or count == len(clips):
                rate = count / max(time.perf_counter() - started, 1e-6)
                print(f"  {count}/{len(clips)} clips, {ok} tracks, {failed} rejected, {rate:.1f} clips/s")
    index_handle.close()
    reject_handle.close()

    elapsed = time.perf_counter() - started
    print(
        f"done: {ok} tracks ({frames_total} frames, "
        f"{frames_total / max(ok, 1):.0f}/clip) and {failed} rejected in {elapsed / 60:.1f} min"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
