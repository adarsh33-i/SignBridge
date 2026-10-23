#!/usr/bin/env python3
"""Prove the wrist-frame conversion reproduces a real no-pose extraction.

The phone reports hands but no shoulders, so the whole on-device pipeline leans
on one claim: `video_corpus.wrist_frame` turns a track extracted *with* pose
landmarks into the track that the extractor's own wrist fallback would have
produced. If that is wrong, every number trained on the corpus describes a
representation the device cannot make.

This checks it against the ground truth rather than against itself: extract the
same clips twice, once with pose and once without, convert the pose tracks and
compare every row, including the rows both passes declare untracked.

The two halves of the row are held to different standards, because they mean
different things. Which hand slots a row trusts, how many hands it counts and
whether an unanchored row comes out empty are statements about the *rule*, so
they have to match exactly - a single disagreement is a bug in one of the two
implementations, whatever the tolerance. The landmark numbers are statements
about arithmetic, so they get a tolerance, and they are reported per column so an
amplified shape field cannot hide inside a coordinate difference.

Run it on float32 tracks to check the rule, where any difference at all is
either a rule bug or a column the row cannot help rounding:

    training/video/.venv/bin/python training/video/check_wrist_frame.py \
        --pose training/video/data/tracks_f32_pose \
        --no-pose training/video/data/tracks_f32_nopose --tolerance 0.0001

and on the shipped float16 corpus against that float32 ground truth to measure
what storing the corpus in half precision costs the phone:

    training/video/.venv/bin/python training/video/check_wrist_frame.py \
        --pose training/video/data/tracks \
        --no-pose training/video/data/tracks_f32_nopose --tolerance 0.02
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

import video_corpus as vc

TOLERANCE = 0.02

# What the corpus is allowed to be wrong by, as a fraction of the distance the
# same landmark travels between two consecutive sampled frames. `--tolerance` is
# only the reporting threshold; this is the gate, because a storage error smaller
# than the tracker's own frame-to-frame change is not something the model can be
# blamed for failing to reproduce.
MOVEMENT_FRACTION = 0.5

# A hand block is 42 coordinate floats, then spread, roll sin, roll cos, then the
# slot's own present flag. Which slots are trusted, how many hands a row counts
# and whether an unanchored row is empty are the rule, and are checked exactly
# below, so they are deliberately not tolerance groups here.
GROUPS = (
    ("left coords", slice(0, vc.COORDS)),
    ("left shape", slice(vc.COORDS, vc.COORDS + 3)),
    ("right coords", slice(46, 46 + vc.COORDS)),
    ("right shape", slice(46 + vc.COORDS, 46 + vc.COORDS + 3)),
)


def read(path: Path) -> tuple[np.ndarray, np.ndarray]:
    """The stored features array and the same values in full precision."""
    with np.load(path) as archive:
        stored = archive["features"]
        return stored, stored.astype(np.float32)


def handed_rows(features: np.ndarray) -> np.ndarray:
    """Rows where at least one hand slot carries a detection."""
    return np.stack([features[:, block.start + 45] > 0.5 for block in vc.HAND_BLOCKS], axis=1).any(axis=1)


def spreads(features: np.ndarray) -> np.ndarray:
    """Each row's largest fingertip-span-over-palm, which is how small its ruler was."""
    return np.max(
        np.stack([features[:, block.start + vc.SPREAD] for block in vc.HAND_BLOCKS], axis=1), axis=1
    )


def frame_movement(features: np.ndarray) -> np.ndarray:
    """How far the mean landmark of a hand moves between two consecutive frames."""
    present = np.stack([features[:, b.start + 45] > 0.5 for b in vc.HAND_BLOCKS], axis=1)
    coords = np.stack(
        [features[:, b.start : b.start + vc.COORDS].reshape(-1, 21, 2) for b in vc.HAND_BLOCKS], axis=1
    )
    moved = np.linalg.norm(coords[1:] - coords[:-1], axis=-1).mean(axis=-1)
    both = present[1:] & present[:-1]
    return moved[both]


def compare(pose_dir: Path, no_pose_dir: Path, tolerance: float = TOLERANCE) -> int:
    clips = rows_live = rows_empty = 0
    rows_kept = rows_blind = hands_kept = 0
    rule_bad: dict[str, int] = {}
    over = {name: 0 for name, _ in GROUPS}
    worst = (0.0, "", "")
    offenders: list[float] = []
    survivors: list[float] = []
    movement: list[float] = []

    for truth_path in sorted(no_pose_dir.glob("*.npz")):
        pose_path = pose_dir / truth_path.name
        if not pose_path.is_file():
            print(f"FAIL: {truth_path.name} has no matching pose track to convert")
            return 1
        with np.load(truth_path) as archive:
            key = str(archive["key"])
        stored_pose, converted = read(pose_path)
        truth = read(truth_path)[1]
        # Exactly what the training loader does, including emptying the rows half
        # precision cannot carry. Those are a deliberate difference from the
        # device's own row, so they are counted and left out of the comparison.
        blind = (
            vc.precision_blind_rows(stored_pose)
            if stored_pose.dtype == np.float16
            else np.zeros(converted.shape[0], dtype=bool)
        )
        converted = vc.wrist_frame(converted, blind)
        if converted.shape != truth.shape:
            print(f"FAIL: {key} shape {converted.shape} != {truth.shape}")
            return 1
        clips += 1

        live = handed_rows(truth)
        kept = ~blind
        rows_live += int(live.sum())
        rows_empty += int((~live).sum())
        rows_kept += int((kept & live).sum())
        rows_blind += int((blind & live).sum())
        present_truth = np.stack([truth[:, b.start + 45] > 0.5 for b in vc.HAND_BLOCKS], axis=1)
        hands_kept += int((present_truth & kept[:, None]).sum())

        # The rule, exactly, on every row the loader keeps: which slots it trusts,
        # how many hands it counts, that a row nothing anchors is empty - and that
        # a row it dropped really is empty instead of half kept.
        for label, column in (
            ("left slot", vc.HAND_BLOCKS[0].start + 45),
            ("right slot", vc.HAND_BLOCKS[1].start + 45),
            ("hand count", vc.HAND_COUNT),
            ("pose flag", vc.POSE_PRESENT),
        ):
            mismatch = int(((converted[:, column] != truth[:, column]) & kept).sum())
            if mismatch:
                rule_bad[label] = rule_bad.get(label, 0) + mismatch
        for label, rows in (("unanchored rows not empty", ~live), ("dropped rows not empty", blind)):
            stray = int((np.abs(converted[rows]).max(axis=1) > 0).sum()) if rows.any() else 0
            if stray:
                rule_bad[label] = rule_bad.get(label, 0) + stray

        # The numbers, per column group, with the row's own conditioning on record
        # so an over-tolerance row says whether the conversion or the storage did it.
        for name, columns in GROUPS:
            keep = live & kept
            diff = np.abs(converted[:, columns] - truth[:, columns]).max(axis=1)
            rows_over = int((diff[keep] > tolerance).sum())
            over[name] += rows_over
            if rows_over:
                offenders.extend(spreads(truth)[keep][diff[keep] > tolerance].tolist())
            peak = float(diff[keep].max()) if keep.any() else 0.0
            if peak > worst[0]:
                worst = (peak, key, name)
        survivors.extend(spreads(truth)[live].tolist())
        movement.extend(frame_movement(truth).tolist())

    print(f"{clips} clips, {rows_live} rows carrying a hand, {rows_empty} rows unanchored by both passes")
    if rows_blind:
        print(
            f"the loader empties {rows_blind} of those rows ({rows_blind / rows_live:.3%}), whose stored "
            f"coordinates are coarser than the hand they describe, and trains on the remaining {rows_kept}"
        )
    if rule_bad:
        for label, count in rule_bad.items():
            print(f"FAIL rule: {label} disagrees on {count} rows")
    else:
        print("ok rule: every row trusts the same slots, counts the same hands and empties the same rows")
    for name, count in over.items():
        print(f"  {name}: {count} rows over {tolerance}")
    if offenders:
        print(
            f"the rows over tolerance had a span/palm of {min(offenders):.1f} to {max(offenders):.1f} "
            f"(median {float(np.median(offenders)):.1f}); the corpus median is {float(np.median(survivors)):.2f}, "
            f"and a hand counts as tracked up to {1.0 / vc.MIN_PALM_FRACTION:.0f}"
        )
    print(f"worst single difference {worst[0]:.6f} on {worst[1]} ({worst[2]})")
    # The yardstick is the tracker, not a number someone liked. A landmark of the
    # same hand moves this far between two frames sampled 0.1 s apart, so anything
    # the corpus gets wrong by less than a fraction of that is a difference the
    # model has to be robust to whether the storage is exact or not.
    median_move = float(np.median(movement)) if movement else 0.0
    print(
        f"reference: the mean landmark of one hand moves {median_move:.4f} wrist units "
        f"between consecutive frames (median over {len(movement)} steps)"
    )
    if movement and worst[0] > MOVEMENT_FRACTION * median_move:
        print(f"FAIL: storage error {worst[0]:.4f} is over {MOVEMENT_FRACTION:.0%} of that movement")
        return 1
    if rule_bad:
        print(f"FAIL: {sum(rule_bad.values())} rule rows wrong")
        return 1
    print(f"ok: the converted tracks match a real no-pose extraction, {sum(over.values())} rows over {tolerance}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pose", type=Path, required=True)
    parser.add_argument("--no-pose", type=Path, required=True)
    parser.add_argument("--tolerance", type=float, default=TOLERANCE)
    args = parser.parse_args(argv)
    return compare(args.pose, args.no_pose, args.tolerance)


if __name__ == "__main__":
    raise SystemExit(main())
