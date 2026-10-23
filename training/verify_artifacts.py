#!/usr/bin/env python3
"""Audit a trained run and its ONNX exports without retraining or re-exporting.

Usage:
  python3 training/verify_artifacts.py --run training/runs/gloss_rnn_v4
  python3 training/verify_artifacts.py --run ... --samples 256 --splits val ood

Checks vocab.json against the checkpoint state dict, scores greedy output
against the gold glosses per split and per corpus source, reports how often
the tokenizer has to fall back to UNK (the app's hybrid trigger), and compares
ONNX fp32 / int8 against PyTorch greedy on the same samples.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from export_onnx import encode_batch, vocab_from_itos  # noqa: E402
from train import GlossSeq2Seq, load_rows, tokenize_source  # noqa: E402

PAD, UNK, BOS, EOS = 0, 1, 2, 3


def expected_shapes(config: dict) -> dict[str, tuple[int, ...]]:
    emb, enc, dec = config["emb"], config["enc_hidden"], config["dec_hidden"]
    ctx = 2 * enc
    return {
        "decoder.bridge.weight": (dec, ctx),
        "decoder.attn_enc.weight": (dec, ctx),
        "decoder.attn_dec.weight": (dec, dec),
        "decoder.v.weight": (1, dec),
        "decoder.rnn.weight_ih_l0": (3 * dec, emb + ctx),
        "decoder.rnn.weight_hh_l0": (3 * dec, dec),
    }


def check_state_dict(state: dict, src_vocab: Vocab, tgt_vocab: Vocab,
                     config: dict) -> list[str]:
    problems = []
    shapes = {
        "encoder.embed.weight": (len(src_vocab), config["emb"]),
        "encoder.rnn.weight_ih_l0": (3 * config["enc_hidden"], config["emb"]),
        "encoder.rnn.weight_hh_l0": (3 * config["enc_hidden"], config["enc_hidden"]),
        "decoder.out.weight": (
            len(tgt_vocab),
            config["dec_hidden"] + config["emb"] + 2 * config["enc_hidden"],
        ),
    }
    shapes.update(expected_shapes(config))
    for name, want in shapes.items():
        got = tuple(state[name].shape)
        if got != want:
            problems.append(f"{name}: state_dict {got} != config {want}")
    if tuple(state["encoder.rnn.weight_ih_l0_reverse"].shape) != \
            tuple(state["encoder.rnn.weight_ih_l0"].shape):
        problems.append("encoder is not bidirectional with matched directions")
    return problems


def strip(ids: list[int]) -> list[int]:
    out = []
    for value in ids:
        if value == EOS:
            break
        out.append(value)
    return out


def even_idxs(length: int, count: int) -> list[int]:
    count = min(count, length)
    return [i * length // count for i in range(count)]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", default="training/runs/gloss_rnn_v4")
    parser.add_argument("--data", default="training/data")
    parser.add_argument("--export", default="training/export")
    parser.add_argument("--splits", nargs="+",
                        default=["val", "test", "ood"])
    parser.add_argument("--samples", type=int, default=512)
    args = parser.parse_args()

    run_dir = Path(args.run)
    meta = json.loads((run_dir / "vocab.json").read_text(encoding="utf-8"))
    config = meta["config"]
    src_vocab = vocab_from_itos(meta["src_itos"])
    tgt_vocab = vocab_from_itos(meta["tgt_itos"])
    print(f"run={run_dir} src_vocab={len(src_vocab)} "
          f"tgt_vocab={len(tgt_vocab)} params_config={config}")

    model = GlossSeq2Seq(
        len(src_vocab),
        len(tgt_vocab),
        emb=config["emb"],
        enc_hidden=config["enc_hidden"],
        dec_hidden=config["dec_hidden"],
        dropout=0.0,
    )
    checkpoint = torch.load(run_dir / "best.pt", map_location="cpu")
    state = checkpoint["model"]
    model.load_state_dict(state)
    model.eval()
    params = sum(p.numel() for p in model.parameters())
    problems = check_state_dict(state, src_vocab, tgt_vocab, config)
    print(f"params={params / 1e6:.2f}M best_epoch={checkpoint.get('epoch')}")
    print("state_dict vs vocab config: "
          + ("OK" if not problems else "MISMATCH"))
    for problem in problems:
        print(f"  ! {problem}")
    stored = checkpoint.get("metrics") or {}
    if stored:
        print("stored val metrics: " + ", ".join(
            f"{k}={v:.4f}" for k, v in stored.items()))

    onnx_paths = [Path(args.export) / name for name in
                  ("gloss_seq2seq.onnx", "gloss_seq2seq.int8.onnx")]
    sessions = {}
    if all(p.exists() for p in onnx_paths):
        import onnxruntime as ort

        for path in onnx_paths:
            sessions[path.name] = ort.InferenceSession(
                str(path), providers=["CPUExecutionProvider"])
        for path in onnx_paths:
            print(f"{path.name}: {path.stat().st_size / 1e6:.2f} MB")
    else:
        print("onnx: export files missing, skipping parity check")

    for split in args.splits:
        rows = load_rows(Path(args.data) / f"{split}.jsonl")
        idxs = even_idxs(len(rows), args.samples)
        src, src_len, batch = encode_batch(rows, src_vocab, idxs)
        with torch.no_grad():
            reference = model.greedy(src, src_len).tolist()

        unk_rows = 0
        exact = 0
        by_source: dict[str, list[int]] = defaultdict(lambda: [0, 0])
        for row, ids in zip(batch, reference):
            tokens = tokenize_source(row["x"], row["system"])
            unk_rows += any(t not in src_vocab.stoi for t in tokens)
            ref = [tgt_vocab.stoi.get(t, UNK) for t in row["y"].split()]
            hit = strip(ids) == ref
            exact += hit
            bucket = by_source[row.get("source", "?")]
            bucket[0] += hit
            bucket[1] += 1

        parity = {}
        for name, session in sessions.items():
            out = session.run(None, {
                "src": src.numpy().astype(np.int64),
                "src_len": src_len.numpy().astype(np.int64),
            })[0].tolist()
            parity[name] = sum(strip(a) == strip(b)
                               for a, b in zip(reference, out))

        print(f"\n[{split}] n={len(batch)} exact={exact}/{len(batch)} "
              f"({exact / len(batch):.4f}) source_tokens_unknown="
              f"{unk_rows}/{len(batch)} ({unk_rows / len(batch):.3f})")
        for source, (hits, total) in sorted(by_source.items()):
            print(f"  {source:<18} {hits}/{total} ({hits / total:.4f})")
        for name, hits in parity.items():
            print(f"  {name} == torch greedy: {hits}/{len(batch)}")


if __name__ == "__main__":
    main()
