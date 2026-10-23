#!/usr/bin/env python3
"""Verify a trained matcher end to end and measure what the phone will see.

Checks that the exported ONNX encoder agrees with PyTorch, that the shipped bank
reproduces the retrieval numbers, how long one query takes on a single CPU thread
(the phone budget), and where to put the confidence cut-off — the app needs to
know when to say "unclear" instead of naming a word it is not sure of.

    python3 training/video/verify_video_match.py --run training/video/runs/video_match_v1
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import numpy as np
import torch

import train_match as tm
import video_corpus as vc


def disjoint_bank_windows(track: vc.Track, length: int = vc.WINDOW, count: int = 3) -> list[vc.Sample]:
    """Several references per clip, all inside the first half so no query frame is
    ever in the bank it is scored against. The shipped bank uses the whole clip;
    measuring with whole-clip references would score the query against itself."""
    half = track.features[: max(1, track.length // 2)]
    if len(half) <= length:
        return [vc.Sample.from_block(half, length)]
    slots = min(count, (len(half) - 1) // length + 1)
    starts = np.linspace(0, len(half) - length, slots).round().astype(int)
    return [vc.Sample.from_block(half[start : start + length], length) for start in starts]


def eval_pairs(corpus: tm.Corpus) -> tuple[list[vc.Sample], list[str], list[vc.Sample], list[str]]:
    """First-half references, second-half queries, and the clip each came from."""
    references: list[vc.Sample] = []
    reference_keys: list[str] = []
    queries: list[vc.Sample] = []
    query_keys: list[str] = []
    for track in corpus.tracks:
        if track.length < 2 * vc.WINDOW:
            continue
        reference, query_windows = vc.split_windows(track, vc.WINDOW)
        references.append(reference)
        reference_keys.append(track.key)
        for query in query_windows:
            queries.append(query)
            query_keys.append(track.key)
    return references, reference_keys, queries, query_keys


def collapse_by_key(similarity: np.ndarray, keys: np.ndarray) -> tuple[np.ndarray, list[str]]:
    """Score a bank that holds several windows per clip: best window wins."""
    order = np.concatenate([[True], keys[1:] != keys[:-1]])
    grouped = np.maximum.reduceat(similarity, np.flatnonzero(order), axis=1)
    unique: list[str] = []
    for index, key in enumerate(keys):
        if order[index]:
            unique.append(str(key))
    return grouped, unique


def truth_positions(keys: list[str], unique: list[str]) -> np.ndarray:
    position = {key: index for index, key in enumerate(unique)}
    return np.asarray([position[key] for key in keys])


def top_k(similarity: np.ndarray, truth: np.ndarray, topk: tuple[int, ...]) -> dict[int, float]:
    own = np.take_along_axis(similarity, truth[:, None], 1)
    ranks = (similarity > own).sum(axis=1) + 1
    return {k: float(np.mean(ranks <= k)) for k in topk}


GAP_CUTS = (0.0, 0.01, 0.02, 0.05, 0.10, 0.20)


def operating_curve(similarity: np.ndarray, truth: np.ndarray) -> list[str]:
    """How often the right clip wins by a wide enough margin.

    The app needs a cut-off: answer only when the best match is clearly ahead of
    the runner-up. Precision inside this set is 100% by construction (a positive
    margin is what "top-1" means), so the number that matters is the coverage the
    cut-off leaves behind.
    """
    own = np.take_along_axis(similarity, truth[:, None], 1)[:, 0]
    masked = similarity.copy()
    masked[np.arange(len(truth)), truth] = -1.0
    gap = own - masked.max(axis=1)
    correct = gap > 0
    lines = [
        f"margin of the right clip over the runner-up: "
        f"p50 {np.percentile(gap[correct], 50) if correct.any() else float('nan'):.3f} when it wins, "
        f"p50 {np.percentile(gap[~correct], 50) if (~correct).any() else float('nan'):.3f} when it loses"
    ]
    lines.append(f"{'min margin':>12}{'answered':>10}{'of those correct':>18}")
    for cut in GAP_CUTS:
        keep = gap >= cut
        lines.append(
            f"{cut:>12.2f}{keep.mean():>9.1%}{(100.0 if not keep.any() else correct[keep].mean() * 100):>17.1f}%"
        )
    return lines


def onnx_embeddings(path: Path, samples: list[vc.Sample]) -> np.ndarray:
    import onnxruntime as ort

    session = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
    features = np.stack([s.features for s in samples])
    masks = np.stack([s.mask for s in samples])
    out = np.empty((len(samples), tm.EMBED_DIM), dtype=np.float32)
    for start in range(0, len(samples), tm.BATCH):
        stop = min(start + tm.BATCH, len(samples))
        out[start:stop] = session.run(
            ["embedding"], {"features": features[start:stop], "mask": masks[start:stop]}
        )[0]
    return out


def timed_single_query(path: Path, sample: vc.Sample) -> float:
    import onnxruntime as ort

    options = ort.SessionOptions()
    options.intra_op_num_threads = 1
    session = ort.InferenceSession(str(path), sess_options=options, providers=["CPUExecutionProvider"])
    features, mask = sample.features[None], sample.mask[None]
    session.run(["embedding"], {"features": features, "mask": mask})
    started = time.perf_counter()
    for _ in range(50):
        session.run(["embedding"], {"features": features, "mask": mask})
    return (time.perf_counter() - started) / 50 * 1000


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, default=vc.VIDEO_DIR / "runs" / "video_match_v1")
    parser.add_argument("--limit", type=int, default=0)
    args = parser.parse_args(argv)

    config = json.loads((args.run / "config.json").read_text(encoding="utf-8"))
    # Runs written before the frame was recorded trained in the extractor's own
    # shoulder normalisation, so that is the default for them.
    frame = config.get("frame", "native")
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    stored = np.load(args.run / "bank.npz")
    bank_keys = stored["keys"]
    bank = stored["vectors"].astype(np.float32)
    corpus = tm.load_corpus(args.limit, wrist_frame=frame == "wrist")
    in_bank = set(str(key) for key in bank_keys)
    all_clips = corpus.size
    corpus = tm.Corpus(
        tracks=[track for track in corpus.tracks if track.key in in_bank],
        skipped_short=corpus.skipped_short,
        skipped_no_hand=corpus.skipped_no_hand,
    )
    references, reference_keys, queries, query_keys = eval_pairs(corpus)
    print(
        f"corpus {all_clips} clips, {corpus.size} of them in this bank; "
        f"{len(references)} references, {len(queries)} queries"
    )

    model = tm.TrackEmbedder().to(device)
    model.load_state_dict(torch.load(args.run / "embed.pt", map_location=device))
    torch_queries = tm.embed(model, queries, device).cpu().numpy()
    torch_references = tm.embed(model, references, device).cpu().numpy()

    lines = [
        f"run: {args.run.name}",
        f"trained on {config['clips']} clips, window {config['window']} frames, "
        f"{config['epochs']} epochs, temperature {config.get('temperature')}",
        f"feature frame: {frame} ({'what the phone can build' if frame == 'wrist' else 'shoulder normalised, not reachable on device'})",
        f"eval: {len(queries)} second-half queries against {len(references)} first-half references",
    ]

    onnx_path = args.run / "video_embed.onnx"
    if onnx_path.is_file():
        onnx_queries = onnx_embeddings(onnx_path, queries)
        parity = float(np.abs(onnx_queries - torch_queries).max())
        lines.append(f"onnx vs torch parity: max abs difference {parity:.5f} over {len(queries)} queries")
        lines.append(f"onnx latency: {timed_single_query(onnx_path, queries[0]):.2f} ms per query, 1 CPU thread")
    else:
        onnx_queries = torch_queries
        lines.append("onnx: not exported, scoring with the torch encoder")

    single_scores = top_k(
        onnx_queries @ torch_references.T, truth_positions(query_keys, reference_keys), (1, 5, 10)
    )
    chance = 1.0 / max(len(reference_keys), 1)
    for k in sorted(single_scores):
        lines.append(
            f"single-window disjoint bank top-{k}: {single_scores[k] * 100:.2f}% "
            f"(chance {min(1.0, k * chance) * 100:.4f}%)"
        )

    multi: list[vc.Sample] = []
    multi_keys: list[str] = []
    for track in corpus.tracks:
        if track.length < 2 * vc.WINDOW:
            continue
        for sample in disjoint_bank_windows(track):
            multi.append(sample)
            multi_keys.append(track.key)
    multi_bank = tm.embed(model, multi, device).cpu().numpy()
    similarity, unique = collapse_by_key(onnx_queries @ multi_bank.T, np.asarray(multi_keys))
    truth = truth_positions(query_keys, unique)
    scores = top_k(similarity, truth, (1, 5, 10))
    multi_chance = 1.0 / max(len(unique), 1)
    lines.append(
        f"{len(multi) // max(len(unique), 1)}-window disjoint bank, {len(unique)} clips: "
        + "  ".join(
            f"top-{k} {scores[k] * 100:.2f}% (chance {min(1.0, k * multi_chance) * 100:.4f}%)"
            for k in sorted(scores)
        )
    )
    lines.append(
        f"shipped bank on disk: {len(set(str(key) for key in bank_keys))} clips, "
        f"{len(bank_keys)} windows, {bank.shape[1]} dims, "
        f"{(args.run / 'bank.npz').stat().st_size / 1e6:.2f} MB (whole clips, so it is never "
        f"the bank these scores are computed against)"
    )
    lines.append("")
    lines.extend(operating_curve(similarity, truth))
    lines.append("")
    lines.append(
        "what this cannot measure: a different signer. Every gloss here has exactly one "
        "clip by one signer, so cross-signer accuracy is unknown - only phase, speed, "
        "framing and hand-mirroring robustness are covered by these numbers."
    )

    text = "\n".join(lines)
    print(text)
    (args.run / "verify.txt").write_text(text + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
