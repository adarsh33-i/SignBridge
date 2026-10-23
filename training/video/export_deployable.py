#!/usr/bin/env python3
"""Write the trained matcher out as files a phone can read without a runtime.

The app has no ONNX or TensorFlow runtime and this project adds no paid or
subscription dependency, so the encoder ships as raw numbers and runs in
Dart. This script flattens `runs/<name>/embed.pt` into one float32 blob in the
exact order the Dart reader walks it, quantises the retrieval bank to int8, and
proves both of those are lossless where loss matters:

  * the blob re-read from disk must reproduce the torch embedding, and
  * the int8 bank must name the same clip for every window the phone would
    actually answer on, and move the accept margin by well under the gate.

Near-ties the float bank already declines may flip clips between the two banks;
neither answer is shown, so that is reported rather than failed on.

It also writes a golden file - real clip windows with the embedding torch
computed for them - which is what `landmark_encoder_test.dart` compares against,
so the Dart forward pass cannot quietly disagree with the trained one.

    training/video/.venv/bin/python training/video/export_deployable.py \
        --run training/video/runs/video_match_wrist
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np
import torch

import video_corpus as vc
import train_match as tm

LAYOUT_VERSION = 1
GOLDEN_WINDOWS = 1024
GOLDEN_TRACKS = 600
# What the phone will be configured to accept, and what this export has to prove
# it can hold. `verify_video_match.py` measures the answer rate at each threshold
# on held-out clip halves; 0.02 is the smallest gate that keeps a fourth of the
# head-room for the int8 margin shift measured below.
ACCEPT_MARGIN = 0.02
RNG_SEED = 20261023


def named_tensors(model: torch.nn.Module) -> list[tuple[str, np.ndarray]]:
    """Every parameter, in the order the Dart reader consumes them.

    A flat float32 blob with no names is only safe if this order is written down
    in one place; the manifest repeats it so the Dart side can assert it read the
    number of floats it expected.
    """
    state = model.state_dict()
    order = ["frame.0.weight", "frame.0.bias"]
    # nn.GRU names its weights weight_ih_l0 / weight_hh_l0 / bias_ih_l0, and a
    # bidirectional layer adds _reverse.
    for reverse in ("", "_reverse"):
        for name in ("weight_ih", "weight_hh", "bias_ih", "bias_hh"):
            key = f"temporal.{name}_l0{reverse}"
            if key in state:
                order.append(key)
    order += ["attend.weight", "attend.bias", "head.weight", "head.bias"]
    missing = [key for key in order if key not in state]
    if missing:
        raise SystemExit(f"the trained model does not carry {missing}; export order has drifted")
    unknown = [key for key in state if key not in order]
    if unknown:
        raise SystemExit(f"unexported parameters {unknown}; the Dart reader would be incomplete")
    return [(key, state[key].detach().cpu().numpy().astype(np.float32)) for key in order]


def write_weights(tensors: list[tuple[str, np.ndarray]], target: Path) -> int:
    blob = np.concatenate([values.reshape(-1) for _, values in tensors])
    target.write_bytes(blob.astype("<f4").tobytes())
    return int(blob.size)


def quantise(vectors: np.ndarray) -> tuple[np.ndarray, float]:
    """One global scale for a bank of unit vectors.

    Per-row or per-column scales would make the dot product a two-loop mess on
    the phone for no gain here: every vector is L2-normalised, so they all live
    in the same range.
    """
    peak = float(np.abs(vectors).max())
    scale = peak / 127.0 if peak > 0 else 1.0
    return np.rint(vectors / scale).clip(-127, 127).astype(np.int8), scale


def gru_numpy(x: np.ndarray, weights: dict, direction: str) -> np.ndarray:
    """The GRU the Dart encoder mirrors, gate order reset / update / new."""
    w_ih, w_hh = weights[f"weight_ih{direction}"], weights[f"weight_hh{direction}"]
    b_ih, b_hh = weights[f"bias_ih{direction}"], weights[f"bias_hh{direction}"]
    third = w_ih.shape[0] // 3
    out = np.zeros((x.shape[0], x.shape[1], w_hh.shape[1]), dtype=np.float64)
    state = np.zeros((x.shape[0], w_hh.shape[1]), dtype=np.float64)
    for row in range(x.shape[1]):
        gates_x = x[:, row] @ w_ih.T + b_ih
        gates_h = state @ w_hh.T + b_hh
        reset = 1.0 / (1.0 + np.exp(-(gates_x[:, :third] + gates_h[:, :third])))
        update = 1.0 / (1.0 + np.exp(-(gates_x[:, third : 2 * third] + gates_h[:, third : 2 * third])))
        new = np.tanh(gates_x[:, 2 * third :] + reset * gates_h[:, 2 * third :])
        state = (1.0 - update) * new + update * state
        out[:, row] = state
    return out


def gelu(x: np.ndarray) -> np.ndarray:
    """torch's default GELU, which is the exact erf form, not the tanh one.

    `math.erf` is accurate to better than 1e-15, so the exported blob and the
    Dart encoder agree with the trained model instead of drifting by the 1e-3 a
    tanh approximation would cost.
    """
    return 0.5 * x * (1.0 + np.vectorize(math.erf)(x / math.sqrt(2.0)))


def forward_numpy(features: np.ndarray, mask: np.ndarray, tensors: dict) -> np.ndarray:
    """Encode a batch of windows from the exported blob alone, no torch."""
    frame = gelu(features @ tensors["frame.0.weight"].T + tensors["frame.0.bias"])
    frame = np.where(mask[:, :, None] > 0.5, frame, 0.0)
    forward = gru_numpy(frame, tensors, "")
    backward = np.flip(gru_numpy(np.flip(frame, axis=1), tensors, "_reverse"), axis=1)
    joined = np.concatenate([forward, backward], axis=2)
    scores = joined @ tensors["attend.weight"].T + tensors["attend.bias"]
    scores = np.where(mask[:, :, None] > 0.5, scores, -1e4)
    weights = np.exp(scores - scores.max(axis=1, keepdims=True))
    weights = weights / weights.sum(axis=1, keepdims=True)
    pooled = (joined * weights).sum(axis=1)
    embed = pooled @ tensors["head.weight"].T + tensors["head.bias"]
    return embed / np.maximum(np.linalg.norm(embed, axis=1, keepdims=True), 1e-12)


def load_blob(target: Path, tensors: list[tuple[str, np.ndarray]]) -> dict:
    raw = np.frombuffer(target.read_bytes(), dtype="<f4")
    cursor = 0
    out: dict = {}
    for key, values in tensors:
        size = int(values.size)
        out[key] = raw[cursor : cursor + size].reshape(values.shape).astype(np.float64)
        cursor += size
    if cursor != raw.size:
        raise SystemExit(f"the blob holds {raw.size} floats, the layout consumed {cursor}")
    aliases = {
        "frame.0.weight": "frame.0.weight",
        "frame.0.bias": "frame.0.bias",
        "attend.weight": "attend.weight",
        "attend.bias": "attend.bias",
        "head.weight": "head.weight",
        "head.bias": "head.bias",
    }
    for short, long in aliases.items():
        out[short] = out[long]
    for direction in ("", "_reverse"):
        for name in ("weight_ih", "weight_hh", "bias_ih", "bias_hh"):
            out[f"{name}{direction}"] = out[f"temporal.{name}_l0{direction}"]
    return out


DART_GOLDEN_WINDOWS = 8


def write_dart_golden(target: Path, features: np.ndarray, masks: np.ndarray, expected: np.ndarray) -> int:
    """The same windows as flat text, so a Dart test can read them without numpy.

    Python's shortest round-trip repr is exact for a float32 value, which is what
    a golden needs: the Dart encoder must land on the number torch produced, not
    on a rounded copy of it.
    """
    lines = [
        "layout_version 1",
        f"windows {DART_GOLDEN_WINDOWS}",
        f"window {features.shape[1]}",
        f"features_per_frame {features.shape[2]}",
        f"embed_dim {expected.shape[1]}",
        "features",
    ]
    for row in features[:DART_GOLDEN_WINDOWS]:
        for frame_row in row:
            lines.append(" ".join(repr(float(value)) for value in frame_row))
    lines.append("mask")
    for row in masks[:DART_GOLDEN_WINDOWS]:
        lines.append(" ".join(repr(float(value)) for value in row))
    lines.append("expected")
    for row in expected[:DART_GOLDEN_WINDOWS]:
        lines.append(" ".join(repr(float(value)) for value in row))
    target.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return DART_GOLDEN_WINDOWS


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--out", type=Path, default=None)
    parser.add_argument("--limit", type=int, default=0, help="cap the bank for a quick check")
    args = parser.parse_args(argv)
    out = args.out or args.run
    out.mkdir(parents=True, exist_ok=True)

    config = json.loads((args.run / "config.json").read_text(encoding="utf-8"))
    frame = config.get("frame", "native")
    model = tm.TrackEmbedder()
    model.load_state_dict(torch.load(args.run / "embed.pt", map_location="cpu"))
    model.eval()

    tensors = named_tensors(model)
    float_count = write_weights(tensors, out / "video_embed.f32.bin")
    blob = load_blob(out / "video_embed.f32.bin", tensors)

    bank = np.load(args.run / "bank.npz")
    vectors = bank["vectors"].astype(np.float32)
    keys = [str(key) for key in bank["keys"]]
    if args.limit:
        vectors, keys = vectors[: args.limit], keys[: args.limit]
    quantised, scale = quantise(vectors)
    (out / "video_bank.i8.bin").write_bytes(quantised.tobytes())

    clips = sorted(set(keys))
    clip_of = {key: index for index, key in enumerate(clips)}
    window_clip = np.asarray([clip_of[key] for key in keys], dtype=np.uint16)
    if len(clips) > np.iinfo(window_clip.dtype).max:
        raise SystemExit(f"{len(clips)} clips no longer fit in a uint16 window index")
    (out / "video_bank_clip_index.bin").write_bytes(window_clip.tobytes())

    # Golden windows: real clip frames, encoded by torch and by the blob.
    rng = np.random.default_rng(RNG_SEED)
    tracks = vc.load_tracks(limit=GOLDEN_TRACKS, to_wrist_frame=frame == "wrist")
    samples = [s for track in tracks for s in vc.windows(track)]
    picks = rng.choice(len(samples), size=min(GOLDEN_WINDOWS, len(samples)), replace=False)
    features = np.stack([samples[int(i)].features for i in picks])
    masks = np.stack([samples[int(i)].mask for i in picks])
    with torch.no_grad():
        expected = model(torch.from_numpy(features), torch.from_numpy(masks)).numpy()
    got = forward_numpy(features.astype(np.float64), masks.astype(np.float64), blob)
    parity = float(np.abs(expected - got).max())

    # Would the int8 bank change an answer? Collapse to the best window per clip,
    # which is what the phone does, and compare the clip it picks and the margin
    # the accept gate reads.
    def search(queries: np.ndarray, bank_matrix: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        scores = np.asarray(queries, dtype=np.float64) @ bank_matrix.T
        clip_scores = np.full((scores.shape[0], len(clips)), -np.inf)
        for column, clip in enumerate(window_clip):
            np.maximum(clip_scores[:, clip], scores[:, column], out=clip_scores[:, clip])
        second, best = np.partition(clip_scores, -2, axis=1)[:, -2], clip_scores.max(axis=1)
        return clip_scores.argmax(axis=1), best - second

    picked_float, margin_float = search(expected, vectors)
    picked_int8, margin_int8 = search(expected, quantised.astype(np.float32) * scale)
    same_pick = float((picked_float == picked_int8).mean())
    margin_shift = float(np.abs(margin_float - margin_int8).max())
    # A window the float bank already declines can pick any clip in either bank
    # and the app shows nothing either way, so those flips are reported, not
    # failed on. The ones that matter are answers the gate lets through: an
    # accepted clip the phone would name differently is a word the user is shown
    # that the measured pipeline never said.
    accepted = margin_float >= ACCEPT_MARGIN
    accepted_flips = int((picked_float[accepted] != picked_int8[accepted]).sum())
    tie_flips = int((picked_float[~accepted] != picked_int8[~accepted]).sum())

    np.savez_compressed(
        out / "video_golden.npz", features=features, mask=masks, expected=expected.astype(np.float32)
    )
    dart_golden = write_dart_golden(out / "video_golden.txt", features, masks, expected)

    manifest = {
        "layout_version": LAYOUT_VERSION,
        "feature_frame": frame,
        "features_per_frame": vc.FEATURES_PER_FRAME,
        "window": vc.WINDOW,
        "window_stride": vc.WINDOW_STRIDE,
        "embed_dim": int(tensors[-1][1].shape[0]),
        "hidden_dim": int(model.temporal.hidden_size),
        "bidirectional": bool(model.temporal.bidirectional),
        "gelu": "exact erf form, 0.5 * x * (1 + erf(x / sqrt(2))); the Dart encoder "
        "approximates erf to better than 1e-7 rather than the tanh form",
        "weights": [
            {"name": name, "shape": [int(d) for d in values.shape], "dtype": "float32"}
            for name, values in tensors
        ],
        "float_count": float_count,
        "bank": {
            "windows": int(quantised.shape[0]),
            "clips": len(clips),
            "int8_scale": scale,
            "accept_margin": ACCEPT_MARGIN,
        },
        "run": str(args.run),
        "clips": clips,
    }
    (out / "video_match_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(f"weights: {out / 'video_embed.f32.bin'} ({float_count} floats, {float_count * 4 / 1e6:.2f} MB)")
    print(f"bank: {quantised.shape[0]} windows x {quantised.shape[1]} int8, scale {scale:.6f} "
          f"({quantised.nbytes / 1e6:.2f} MB) + {window_clip.nbytes} B clip index")
    print(f"golden: {features.shape[0]} windows -> {out / 'video_golden.npz'}")
    print(f"dart golden: {dart_golden} windows -> {out / 'video_golden.txt'}")
    print(f"blob vs torch on the golden windows: max abs difference {parity:.6f}")
    print(f"int8 bank keeps the same nearest clip on {same_pick:.1%} of golden windows")
    print(
        f"of the {int(accepted.sum())} windows that clear the shipped margin {ACCEPT_MARGIN}, "
        f"int8 names a different clip on {accepted_flips}"
    )
    print(
        f"of the {int((~accepted).sum())} windows both banks decline, {tie_flips} pick a different "
        f"clip - the app shows nothing for those either way"
    )
    print(f"int8 bank moves the accept margin by at most {margin_shift:.6f}")
    ok = parity < 1e-4 and accepted_flips == 0 and margin_shift < ACCEPT_MARGIN / 4
    print("ok: the phone can read these files" if ok else "FAIL: the export is not faithful")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
