#!/usr/bin/env python3
"""Run the trained gloss model on prepared English captions.

Usage:
  python3 training/predict.py --system asl "I need to buy medicine for my mother"
  python3 training/predict.py --system isl "today I go hospital"

Input must be the prepared English token string (the app produces it with
SpokenTextPrep before calling the model).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from train import GlossSeq2Seq, Vocab, tokenize_source  # noqa: E402


def vocab_from_itos(itos: list[str]) -> Vocab:
    vocab = Vocab([])
    vocab.itos = itos
    vocab.stoi = {t: i for i, t in enumerate(itos)}
    return vocab


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("text", nargs="+")
    parser.add_argument("--run", default="training/runs/gloss_rnn_v4")
    parser.add_argument("--system", choices=["asl", "isl"], default="asl")
    args = parser.parse_args()

    run_dir = Path(args.run)
    meta = json.loads((run_dir / "vocab.json").read_text(encoding="utf-8"))
    config = meta["config"]
    src_vocab = vocab_from_itos(meta["src_itos"])
    tgt_vocab = vocab_from_itos(meta["tgt_itos"])

    model = GlossSeq2Seq(
        len(src_vocab),
        len(tgt_vocab),
        emb=config["emb"],
        enc_hidden=config["enc_hidden"],
        dec_hidden=config["dec_hidden"],
        dropout=0.0,
    )
    checkpoint = torch.load(run_dir / "best.pt", map_location="cpu")
    model.load_state_dict(checkpoint["model"])
    model.eval()

    text = " ".join(args.text)
    ids = src_vocab.encode(tokenize_source(text, args.system))[:24]
    src = torch.tensor([ids], dtype=torch.long)
    src_len = torch.tensor([len(ids)], dtype=torch.long)

    with torch.no_grad():
        output = model.greedy(src, src_len)
    gloss = " ".join(tgt_vocab.decode(output[0].tolist()))
    print(f"input : {text}")
    print(f"system: {args.system}")
    print(f"gloss : {gloss}")


if __name__ == "__main__":
    main()
