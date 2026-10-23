#!/usr/bin/env python3
"""Production audit of the authored avatar rig against the ASL landmark corpus.

The corpus holds one hand-landmark track per ASL clip, in shoulder-frame units,
plus a pose-present flag. It carries no face or head landmarks: the face and the
non-manual grammar were never extracted, so this audit can measure only the
hands, their placement, their timing and how close they come to a head inferred
from body proportions. It says so rather than inventing a face score.

Every rig number comes from `build/audit/avatar_rig.json`, which the Flutter
suite exports from the painter itself:

    RIG_AUDIT_OUT=build/audit flutter test test/tools/rig_audit_export_test.dart

Then:

    python3 training/video/audit_avatar_rig.py

The output is `build/audit/avatar_corpus_audit.json`. Thresholds and the reason
for each are documented in `docs/avatar_corpus_audit.md`.

Evidence ladder, per hand, per clip:

    present -> gated -> usable -> held clusters

`present` is MediaPipe detection, `gated` additionally requires a palm within a
plausible size and a wrist inside signing space, and `usable` additionally
requires a palm that is not edge-on, because finger angles projected from an
edge-on palm are noise. A side with fewer than MIN_SHAPE_FRAMES usable frames is
reported as low confidence and never turned into a shape finding.

Placement, motion and face findings need MIN_STATIC_FRAMES usable frames: below
that the 20% end trim does not run, so the clip's fade-in and fade-out stay in
the envelope and the median anchor is a transition, not the citation form.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np

VIDEO_DIR = Path(__file__).resolve().parent
ROOT = VIDEO_DIR.parents[1]
DEFAULT_RIG = ROOT / "build" / "audit" / "avatar_rig.json"
DEFAULT_TRACKS = VIDEO_DIR / "data" / "tracks"
DEFAULT_OUT = ROOT / "build" / "audit" / "avatar_corpus_audit.json"

FPS = 10.0
SIDES = ("left", "right")
SLOTS = {"left": 0, "right": 46}
MIDDLE_MCP = 9
MIDDLE_TIP = 12
FINGERS = {
    "index": (5, 6, 8),
    "middle": (9, 10, 12),
    "ring": (13, 14, 16),
    "pinky": (17, 18, 20),
}

# A hand is "in signing space" when its wrist is at most this far below the
# shoulder line, in shoulder-width units. A hanging wrist sits near 1.2-1.5;
# every authored sign's target sits above 0.6. The gap is wide enough that the
# exact cut does not decide a sign.
ENGAGED_Y = 0.85
# Rig arms are drawn shorter than life, so engagement is measured from the
# rig's own rest wrist (y 0.687): a hand raised to 0.60 or above has left the
# side of the body. Both values are recorded in the report.
RIG_ENGAGED_Y = 0.60
# Reject collapsed or huge palms before trusting a hand's geometry. The palm
# is wrist -> middle knuckle, measured in shoulder widths.
PALM_RANGE = (0.12, 0.50)
# A palm seen edge-on projects its width onto almost nothing; finger angles
# from those frames are noise. Keep frontal-ish palms only.
ASPECT_MIN = 0.40
# Shape clusters: two frames belong together when their four PIP angles agree
# within this mean absolute difference.
CLUSTER_TOLERANCE = 30.0
MIN_CLUSTER_FRAMES = 3
# A cluster has to hold this share of a hand's usable frames to count as one of
# the sign's shapes. Transitions are short; the held handshape is not.
MIN_CLUSTER_SHARE = 0.15
# An authored handshape "supports" a corpus shape inside this mean PIP error.
SHAPE_MATCH = 30.0
MIN_SHAPE_FRAMES = 6
# Placement: how far (rig units, where a shoulder is 0.336) an authored hand
# anchor may sit from the observed anchor path before the pose is unsupported.
# The anchor is the middle knuckle, which is stable under finger curl and hand
# rotation, unlike the wrist or a fingertip.
POSITION_GAP = 0.12
# Corps clips carry an approach from rest and a release at the end. Trim this
# share from each end of the anchor path before comparing movement, when the
# clip is long enough for the trim to leave a real sample.
TRIM_SHARE = 0.20
MIN_MOTION_FRAMES = 8
# Placement and motion share the trimmed envelope, so they need at least the
# trim minimum: below it the sample keeps its fade-in and fade-out frames and
# the median anchor is a transition, not the citation form.
MIN_STATIC_FRAMES = 8
# Movement: rig keyframes draw the citation form only, with no entry from rest,
# so its motion is a lower bound. Only a gross shortfall or excess is a finding,
# and it stays a low-severity flag until a clip is checked by eye.
MOTION_RATIO_LOW = 0.30
MOTION_RATIO_HIGH = 2.00
MIN_CORPUS_SPREAD = 0.06
# The corpus clips are single citation forms with fade-in/out, and 10 fps
# quantises the span; only extreme tempo gaps are findings.
TIMING_RATIO_LOW = 0.40
TIMING_RATIO_HIGH = 2.20
MIN_TIMING_FRAMES = 8
# Rig head anchor, from `headUnitPath` in the export. The corpus has no head
# landmarks, so face contacts can only be judged against this anchor after
# mapping corpus landmarks into rig space.
HEAD_CENTER = (0.5, 0.245)
HEAD_RADIUS = 0.099
NEAR_FACE = 0.02
# One frame inside the head is indistinguishable from landmark noise, so a
# contact has to hold for at least two usable frames to be expected.
MIN_FACE_CONTACT_FRAMES = 2


def pip_angles(xy: np.ndarray) -> np.ndarray:
    """PIP angle per finger, degrees, 180 = straight, 0 = fully folded."""
    out = []
    for mcp, pip, tip in FINGERS.values():
        a = xy[mcp] - xy[pip]
        b = xy[tip] - xy[pip]
        cosine = float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-9))
        out.append(math.degrees(math.acos(max(-1.0, min(1.0, cosine)))))
    return np.array(out, dtype=np.float64)


def rig_pip(arm: dict) -> np.ndarray:
    out = []
    for chain in arm["digits"][:4]:
        base, knuckle, tip = (np.array(p, dtype=np.float64) for p in chain)
        a1 = base - knuckle
        a2 = tip - knuckle
        cosine = float(np.dot(a1, a2) / (np.linalg.norm(a1) * np.linalg.norm(a2) + 1e-9))
        out.append(math.degrees(math.acos(max(-1.0, min(1.0, cosine)))))
    return np.array(out, dtype=np.float64)


def to_rig(x: float, y: float) -> np.ndarray:
    """Corpus shoulder frame -> rig unit canvas."""
    return np.array([0.5 + x * 0.336, 0.405 + y * 0.336])


def thumb_extension(xy: np.ndarray, palm: float) -> float:
    """Thumb tip distance from the wrist over palm length; 1.4+ reads splayed."""
    return float(np.linalg.norm(xy[4] - xy[0]) / max(palm, 1e-6))


def rig_thumb_extension(arm: dict) -> float:
    wrist = np.array(arm["wrist"], dtype=np.float64)
    palm = float(np.linalg.norm(np.array(arm["digits"][1][0]) - wrist))
    tip = np.array(arm["digits"][4][2], dtype=np.float64)
    return float(np.linalg.norm(tip - wrist) / max(palm, 1e-6))


def rig_family(hand: dict) -> dict:
    folds = [float(hand[n]) for n in ("index", "middle", "ring", "pinky")]
    extended = sum(1 for f in folds if f <= 0.2)
    return {
        "extended": extended,
        "family": "open" if extended == 4 else "fist" if extended == 0 else "partial",
    }


def corpus_family(pip: np.ndarray) -> dict:
    extended = int(np.count_nonzero(pip >= 145.0))
    return {
        "extended": extended,
        "family": "open" if extended == 4 else "fist" if extended == 0 else "partial",
    }


def cluster_shapes(frames: list[dict]) -> list[dict]:
    """Group usable frames by handshape, largest group first.

    Greedy on purpose: a k-means would split one held handshape at an arbitrary
    boundary, and the question here is "which shapes does this sign hold", not
    "how many micro-states does it pass through".
    """
    clusters: list[list[dict]] = []
    for frame in frames:
        for group in clusters:
            if np.mean(np.abs(frame["pip"] - group[0]["pip"])) <= CLUSTER_TOLERANCE:
                group.append(frame)
                break
        else:
            clusters.append([frame])
    clusters.sort(key=len, reverse=True)
    usable = max(len(frames), 1)
    out = []
    for group in clusters:
        if len(group) < MIN_CLUSTER_FRAMES or len(group) / usable < MIN_CLUSTER_SHARE:
            continue
        out.append(
            {
                "frames": len(group),
                "share": round(len(group) / usable, 3),
                "pip": np.median([f["pip"] for f in group], axis=0),
                "aspect": float(np.median([f["aspect"] for f in group])),
                "thumb": float(np.median([f["thumb"] for f in group])),
                "anchor": np.median([f["anchor"] for f in group], axis=0),
                "sample": group[len(group) // 2]["index"],
            }
        )
    return out


def read_hand_track(features: np.ndarray, base: int) -> dict:
    """Per-frame hand geometry plus the detection funnel for one track slot."""
    present = features[:, base + 45] > 0.5
    pose = features[:, 92] > 0.5
    stats = {
        "present_frames": int(np.count_nonzero(present)),
        "pose_frames": int(np.count_nonzero(present & pose)),
        "size_frames": 0,
        "aspect_frames": 0,
    }
    out: list[dict] = []
    for i in np.where(present & pose)[0]:
        xy = features[i, base : base + 42].reshape(21, 2).astype(np.float64)
        palm = float(np.linalg.norm(xy[9] - xy[0]))
        if not (PALM_RANGE[0] <= palm <= PALM_RANGE[1]):
            continue
        if float(xy[0, 1]) > ENGAGED_Y:
            continue
        stats["size_frames"] += 1
        aspect = float(np.linalg.norm(xy[5] - xy[17]) / max(palm, 1e-6))
        usable = aspect >= ASPECT_MIN
        if usable:
            stats["aspect_frames"] += 1
        out.append(
            {
                "index": int(i),
                "wrist": xy[0].copy(),
                "anchor": xy[MIDDLE_MCP].copy(),
                "tips": xy[[4, 8, 12, 16, 20]].copy(),
                "palm": palm,
                "aspect": aspect,
                "thumb": thumb_extension(xy, palm),
                "pip": pip_angles(xy),
                "shape_usable": usable,
            }
        )
    stats["gated_frames"] = len(out)
    stats["usable_frames"] = stats["aspect_frames"]
    return {"frames": out, "stats": stats}


def authored_paths(sign: dict) -> dict[str, list[dict]]:
    """Every authored keyframe's hand anchor, per side, in draw order."""
    out: dict[str, list[dict]] = {side: [] for side in SIDES}
    for frame in sign["frames"]:
        for side in SIDES:
            arm = frame[side]
            if not arm["visible"]:
                continue
            out[side].append(
                {
                    "frame": frame["index"],
                    "anchor": np.array(arm["digits"][1][0], dtype=np.float64),
                    "wrist": np.array(arm["wrist"], dtype=np.float64),
                    "tip": np.array(arm["digits"][1][2], dtype=np.float64),
                    "tip4": np.array(arm["digits"][4][2], dtype=np.float64),
                    "tips": np.array(
                        [arm["digits"][i][2] for i in range(5)], dtype=np.float64
                    ),
                    "engaged": arm["wrist"][1] < RIG_ENGAGED_Y,
                }
            )
    return out


def authored_candidates(sign: dict) -> dict[str, list[dict]]:
    """Every distinct handshape the rig draws, per side, with its anchor."""
    out: dict[str, list[dict]] = {side: [] for side in SIDES}
    seen: dict[str, set] = {side: set() for side in SIDES}
    for frame in sign["frames"]:
        for side in SIDES:
            arm = frame[side]
            if not arm["visible"]:
                continue
            pip = rig_pip(arm)
            key = tuple(float(v) for v in np.round(pip / 5.0) * 5.0)
            if key in seen[side]:
                continue
            seen[side].add(key)
            out[side].append(
                {
                    "frame": frame["index"],
                    "wrist": np.array(arm["wrist"], dtype=np.float64),
                    "anchor": np.array(arm["digits"][1][0], dtype=np.float64),
                    "pip": pip,
                    "thumb": rig_thumb_extension(arm),
                    "engaged": arm["wrist"][1] < RIG_ENGAGED_Y,
                    "hand": arm["hand"],
                    "side": side,
                }
            )
    return out


def engaged_candidates(candidates: dict[str, list[dict]]) -> list[dict]:
    """The hands that take part in the sign, pooled across sides.

    A one-handed sign is authored on one arm and leaves the other resting;
    matching a corpus hand to the resting arm would compare the sign against a
    hand that is not signing. Handshape does not depend on which arm draws it,
    so the shape search runs over every engaged arm.
    """
    pooled = [c for side in SIDES for c in candidates[side] if c["engaged"]]
    return pooled or [c for side in SIDES for c in candidates[side]]


def best_shape_match(pip: np.ndarray, candidates: list[dict]) -> tuple[float, dict | None]:
    best = (float("inf"), None)
    for candidate in candidates:
        delta = float(np.mean(np.abs(pip - candidate["pip"])))
        if delta < best[0]:
            best = (delta, candidate)
    return best


def spread(points: np.ndarray) -> float:
    """Mean distance from the point set's centroid: its radius of gyration.

    A median distance is robust but not comparable across point counts. The
    rig envelope can be only three keys, so its median is one of three
    distances and a key that arcs out and returns still reads as a small move.
    The mean is unbiased at any count; the corpus path is already trimmed.
    """
    if len(points) < 2:
        return 0.0
    centre = np.mean(points, axis=0)
    return float(np.mean(np.linalg.norm(points - centre, axis=1)))


def directed_gap(a: np.ndarray, b: np.ndarray) -> float:
    """Median nearest-neighbour distance from path a to path b."""
    if not len(a) or not len(b):
        return float("nan")
    return float(np.median(np.min(np.linalg.norm(a[:, None, :] - b[None, :, :], axis=2), axis=1)))


def trim(points: list[dict], share: float = TRIM_SHARE) -> list[dict]:
    if len(points) < MIN_MOTION_FRAMES:
        return points
    cut = int(len(points) * share)
    return points[cut : len(points) - cut]


def summarise_side(
    frames: list[dict],
    pooled: list[dict],
    paths: dict[str, list[dict]],
) -> dict:
    usable = [f for f in frames if f["shape_usable"]]
    clusters = cluster_shapes(usable)
    cluster_rows = []
    matched_frames = 0
    total_cluster_frames = 0
    worst = 0.0
    matched_side: str | None = None
    matched_delta = float("inf")
    for cluster in clusters:
        delta, candidate = best_shape_match(cluster["pip"], pooled)
        supported = delta <= SHAPE_MATCH
        corpus_class = corpus_family(cluster["pip"])
        rig_class = rig_family(candidate["hand"]) if candidate else None
        if supported or candidate is None:
            kind = None
        elif rig_class is None:
            kind = "no_candidate"
        elif rig_class["extended"] != corpus_class["extended"]:
            kind = "count_conflict"
        else:
            kind = "fold_depth"
        cluster_rows.append(
            {
                "frames": cluster["frames"],
                "share": cluster["share"],
                "aspect": round(cluster["aspect"], 2),
                "thumb": round(cluster["thumb"], 2),
                "pip": [round(float(v), 1) for v in cluster["pip"]],
                "family": corpus_class,
                "delta": round(delta, 1),
                "supported": supported,
                "kind": kind,
                "rig_family": rig_class,
                "match_frame": candidate["frame"] if candidate else None,
                "match_side": candidate["side"] if candidate else None,
                "sample_frame": cluster["sample"],
            }
        )
        total_cluster_frames += cluster["frames"]
        if supported:
            matched_frames += cluster["frames"]
        worst = max(worst, delta)
        if delta < matched_delta and candidate is not None:
            matched_delta = delta
            matched_side = candidate["side"]
    shape_support = (
        round(matched_frames / total_cluster_frames, 3) if total_cluster_frames else None
    )

    # Placement compares the middle-knuckle path up to a mirror, because the
    # corpus contains handedness-labelled slots while the rig draws one signer.
    # The mirror decision is made once, from the medians, not per frame.
    placement = paths[matched_side] if matched_side else []
    if not placement:
        placement = [p for side in SIDES for p in paths[side]]
    engaged_placement = [p for p in placement if p["engaged"]] or placement

    corpus_anchor_rig = np.array([to_rig(*f["anchor"]) for f in frames]) if frames else np.empty((0, 2))
    rig_anchor = np.array([p["anchor"] for p in engaged_placement]) if engaged_placement else np.empty((0, 2))
    median_corpus_x = (
        float(np.median([f["anchor"][0] for f in frames])) if frames else 0.0
    )
    median_rig_offset = (
        float(np.median(rig_anchor[:, 0]) - 0.5) if len(rig_anchor) else median_corpus_x
    )
    reflect = median_corpus_x * median_rig_offset < 0
    if reflect and len(corpus_anchor_rig):
        corpus_anchor_rig[:, 0] = 1.0 - corpus_anchor_rig[:, 0]
    gap_a = directed_gap(corpus_anchor_rig, rig_anchor)
    gap_b = directed_gap(rig_anchor, corpus_anchor_rig)
    pos_gap = (
        round(max(gap_a, gap_b), 3)
        if math.isfinite(gap_a) and math.isfinite(gap_b)
        else None
    )

    corpus_core = trim(frames)
    corpus_motion = (
        np.array([to_rig(*f["anchor"]) for f in corpus_core])
        if corpus_core
        else np.empty((0, 2))
    )
    if reflect and len(corpus_motion):
        corpus_motion[:, 0] = 1.0 - corpus_motion[:, 0]
    corpus_spread = spread(corpus_motion)
    rig_spread = spread(rig_anchor)

    tip_rig = (
        np.array([[to_rig(*p) for p in f["tips"]] for f in frames])
        if frames
        else np.empty((0, 5, 2))
    )
    head = np.array(HEAD_CENTER)
    if len(tip_rig):
        near = np.linalg.norm(tip_rig - head, axis=2) - HEAD_RADIUS
        min_face = round(float(np.min(near)), 3)
        face_frames = int(np.count_nonzero(np.min(near, axis=1) < NEAR_FACE))
    else:
        min_face = None
        face_frames = 0

    return {
        "usable_frames": len(usable),
        "static_support": len(usable) >= MIN_STATIC_FRAMES,
        "clusters": cluster_rows,
        "shape_support": shape_support,
        "worst_delta": round(worst, 1) if clusters else None,
        "matched_side": matched_side,
        "position_gap": pos_gap,
        "corpus_spread": round(corpus_spread, 3),
        "rig_spread": round(rig_spread, 3),
        "motion_ratio": (
            round(rig_spread / corpus_spread, 2) if corpus_spread > 1e-6 else None
        ),
        "corpus_anchor_median": (
            [round(float(v), 3) for v in np.median(corpus_motion, axis=0)]
            if len(corpus_motion)
            else []
        ),
        "rig_anchor_median": (
            [round(float(v), 3) for v in np.median(rig_anchor, axis=0)]
            if len(rig_anchor)
            else []
        ),
        "corpus_wrist_median": (
            [round(float(v), 3) for v in np.median([f["wrist"] for f in frames], axis=0)]
            if frames
            else []
        ),
        "min_tip_head_surface": min_face,
        "tip_near_head_frames": face_frames,
        "reflected": bool(reflect),
    }


def audit_sign(key: str, sign: dict, track_dir: Path) -> dict:
    path = track_dir / f"asl__{key}.npz"
    if not path.is_file():
        return {"status": "missing"}
    features = np.load(path)["features"].astype(np.float32)
    tracks = {name: read_hand_track(features, base) for name, base in SLOTS.items()}
    sides = {name: tracks[name]["frames"] for name in SIDES}
    candidates = authored_candidates(sign)
    pooled = engaged_candidates(candidates)
    paths = authored_paths(sign)

    engaged = {name: len(frames) for name, frames in sides.items()}
    both = 0
    both_present = 0
    any_engaged = 0
    for i in range(features.shape[0]):
        if features[i, 92] <= 0.5:
            continue
        detected = [features[i, base + 45] > 0.5 for base in SLOTS.values()]
        if all(detected):
            both_present += 1
        caught = []
        for name, base in SLOTS.items():
            if features[i, base + 45] <= 0.5:
                caught.append(False)
                continue
            caught.append(float(features[i, base + 1]) <= ENGAGED_Y)
        if any(caught):
            any_engaged += 1
            if all(caught):
                both += 1
    both_share = round(both / max(any_engaged, 1), 3)

    side_rows = {}
    for name in SIDES:
        track = tracks[name]
        frames = track["frames"]
        usable = sum(1 for f in frames if f["shape_usable"])
        if usable < MIN_SHAPE_FRAMES:
            side_rows[name] = {
                "status": "low_sample",
                "present_frames": track["stats"]["present_frames"],
                "pose_frames": track["stats"]["pose_frames"],
                "gated_frames": track["stats"]["gated_frames"],
                "usable_frames": usable,
            }
            continue
        row = summarise_side(frames, pooled, paths)
        row["status"] = "ok"
        row["present_frames"] = track["stats"]["present_frames"]
        row["pose_frames"] = track["stats"]["pose_frames"]
        row["gated_frames"] = track["stats"]["gated_frames"]
        side_rows[name] = row

    authored_engaged = {
        name: any(c["engaged"] for c in candidates[name]) for name in SIDES
    }
    rig_hands = sum(authored_engaged.values())
    active = max(engaged, key=lambda n: engaged[n]) if any(engaged.values()) else None
    active_row = side_rows.get(active) if active else None
    has_shapes = active_row is not None and active_row.get("status") == "ok"

    flags = []
    shape_findings = []
    if has_shapes:
        if active_row["shape_support"] is not None and active_row["shape_support"] < 0.7:
            flags.append("handshape_unmatched")
        for cluster in active_row["clusters"]:
            if cluster["kind"] is None:
                continue
            shape_findings.append(
                {
                    "sample_frame": cluster["sample_frame"],
                    "corpus_family": cluster["family"],
                    "rig_family": cluster["rig_family"],
                    "delta": cluster["delta"],
                    "kind": cluster["kind"],
                    "severity": "high" if cluster["kind"] == "count_conflict" else "medium",
                }
            )
        if (
            active_row.get("static_support")
            and active_row["position_gap"] is not None
            and active_row["position_gap"] > POSITION_GAP
        ):
            flags.append("placement_gap")
        if (
            active_row.get("static_support")
            and active_row["motion_ratio"] is not None
            and active_row["corpus_spread"] >= MIN_CORPUS_SPREAD
            and (
                active_row["motion_ratio"] < MOTION_RATIO_LOW
                or active_row["motion_ratio"] > MOTION_RATIO_HIGH
            )
        ):
            flags.append("motion_amplitude")
    if rig_hands == 1 and both_share >= 0.35 and both >= 4:
        flags.append("offhand_missing")
    if rig_hands == 2 and both_share <= 0.02:
        # Two hands were never both detected in signing space. If the corpus
        # detected both hands together at all, that is evidence against the
        # authored second hand; if it never did, the clip cannot judge.
        flags.append(
            "offhand_unobserved" if both_present >= MIN_SHAPE_FRAMES else "offhand_undetected"
        )

    face = None
    if active_row is not None:
        corpus_min = active_row.get("min_tip_head_surface")
        rig_tips = [
            p["tips"]
            for side in SIDES
            for p in paths[side]
            if p["engaged"]
        ]
        rig_min = None
        if rig_tips:
            rig_tips = np.array(rig_tips)
            rig_min = round(
                float(
                    np.min(
                        np.linalg.norm(rig_tips - np.array(HEAD_CENTER), axis=2)
                        - HEAD_RADIUS
                    )
                ),
                3,
            )
        near_head_frames = int(active_row.get("tip_near_head_frames") or 0)
        contact_expected = (
            corpus_min is not None
            and corpus_min <= NEAR_FACE
            and near_head_frames >= MIN_FACE_CONTACT_FRAMES
            and active_row.get("static_support")
        )
        face = {
            "corpus_min_tip_head_surface": corpus_min,
            "rig_min_tip_head_surface": rig_min,
            "corpus_near_head_frames": near_head_frames,
            "contact_expected": bool(contact_expected),
        }
        if contact_expected and rig_min is not None and rig_min > NEAR_FACE + 0.04:
            flags.append("face_contact_missed")

    timing_frames = sides[active] if active else []
    corpus_span = (
        (max(f["index"] for f in timing_frames) - min(f["index"] for f in timing_frames) + 1)
        / FPS
        if timing_frames
        else 0.0
    )
    timing_ratio = (
        round((sign["totalMs"] / 1000.0) / corpus_span, 2) if corpus_span else None
    )
    if (
        timing_ratio is not None
        and corpus_span >= 0.4
        and len(timing_frames) >= MIN_TIMING_FRAMES
        and (timing_ratio < TIMING_RATIO_LOW or timing_ratio > TIMING_RATIO_HIGH)
    ):
        flags.append("timing")

    return {
        "status": "ok",
        "frames": int(features.shape[0]),
        "engaged_frames": engaged,
        "both_engaged_frames": both,
        "both_engaged_share": both_share,
        "both_present_frames": both_present,
        "corpus_span_s": round(corpus_span, 1),
        "rig_total_s": round(sign["totalMs"] / 1000.0, 2),
        "timing_ratio": timing_ratio,
        "rig_hands": rig_hands,
        "sides": side_rows,
        "shape_findings": shape_findings,
        "face": face,
        "flags": flags,
    }


def rig_shape_summary(rig: dict) -> list[dict]:
    """Distinct authored handshapes and the signs that use them.

    The corpus cannot audit a shape nobody signs, and the report needs the
    inventory to state which rig shapes are fists, open hands or partial.
    """
    shapes: dict[tuple, dict] = {}
    for key, sign in sorted(rig["signs"].items()):
        for frame in sign["frames"]:
            for side in SIDES:
                arm = frame[side]
                if not arm["visible"]:
                    continue
                pip = rig_pip(arm)
                rounded = tuple(float(v) for v in np.round(pip / 5.0) * 5.0)
                if rounded not in shapes:
                    cls = rig_family(arm["hand"])
                    shapes[rounded] = {
                        "pip": [round(float(v), 1) for v in pip],
                        "thumb": round(rig_thumb_extension(arm), 2),
                        "extended": cls["extended"],
                        "family": cls["family"],
                        "signs": set(),
                    }
                shapes[rounded]["signs"].add(key)
    out = []
    for row in shapes.values():
        row["mean_pip"] = round(float(np.mean(row["pip"][:4])), 1)
        row["signs"] = sorted(row["signs"])
        out.append(row)
    out.sort(key=lambda r: (r["family"], r["mean_pip"]))
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rig", type=Path, default=DEFAULT_RIG)
    parser.add_argument("--tracks", type=Path, default=DEFAULT_TRACKS)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args(argv)

    rig = json.loads(args.rig.read_text(encoding="utf-8"))
    results = {}
    counts: dict[str, int] = {}
    print(f"{'sign':14s} {'present':>8s} {'usable':>7s} {'support':>8s} {'gap':>6s} {'motion':>7s} {'flags'}")
    for key, sign in sorted(rig["signs"].items()):
        row = audit_sign(key, sign, args.tracks)
        results[key] = row
        for flag in row.get("flags", []):
            counts[flag] = counts.get(flag, 0) + 1
        if row["status"] != "ok":
            print(f"{key:14s} {'-':>8s} {'-':>7s} {'-':>8s} {'-':>6s} {'-':>7s} missing")
            continue
        active = max(row["engaged_frames"], key=lambda n: row["engaged_frames"][n])
        active_row = row["sides"].get(active, {})
        present = active_row.get("present_frames", 0)
        usable = active_row.get("usable_frames", 0)
        support = active_row.get("shape_support")
        gap = active_row.get("position_gap")
        motion = active_row.get("motion_ratio")
        print(
            f"{key:14s} {present:8d} {usable:7d} "
            f"{(f'{support:.2f}' if support is not None else '-'):>8s} "
            f"{(f'{gap:.2f}' if gap is not None else '-'):>6s} "
            f"{(f'{motion:.2f}' if motion is not None else '-'):>7s} "
            f"{','.join(row['flags']) or 'clean'}"
        )
    limited_static = []
    for key, row in results.items():
        if row.get("status") != "ok":
            continue
        active = max(row["engaged_frames"], key=lambda n: row["engaged_frames"][n])
        side = row["sides"].get(active) or {}
        if side.get("status") == "ok" and not side.get("static_support"):
            limited_static.append(key)
    payload = {
        "version": 3,
        "rig": rig["rig"],
        "thresholds": {
            "engaged_y": ENGAGED_Y,
            "rig_engaged_y": RIG_ENGAGED_Y,
            "palm_range": list(PALM_RANGE),
            "aspect_min": ASPECT_MIN,
            "cluster_tolerance": CLUSTER_TOLERANCE,
            "min_cluster_frames": MIN_CLUSTER_FRAMES,
            "min_cluster_share": MIN_CLUSTER_SHARE,
            "shape_match": SHAPE_MATCH,
            "min_shape_frames": MIN_SHAPE_FRAMES,
            "position_gap": POSITION_GAP,
            "trim_share": TRIM_SHARE,
            "min_static_frames": MIN_STATIC_FRAMES,
            "min_corpus_spread": MIN_CORPUS_SPREAD,
            "motion_ratio": [MOTION_RATIO_LOW, MOTION_RATIO_HIGH],
            "timing_ratio": [TIMING_RATIO_LOW, TIMING_RATIO_HIGH],
            "near_face": NEAR_FACE,
            "min_face_contact_frames": MIN_FACE_CONTACT_FRAMES,
        },
        "rig_shapes": rig_shape_summary(rig),
        "flags": counts,
        "limited_static_sample": sorted(limited_static),
        "signs": results,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=1), encoding="utf-8")
    print(f"\nwrote {args.out}")
    print("flags:", counts)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
