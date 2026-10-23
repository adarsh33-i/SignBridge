#!/usr/bin/env python3
"""Write the device feature-row fixture the Dart recognizer is tested against.

The phone has 21 hand landmarks and no body frame, so the numbers it feeds the
encoder are built by a second implementation of one rule - the wrist fallback in
`extract_tracks._body_frame`. That rule is load-bearing twice over: it defines
the corpus the model was trained on, and it is the only frame the app can
compute live. If the Dart version drifts from the Python version, the app scores
a different embedding than the one the accuracy numbers were measured on, and
nothing in the pipeline notices.

So this writes the ground truth from the extractor itself. For each case it
takes raw normalised-image landmark points and emits the 94 floats the
extractor writes for them. It emits the case twice over where it can: the
shoulder-framed row converted by `video_corpus.wrist_frame`, which is how the
shipped corpus was made, and the direct no-pose row, which is what the phone
does. Those two are what `check_wrist_frame.py` proves equal over 80k real rows;
here they are checked per case, so a fixture row is not trusted just because a
Dart test agrees with it.

    training/video/.venv/bin/python training/video/export_row_parity.py \
        --out test/fixtures/video_match/row_parity.txt --cases 400 --seed 7
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

import numpy as np

import extract_tracks as ex
import video_corpus as vc

ROOT = Path(__file__).resolve().parents[2]

# The cases the rule is really about, as (left hand, right hand) kinds: both
# hands, only one of them, neither of them, a hand whose knuckle collapsed onto
# its wrist, a hand whose palm is a sliver of its own span, and a hand pinned to
# the frame edge. `absent` is the state the camera is in most of the time, so it
# is a case the app has to get right, not a gap in the fixture.
CASES = (
    ("normal", "normal"),
    ("normal", "absent"),
    ("absent", "normal"),
    ("absent", "absent"),
    ("collapsed", "normal"),
    ("normal", "collapsed"),
    ("tiny_palm", "tiny_palm"),
    ("collapsed", "tiny_palm"),
    ("edge", "edge"),
    ("edge", "normal"),
)


def make_hand(rng: np.random.Generator, kind: str) -> np.ndarray | None:
    """Raw normalised-image landmarks for one hand, 21 x (x, y).

    Only the points the row actually reads matter - wrist, middle knuckle, the
    four tips, the thumb tip and the index and pinky MCPs - but every slot gets a
    plausible value, because a fixture that leaves coordinates at zero would let
    a Dart implementation pass while misreading a hand a real camera reports.
    """
    if kind == "absent":
        return None
    # A hand near the frame edge has coordinates far from its own length, which is
    # what makes half precision lose it.
    wrist = (
        np.array([rng.choice([0.02, 0.98]), rng.uniform(0.1, 0.9)])
        if kind == "edge"
        else rng.uniform(0.15, 0.85, 2)
    )
    direction = rng.uniform(-math.pi, math.pi)
    palm = {"collapsed": 0.004, "tiny_palm": 0.006}.get(kind, 0.09)
    span = 0.5 if kind == "tiny_palm" else 0.2
    knuckle = wrist + palm * np.array([math.cos(direction), math.sin(direction)])
    points = np.zeros((21, 2), dtype=np.float32)
    points[:] = wrist + 0.5 * (knuckle - wrist)
    points[vc.WRIST] = wrist
    points[vc.MIDDLE_MCP] = knuckle
    for name, offset in (("index", 1), ("middle", 0), ("pinky", -1)):
        angle = direction + 0.35 * offset
        finger = getattr(ex, f"{name.upper()}_MCP")
        points[finger] = knuckle + 0.05 * offset * np.array([math.cos(angle), math.sin(angle)])
    for step, tip in enumerate(ex.FINGERTIPS):
        angle = direction + (step - 1.5) * 0.25
        points[tip] = knuckle + span * np.array([math.cos(angle), math.sin(angle)])
    points[ex.THUMB_TIP] = knuckle + 0.6 * span * np.array(
        [math.cos(direction + 1.0), math.sin(direction + 1.0)]
    )
    return np.clip(points, 0.0, 1.0).astype(np.float32)


class Landmarks:
    """The `.x` / `.y` pair MediaPipe reports, so the extractor code runs unchanged."""

    def __init__(self, point: np.ndarray) -> None:
        self.x = float(point[0])
        self.y = float(point[1])


def row_from_lands(left: np.ndarray | None, right: np.ndarray | None) -> np.ndarray:
    """Exactly what `extract_tracks` writes for a frame with hands but no pose."""
    slots = [None if left is None else [Landmarks(p) for p in left],
             None if right is None else [Landmarks(p) for p in right]]
    frame = ex._body_frame(None, slots)
    row = np.zeros(vc.FEATURES_PER_FRAME, dtype=np.float32)
    if frame is None:
        return row
    centre, scale, usable = frame
    present = [1.0 if ok else 0.0 for ok in usable]
    row[:46] = ex._hand_block(slots[0] if usable[0] else None, centre, scale, present[0])
    row[46:92] = ex._hand_block(slots[1] if usable[1] else None, centre, scale, present[1])
    row[vc.HAND_COUNT] = float(sum(present))
    return row


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "test" / "fixtures" / "video_match" / "row_parity.txt")
    parser.add_argument("--cases", type=int, default=400)
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args(argv)

    rng = np.random.default_rng(args.seed)
    lines = [f"# device feature-row parity, generated by {Path(__file__).name} seed={args.seed}"]
    written = 0
    for case in range(args.cases):
        left_kind, right_kind = CASES[case % len(CASES)]
        left = make_hand(rng, left_kind)
        right = make_hand(rng, right_kind)
        direct = row_from_lands(left, right)
        # The same frame built the way the shipped corpus was built: shoulder
        # units first, then converted. If these disagree the fixture would test
        # a rule the training data never used.
        shoulders = np.array([0.35, 0.65])
        width = 0.3
        native = np.zeros(vc.FEATURES_PER_FRAME, dtype=np.float32)
        for index, hand in enumerate((left, right)):
            if hand is None:
                continue
            block = index * 46
            native[block : block + 42] = ((hand - shoulders) / width).reshape(-1)
            palm = float(np.linalg.norm(hand[vc.MIDDLE_MCP] - hand[vc.WRIST]))
            native[block + vc.SPREAD] = (
                float(np.mean([np.linalg.norm(hand[t] - hand[vc.WRIST]) for t in ex.FINGERTIPS])) / palm
            )
            across = hand[ex.INDEX_MCP] - hand[ex.PINKY_MCP]
            angle = math.atan2(float(across[1]), float(across[0]))
            native[block + 43], native[block + 44] = math.sin(angle), math.cos(angle)
            native[block + 45] = 1.0
        native[vc.POSE_PRESENT] = 1.0
        native[vc.HAND_COUNT] = float(left is not None) + float(right is not None)
        converted = vc.wrist_frame(native.reshape(1, -1))[0]
        difference = float(np.abs(converted - direct).max())
        if difference > 2e-5:
            print(
                f"FAIL case {case} ({left_kind}+{right_kind}): "
                f"corpus route and device route differ by {difference:.2e}"
            )
            return 1

        lines.append(f"case {case} hands {left_kind} {right_kind}")
        # Nine digits is what it takes to write a float32 and read it back
        # unchanged. Fewer and the fixture's own rounding, amplified by the row
        # dividing by a palm, is larger than the error budget a test can use.
        for hand in (left, right):
            lines.append("hand -" if hand is None else "hand " + " ".join(f"{v:.9g}" for v in hand.reshape(-1)))
        lines.append("row " + " ".join(f"{v:.9g}" for v in direct))
        written += 1

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{written} cases -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
