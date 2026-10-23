"""Landmark-track dataset: loading, windowing, augmentation and the gloss bank.

One clip per gloss is the shape of this corpus, which rules out a softmax
classifier: an 11k-way head trained on one example per class memorises the clip
instead of learning the sign. What does work with one example per class is a
retrieval bank — every gloss keeps a normalised reference track and a query is
answered by nearest neighbour in a learned embedding space.

Training and the device export both read this module, so the feature layout
cannot drift between them.

Feature layout, 94 floats per frame (see extract_tracks.py for how they are
measured):

    0..45    left hand: 21 * (x, y) in shoulder units, then spread, roll sin,
             roll cos, present
    46..91   right hand, same
    92       pose landmarks were available for this frame
    93       hands detected in this frame
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path

import numpy as np

VIDEO_DIR = Path(__file__).resolve().parent
DATA = VIDEO_DIR / "data"
TRACKS = DATA / "tracks"
MANIFEST = VIDEO_DIR.parents[1] / "assets" / "signs" / "manifest.json"

FEATURES_PER_FRAME = 94
WINDOW = 16
WINDOW_STRIDE = 8
HAND_BLOCKS = (slice(0, 46), slice(46, 92))
COORDS = 42
PRESENT = (45, 91)
POSE_PRESENT = 92
HAND_COUNT = 93


@dataclass(frozen=True)
class Track:
    key: str
    features: np.ndarray
    stamps: np.ndarray

    @property
    def length(self) -> int:
        return int(self.features.shape[0])

    def tracked_frames(self) -> int:
        return int(np.count_nonzero(self.features[:, PRESENT].sum(axis=1) > 0))


@dataclass(frozen=True)
class Sample:
    """A fixed-length window plus a mask marking the rows that are real data."""

    features: np.ndarray
    mask: np.ndarray

    @staticmethod
    def from_block(block: np.ndarray, length: int = WINDOW) -> "Sample":
        rows = min(int(block.shape[0]), length)
        features = np.zeros((length, FEATURES_PER_FRAME), dtype=np.float32)
        features[:rows] = block[:rows]
        mask = np.zeros(length, dtype=np.float32)
        mask[:rows] = 1.0
        return Sample(features=features, mask=mask)


def load_gloss_labels(manifest_path: Path = MANIFEST) -> dict[str, list[str]]:
    """clip key -> gloss labels, so `asl/hello.mp4` also answers to `hi`."""
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    labels: dict[str, set[str]] = {}
    for lang in ("asl", "isl"):
        for gloss, asset_path in manifest.get(lang, {}).items():
            labels.setdefault(f"{lang}/{Path(asset_path).name}", set()).add(gloss)
    return {key: sorted(values) for key, values in labels.items()}


WRIST, MIDDLE_MCP = 0, 9
SPREAD = 42
# A wrist-to-knuckle this far under the hand's own fingertip span is a collapsed
# detection, not a small hand; scaling a row by it multiplies tracker jitter.
MIN_PALM_FRACTION = 0.05
# How many storage steps a hand has to span before its own recorded shape means
# anything. Calibrated against the tracker, not against a wish: `check_wrist_frame.py`
# measures that the mean landmark of a hand moves 0.0886 wrist units between two
# frames sampled 0.1 s apart, and holds the corpus to half of that. At 100 steps the
# worst error left by half-precision storage is 0.026 and the loader empties 2.56%
# of the rows that carry a hand; at 64 steps it keeps 1.4% more data but leaves
# 0.050, and at 38 it leaves 0.094 - more than a real frame step, which is the one
# thing a training row must not be.
MIN_PALM_STEPS = 100


def precision_blind_rows(stored: np.ndarray, min_palm_steps: int = MIN_PALM_STEPS) -> np.ndarray:
    """Which rows a track read back from disk cannot describe, as a (rows,) mask.

    A wrist-framed row divides a hand by its own palm, so the accuracy that
    matters is the storage step *at the coordinate the hand is written near*,
    measured against the hand's own length. A hand that is small next to where it
    sits in the frame - the signer leaned back, the hand is at the edge, half out
    of shot - has coordinates far from its own ruler, and in half precision the
    step between representable positions can be a tenth of the hand. Its shape is
    gone even though every number in the row looks plausible; at the extreme a
    palm two steps long is pure quantization, and dividing the row by it throws the
    other landmarks tens of units out.

    The whole row goes, not just that hand. A dropped hand stops anchoring the
    frame, and re-anchoring the hand that stays shifts it further from what the
    phone would report than the rounding did - measured at 14.6 wrist units when
    the aim was to fix 0.4. An empty row is a state the extractor already writes
    and `augment` already injects as tracking loss, so the model looks past it
    instead of learning a frame that never existed.

    Only tracks kept at half precision have anything to drop - a float32 row's
    step is orders of magnitude under any hand worth complaining about.
    """
    step = np.spacing(np.abs(stored)).astype(np.float64)
    blind = []
    for block in HAND_BLOCKS:
        coords = stored[:, block][:, :COORDS].reshape(-1, 21, 2).astype(np.float64)
        palm = np.linalg.norm(coords[:, MIDDLE_MCP] - coords[:, WRIST], axis=1)
        worst = step[:, block][:, :COORDS].max(axis=1)
        blind.append((palm > 0) & (palm < min_palm_steps * worst))
    return np.any(np.stack(blind, axis=1), axis=1)


def wrist_frame(features: np.ndarray, drop_rows: np.ndarray | None = None) -> np.ndarray:
    """Re-express shoulder-normalised rows in the frame a phone can actually build.

    The on-device landmarker reports hands but no shoulders, so live tracking can
    only use the extractor's fallback: origin at the wrist midpoint, unit of
    length 2.6 * wrist-to-middle-knuckle. Both of those are distances already
    present in the stored rows, so a track extracted with pose becomes the track
    the device would make of the same clip.

    The rule is deliberately scale-free, because the frame width that would make
    the extractor's absolute thresholds meaningful is not recoverable here: a row
    is anchored by the mean of its wrist positions and divided by the mean of its
    hand lengths, and a hand whose palm is a vanishing fraction of its own finger
    span is declared untracked instead of being divided by a made-up number. That
    test compares two distances inside one hand, so it says the same thing at any
    camera distance and any frame width - which is what lets this match the
    extractor rather than merely approximate it.

    `drop_rows` is a (rows,) mask of rows to emit empty for a reason this rule
    cannot see - the training loader passes `precision_blind_rows` for the corpus
    it stored at half precision. An emptied row carries no hands and counts none,
    which is what this already does for a frame nothing anchors.

    Spread and palm roll survive untouched: one is a ratio of distances inside
    one hand, the other an angle, and neither depends on the frame's origin or
    scale. Applying this to a track already in the wrist frame changes nothing.
    """
    out = np.asarray(features, dtype=np.float32).copy()
    rows = out.shape[0]
    present = np.stack([out[:, block.start + 45] > 0.5 for block in HAND_BLOCKS], axis=1)
    coords = [out[:, block][:, :COORDS].reshape(rows, 21, 2) for block in HAND_BLOCKS]
    wrists = np.stack([c[:, WRIST, :] for c in coords], axis=1)
    knuckles = np.stack([c[:, MIDDLE_MCP, :] for c in coords], axis=1)
    lengths = np.linalg.norm(knuckles - wrists, axis=2)
    # The stored spread is a hand's fingertip span divided by its own palm, so it
    # is already unit-free and `1 / MIN_PALM_FRACTION` is where a palm stopped
    # being a plausible ruler for the fingers it carries.
    spreads = np.stack([out[:, block.start + SPREAD] for block in HAND_BLOCKS], axis=1)
    usable = present & (lengths > 0) & (spreads <= 1.0 / MIN_PALM_FRACTION)
    if drop_rows is not None:
        usable[np.asarray(drop_rows, dtype=bool)] = False

    counts = usable.sum(axis=1)
    anchored = counts > 0
    centre = np.where(usable[:, :, None], wrists, 0.0).sum(axis=1) / np.maximum(counts, 1)[:, None]
    scale = np.where(usable, lengths, 0.0).sum(axis=1) / np.maximum(counts, 1)
    scale = np.where(anchored, scale, 1.0)

    for index, block in enumerate(HAND_BLOCKS):
        moved = (coords[index] - centre[:, None, :]) / (2.6 * scale)[:, None, None]
        values = out[:, block].copy()
        values[:, :COORDS] = moved.reshape(rows, COORDS)
        values[:, 45] = usable[:, index]
        # A hand this row cannot anchor becomes the all-zero block the extractor
        # writes for a slot it dropped - shape fields included, or the device
        # would be trained on a spread and a palm angle it can never report.
        out[:, block] = np.where(usable[:, index][:, None], values, 0.0)

    out[:, POSE_PRESENT] = 0.0
    out[:, HAND_COUNT] = counts.astype(np.float32)
    return out


def load_tracks(tracks_dir: Path = TRACKS, limit: int = 0, to_wrist_frame: bool = False) -> list[Track]:
    files = sorted(tracks_dir.glob("*.npz"))
    if limit:
        files = files[:limit]
    tracks = []
    for path in files:
        with np.load(path) as archive:
            stored = archive["features"]
            features = stored.astype(np.float32)
            if to_wrist_frame:
                # The corpus is stored at half precision, which costs a row whose
                # hand sits far from its own ruler; see `precision_blind_rows`.
                blind = precision_blind_rows(stored) if stored.dtype == np.float16 else None
                features = wrist_frame(features, blind)
            tracks.append(
                Track(
                    key=str(archive["key"]),
                    features=features,
                    stamps=archive["stamps"].astype(np.int32),
                )
            )
    return tracks


def windows(track: Track, length: int = WINDOW, stride: int = WINDOW_STRIDE) -> list[Sample]:
    if track.length <= length:
        return [Sample.from_block(track.features, length)]
    return [
        Sample.from_block(track.features[start : start + length], length)
        for start in range(0, track.length - length + 1, stride)
    ]


def split_windows(track: Track, length: int = WINDOW) -> tuple[Sample, list[Sample]]:
    """Reference from the first half, queries from the second half.

    The disjoint split is what makes a retrieval number mean something: a query
    never contains the frames it is matched against, so a hit cannot be a
    copy of the reference window.
    """
    half = max(1, track.length // 2)
    reference = Sample.from_block(track.features[:half], length)
    tail = track.features[half:]
    if len(tail) > length:
        queries = [
            Sample.from_block(tail[start : start + length], length)
            for start in range(0, len(tail) - length + 1, length)
        ]
    else:
        queries = [Sample.from_block(tail, length)]
    return reference, queries


def _rotate_hands(features: np.ndarray, scale: float, angle: float) -> np.ndarray:
    cos, sin = math.cos(angle), math.sin(angle)
    for block in HAND_BLOCKS:
        coords = features[:, block][:, :COORDS].reshape(-1, 21, 2)
        x = coords[:, :, 0] * scale
        y = coords[:, :, 1] * scale
        features[:, block][:, :COORDS] = np.stack(
            [cos * x - sin * y, sin * x + cos * y], axis=-1
        ).reshape(-1, COORDS)
        roll_sin = features[:, block.start + 43].copy()
        roll_cos = features[:, block.start + 44].copy()
        features[:, block.start + 43] = cos * roll_sin + sin * roll_cos
        features[:, block.start + 44] = cos * roll_cos - sin * roll_sin
    return features


def mirror(sample: Sample) -> Sample:
    """Swap hands and flip x: the same sign produced by the other hand."""
    features = sample.features.copy()
    features[:, HAND_BLOCKS[0]] = sample.features[:, HAND_BLOCKS[1]]
    features[:, HAND_BLOCKS[1]] = sample.features[:, HAND_BLOCKS[0]]
    for block in HAND_BLOCKS:
        coords = features[:, block][:, :COORDS].reshape(-1, 21, 2)
        coords[:, :, 0] *= -1.0
        features[:, block][:, :COORDS] = coords.reshape(-1, COORDS)
        features[:, block.start + 43] *= -1.0
    return Sample(features=features, mask=sample.mask)


def augment(sample: Sample, rng: np.random.Generator, warp: bool = True) -> Sample:
    """Speed warp, rigid transform, jitter and tracking loss — signer-agnostic noise."""
    features, mask = sample.features, sample.mask
    rows = features.shape[0]
    if warp:
        factor = float(rng.uniform(0.75, 1.3))
        index = np.clip(np.round(np.arange(rows) * factor), 0, rows - 1).astype(int)
        features, mask = features[index], mask[index]
    features = features.copy()
    features = _rotate_hands(
        features,
        scale=float(rng.uniform(0.9, 1.1)),
        angle=float(rng.uniform(-8.0, 8.0)) * math.pi / 180.0,
    )
    for block in HAND_BLOCKS:
        features[:, block.start : block.start + COORDS] += rng.normal(0, 0.02, size=(rows, COORDS)).astype(
            np.float32
        )
    dropped = rng.random(rows) < 0.1
    dropped[0] = False
    features[dropped] = 0.0
    mask = mask * (~dropped).astype(np.float32)
    features[mask < 0.5] = 0.0
    out = Sample(features=features, mask=mask)
    return mirror(out) if rng.random() < 0.5 else out


def sample_pair(track: Track, rng: np.random.Generator, length: int = WINDOW) -> tuple[Sample, Sample]:
    """Two differently distorted views of one clip, disjoint when the clip allows it.

    Overlapping views let a matcher collapse: anchor and positive are then the
    same frames and every embedding can be identical. Two separate halves of the
    clip force the encoder to keep the sign, not the phase.
    """
    if track.length < 2 * length:
        block = Sample.from_block(track.features, length)
        return augment(block, rng, warp=False), augment(block, rng, warp=False)
    first_start = int(rng.integers(0, track.length - 2 * length + 1))
    second_start = int(rng.integers(first_start + length, track.length - length + 1))
    return (
        augment(Sample.from_block(track.features[first_start : first_start + length], length), rng),
        augment(Sample.from_block(track.features[second_start : second_start + length], length), rng),
    )


def sample_window(track: Track, rng: np.random.Generator, length: int = WINDOW) -> Sample:
    if track.length <= length:
        sample = Sample.from_block(track.features, length)
        return augment(sample, rng, warp=False)
    start = int(rng.integers(0, track.length - length + 1))
    return augment(Sample.from_block(track.features[start : start + length], length), rng)


def language_of(key: str) -> str:
    return key.split("/", 1)[0]


def gloss_of(key: str) -> str:
    return Path(key).stem
