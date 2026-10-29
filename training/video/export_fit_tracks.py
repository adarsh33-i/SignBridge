#!/usr/bin/env python3
"""Dump landmark tracks as JSON so the Dart rig fitter can read them.

The fitter lives with the rig (`test/tools/landmark_fitter.dart`) because every
number it produces has to come from `armOf`, `armTo` and `digitBones`. This
script only moves data: the 21 MediaPipe points of each hand for each frame, in
the corpus body frame — origin at the shoulder midpoint, unit one shoulder
width — which is the frame `audit_avatar_rig.py::to_rig` already maps into the
rig canvas. A fitted sign and an audited sign therefore share one coordinate
convention and one set of gates.

Only frames whose slot was detected are written, and a slot with no landmark
geometry (palm collapsed onto wrist) is dropped here rather than in the fitter,
so the fitter never has to guess whether a zero row means "hand absent" or "hand
at the origin".

Usage:
    training/video/.venv/bin/python training/video/export_fit_tracks.py \
        --keys asl/hello asl/mother --out training/video/data/fit
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

VIDEO_DIR = Path(__file__).resolve().parent
DEFAULT_TRACKS = VIDEO_DIR / "data" / "tracks"
DEFAULT_OUT = VIDEO_DIR / "data" / "fit"

# Same funnel as the audit: a palm outside this range is a bad detection, and a
# wrist hanging below the shoulder line by more than this is not in signing
# space. Both are in shoulder-width units.
#
# Unlike the audit, this does not drop edge-on frames on palm aspect. A rolled
# hand is a property of the footage the library needs to know about, and the
# fitter's rolled-palm gate says so; filtering it out here would leave only a
# short track and no reason.
PALM_RANGE = (0.12, 0.50)
ENGAGED_Y = 0.85
WRIST, MIDDLE_MCP = 0, 9


def track_path(tracks: Path, key: str) -> Path:
    stem = key.removeprefix("clips/").replace("/", "__")
    if not stem.endswith(".npz"):
        stem = f"{stem}.npz" if not stem.endswith(".mp4") else stem[: -len(".mp4")] + ".npz"
    return tracks / stem


def hand_points(features: np.ndarray, base: int) -> list[dict] | None:
    """Every usable frame's 21 points for one hand slot, or None.

    Each entry carries its own frame ordinal: a slot drops a frame when that hand
    left the signing space, and the other hand's frames keep theirs, so the two
    slots stay on one clock instead of two lists that have silently slid apart.
    """
    present = features[:, base + 45] > 0.5
    pose = features[:, 92] > 0.5
    out: list[dict] = []
    for i in np.where(present & pose)[0]:
        xy = features[i, base : base + 42].reshape(21, 2).astype(np.float64)
        palm = float(np.linalg.norm(xy[MIDDLE_MCP] - xy[WRIST]))
        if not (PALM_RANGE[0] <= palm <= PALM_RANGE[1]):
            continue
        if float(xy[WRIST][1]) > ENGAGED_Y:
            continue
        out.append(
            {
                "f": int(i),
                "p": [[round(float(px), 5), round(float(py), 5)] for px, py in xy],
            }
        )
    return out or None


def export(tracks: Path, out: Path, keys: list[str]) -> int:
    out.mkdir(parents=True, exist_ok=True)
    written = 0
    for key in keys:
        path = track_path(tracks, key)
        if not path.exists():
            print(f"skip {key}: no track at {path.name}")
            continue
        with np.load(path, allow_pickle=True) as data:
            features = data["features"].astype(np.float32)
            fps = float(data["fps"])
        # Each slot keeps only its own detected frames, but every entry carries
        # its clip ordinal, so the fitter can line the two hands up on one clock.
        hands = {
            slot: points
            for slot, points in (("left", hand_points(features, 0)), ("right", hand_points(features, 46)))
            if points is not None
        }
        if not hands:
            print(f"skip {key}: nothing in signing space")
            continue
        target = out / f"{path.stem}.json"
        target.write_text(
            json.dumps(
                {
                    "key": key,
                    "fps": fps,
                    "frameMs": round(1000.0 / fps),
                    "hands": hands,
                },
                separators=(",", ":"),
            )
        )
        written += 1
        print(f"wrote {target.name} ({target.stat().st_size} bytes)")
    return written


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keys", nargs="+", required=True, help="clip keys, e.g. asl/hello")
    parser.add_argument("--tracks", type=Path, default=DEFAULT_TRACKS)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args(argv)
    n = export(args.tracks, args.out, args.keys)
    print(f"{n}/{len(args.keys)} tracks exported")
    return 0 if n else 1


if __name__ == "__main__":
    raise SystemExit(main())
