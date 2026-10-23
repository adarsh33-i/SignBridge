#!/usr/bin/env python3
"""Train a tiny caption→gloss seq2seq student on rule-engine corpus pairs.

Data rows (JSONL): {"x": "prepared english tokens", "y": "GLOSS TOKENS",
"system": "asl"|"isl", "source": "..."}

The rule engine is the teacher (distillation). One small BiGRU encoder +
attention decoder serves both ASL and ISL grammars via a control token.

Usage:
  python3 training/train.py --data training/data --out training/runs/gloss_rnn
"""

from __future__ import annotations

import argparse
import json
import random
import re
import time
from collections import Counter
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader, Dataset

PAD, UNK, BOS, EOS = 0, 1, 2, 3

TOKEN_RE = re.compile(r"[a-z0-9]+(?:'[a-z]+)?(?:-[a-z0-9]+)*")


def tokenize_source(text: str, system: str) -> list[str]:
    return [f"<{system}>", *TOKEN_RE.findall(text.lower())]


def tokenize_target(text: str) -> list[str]:
    return text.split()


class Vocab:
    def __init__(self, tokens: list[str], max_size: int | None = None) -> None:
        counts = Counter(tokens)
        items = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
        if max_size is not None:
            items = items[:max_size]
        self.itos = ["<pad>", "<unk>", "<bos>", "<eos>"] + [t for t, _ in items]
        self.stoi = {t: i for i, t in enumerate(self.itos)}

    def encode(self, tokens: list[str]) -> list[int]:
        return [self.stoi.get(t, UNK) for t in tokens]

    def decode(self, ids: list[int]) -> list[str]:
        out = []
        for i in ids:
            if i == EOS:
                break
            if i in (PAD, BOS):
                continue
            out.append(self.itos[i])
        return out

    def __len__(self) -> int:
        return len(self.itos)


def load_rows(path: Path) -> list[dict]:
    rows = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


class PairDataset(Dataset):
    def __init__(
        self,
        rows: list[dict],
        src_vocab: Vocab,
        tgt_vocab: Vocab,
        max_src: int = 24,
        max_tgt: int = 32,
    ) -> None:
        self.data: list[tuple[list[int], list[int], str]] = []
        for row in rows:
            src = src_vocab.encode(tokenize_source(row["x"], row["system"]))[:max_src]
            tgt = tgt_vocab.encode(tokenize_target(row["y"]))[: max_tgt - 1] + [EOS]
            if len(tgt) < 2:
                continue
            self.data.append((src, tgt, row["system"]))

    def __len__(self) -> int:
        return len(self.data)

    def __getitem__(self, index: int):
        return self.data[index]


def collate(batch):
    src_list, tgt_list, systems = zip(*batch)
    src_len = torch.tensor([len(s) for s in src_list], dtype=torch.long)
    tgt_len = torch.tensor([len(t) for t in tgt_list], dtype=torch.long)
    src = torch.full((len(batch), int(src_len.max())), PAD, dtype=torch.long)
    tgt_in = torch.full((len(batch), int(tgt_len.max())), PAD, dtype=torch.long)
    tgt_out = torch.full((len(batch), int(tgt_len.max())), PAD, dtype=torch.long)
    for i, (s, t) in enumerate(zip(src_list, tgt_list)):
        src[i, : len(s)] = torch.tensor(s)
        tgt_in[i, 0] = BOS
        tgt_in[i, 1 : len(t)] = torch.tensor(t[:-1])
        tgt_out[i, : len(t)] = torch.tensor(t)
    return src, src_len, tgt_in, tgt_out, systems


def apply_src_dropout(src: torch.Tensor, rate: float) -> torch.Tensor:
    """Replace source words with UNK, protecting the system control token."""
    if rate <= 0.0:
        return src
    keep = torch.rand(src.shape, device=src.device) >= rate
    protected = src == PAD
    protected[:, 0] = True
    src = src.clone()
    src[~keep & ~protected] = UNK
    return src


class Encoder(nn.Module):
    def __init__(self, vocab_size: int, emb: int, hidden: int, dropout: float) -> None:
        super().__init__()
        self.hidden = hidden
        self.embed = nn.Embedding(vocab_size, emb, padding_idx=PAD)
        self.dropout = nn.Dropout(dropout)
        self.rnn = nn.GRU(emb, hidden, batch_first=True, bidirectional=True)

    def forward(self, src: torch.Tensor, src_len: torch.Tensor):
        out, _ = self.rnn(self.dropout(self.embed(src)))
        last = (src_len - 1).clamp(min=0).view(-1, 1, 1).expand(-1, 1, self.hidden)
        h_fwd = out[:, :, : self.hidden].gather(1, last).squeeze(1)
        h_bwd = out[:, 0, self.hidden :]
        return out, torch.cat([h_fwd, h_bwd], dim=-1)


class Decoder(nn.Module):
    """One attention step shared by teacher forcing and greedy decoding."""

    def __init__(
        self,
        vocab_size: int,
        emb: int,
        enc_dim: int,
        hidden: int,
        dropout: float,
    ) -> None:
        super().__init__()
        self.embed = nn.Embedding(vocab_size, emb, padding_idx=PAD)
        self.dropout = nn.Dropout(dropout)
        self.bridge = nn.Linear(enc_dim, hidden)
        self.attn_enc = nn.Linear(enc_dim, hidden)
        self.attn_dec = nn.Linear(hidden, hidden)
        self.v = nn.Linear(hidden, 1, bias=False)
        self.rnn = nn.GRU(emb + enc_dim, hidden, batch_first=True)
        self.out = nn.Linear(hidden + enc_dim + emb, vocab_size)

    def init_hidden(self, enc_h: torch.Tensor) -> torch.Tensor:
        return torch.tanh(self.bridge(enc_h)).unsqueeze(0)

    def step(
        self,
        y_prev: torch.Tensor,
        h: torch.Tensor,
        enc_out: torch.Tensor,
        keys: torch.Tensor,
        mask: torch.Tensor,
    ):
        emb = self.dropout(self.embed(y_prev))
        query = self.attn_dec(h.squeeze(0))
        scores = self.v(torch.tanh(keys + query.unsqueeze(1))).squeeze(-1)
        scores = scores.masked_fill(mask, -1e9)
        alpha = F.softmax(scores, dim=-1)
        ctx = torch.bmm(alpha.unsqueeze(1), enc_out).squeeze(1)
        rnn_in = torch.cat([emb, ctx], dim=-1).unsqueeze(1)
        out, h = self.rnn(rnn_in, h)
        logits = self.out(torch.cat([out.squeeze(1), ctx, emb], dim=-1))
        return logits, h


class GlossSeq2Seq(nn.Module):
    def __init__(
        self,
        src_vocab: int,
        tgt_vocab: int,
        emb: int = 96,
        enc_hidden: int = 128,
        dec_hidden: int = 256,
        dropout: float = 0.2,
    ) -> None:
        super().__init__()
        enc_dim = enc_hidden * 2
        self.max_decode = 32
        self.encoder = Encoder(src_vocab, emb, enc_hidden, dropout)
        self.decoder = Decoder(tgt_vocab, emb, enc_dim, dec_hidden, dropout)

    def encode(self, src: torch.Tensor, src_len: torch.Tensor):
        mask = src == PAD
        enc_out, enc_h = self.encoder(src, src_len)
        keys = self.decoder.attn_enc(enc_out)
        return enc_out, enc_h, keys, mask

    def forward(
        self,
        src: torch.Tensor,
        src_len: torch.Tensor,
        tgt_in: torch.Tensor,
    ) -> torch.Tensor:
        enc_out, enc_h, keys, mask = self.encode(src, src_len)
        h = self.decoder.init_hidden(enc_h)
        logits = []
        for t in range(tgt_in.size(1)):
            step_logits, h = self.decoder.step(
                tgt_in[:, t], h, enc_out, keys, mask
            )
            logits.append(step_logits)
        return torch.stack(logits, dim=1)

    def greedy(self, src: torch.Tensor, src_len: torch.Tensor) -> torch.Tensor:
        enc_out, enc_h, keys, mask = self.encode(src, src_len)
        h = self.decoder.init_hidden(enc_h)
        batch = src.size(0)
        prev = torch.full((batch,), BOS, dtype=torch.long, device=src.device)
        done = torch.zeros(batch, dtype=torch.bool, device=src.device)
        tokens = []
        for _ in range(self.max_decode):
            logits, h = self.decoder.step(prev, h, enc_out, keys, mask)
            nxt = logits.argmax(-1)
            nxt = torch.where(done, torch.full_like(nxt, PAD), nxt)
            tokens.append(nxt.unsqueeze(1))
            done = done | (nxt == EOS)
            prev = nxt
        return torch.cat(tokens, dim=1)


def evaluate(model: GlossSeq2Seq, loader: DataLoader, tgt_vocab: Vocab, device: torch.device):
    model.eval()
    total_tokens = 0
    correct_tokens = 0
    exact = 0
    total = 0
    by_system: dict[str, list[int]] = {"asl": [0, 0], "isl": [0, 0]}
    with torch.no_grad():
        for src, src_len, tgt_in, tgt_out, systems in loader:
            src, src_len = src.to(device), src_len.to(device)
            tgt_in, tgt_out = tgt_in.to(device), tgt_out.to(device)
            logits = model(src, src_len, tgt_in)
            pred = logits.argmax(-1)
            mask = tgt_out != PAD
            correct_tokens += int(((pred == tgt_out) & mask).sum().item())
            total_tokens += int(mask.sum().item())
            gen = model.greedy(src, src_len)
            for i, system in enumerate(systems):
                total += 1
                by_system.setdefault(system, [0, 0])[1] += 1
                match = tgt_vocab.decode(gen[i].tolist()) == tgt_vocab.decode(
                    tgt_out[i].tolist()
                )
                exact += int(match)
                by_system[system][0] += int(match)
    model.train()
    return {
        "token_acc": correct_tokens / max(1, total_tokens),
        "exact": exact / max(1, total),
        "asl_exact": by_system["asl"][0] / max(1, by_system["asl"][1]),
        "isl_exact": by_system["isl"][0] / max(1, by_system["isl"][1]),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", default="training/data")
    parser.add_argument("--out", default="training/runs/gloss_rnn")
    parser.add_argument("--epochs", type=int, default=40)
    parser.add_argument("--batch", type=int, default=128)
    parser.add_argument("--lr", type=float, default=1.5e-3)
    parser.add_argument("--emb", type=int, default=128)
    parser.add_argument("--enc-hidden", type=int, default=160)
    parser.add_argument("--dec-hidden", type=int, default=320)
    parser.add_argument("--dropout", type=float, default=0.2)
    parser.add_argument("--label-smoothing", type=float, default=0.05)
    parser.add_argument("--src-dropout", type=float, default=0.05)
    parser.add_argument("--max-src-vocab", type=int, default=20000)
    parser.add_argument("--seed", type=int, default=20261019)
    args = parser.parse_args()

    random.seed(args.seed)
    torch.manual_seed(args.seed)

    data_dir = Path(args.data)
    train_rows = load_rows(data_dir / "train.jsonl")
    val_rows = load_rows(data_dir / "val.jsonl")
    test_rows = (
        load_rows(data_dir / "test.jsonl")
        if (data_dir / "test.jsonl").exists()
        else []
    )
    ood_rows = (
        load_rows(data_dir / "ood.jsonl")
        if (data_dir / "ood.jsonl").exists()
        else []
    )

    src_vocab = Vocab(
        [t for r in train_rows for t in tokenize_source(r["x"], r["system"])],
        max_size=args.max_src_vocab,
    )
    tgt_vocab = Vocab([t for r in train_rows for t in tokenize_target(r["y"])])
    print(f"train={len(train_rows)} val={len(val_rows)} "
          f"test={len(test_rows)} ood={len(ood_rows)} "
          f"src_vocab={len(src_vocab)} tgt_vocab={len(tgt_vocab)}")

    train_ds = PairDataset(train_rows, src_vocab, tgt_vocab)
    val_ds = PairDataset(val_rows, src_vocab, tgt_vocab)
    train_loader = DataLoader(
        train_ds, batch_size=args.batch, shuffle=True, collate_fn=collate
    )
    val_loader = DataLoader(
        val_ds, batch_size=args.batch, shuffle=False, collate_fn=collate
    )
    test_loader = (
        DataLoader(
            PairDataset(test_rows, src_vocab, tgt_vocab),
            batch_size=args.batch,
            shuffle=False,
            collate_fn=collate,
        )
        if test_rows
        else None
    )
    ood_loader = (
        DataLoader(
            PairDataset(ood_rows, src_vocab, tgt_vocab),
            batch_size=args.batch,
            shuffle=False,
            collate_fn=collate,
        )
        if ood_rows
        else None
    )

    device = torch.device(
        "mps" if torch.backends.mps.is_available() else "cpu"
    )
    model = GlossSeq2Seq(
        len(src_vocab),
        len(tgt_vocab),
        emb=args.emb,
        enc_hidden=args.enc_hidden,
        dec_hidden=args.dec_hidden,
        dropout=args.dropout,
    ).to(device)
    params = sum(p.numel() for p in model.parameters())
    print(f"device={device} params={params / 1e6:.2f}M")

    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.ReduceLROnPlateau(
        optimizer, mode="max", factor=0.5, patience=1
    )
    criterion = nn.CrossEntropyLoss(
        ignore_index=PAD, label_smoothing=args.label_smoothing
    )

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "vocab.json").write_text(
        json.dumps(
            {
                "src_itos": src_vocab.itos,
                "tgt_itos": tgt_vocab.itos,
                "config": {
                    "emb": args.emb,
                    "enc_hidden": args.enc_hidden,
                    "dec_hidden": args.dec_hidden,
                    "dropout": args.dropout,
                    "label_smoothing": args.label_smoothing,
                    "src_dropout": args.src_dropout,
                    "max_src": 24,
                    "max_tgt": 32,
                },
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    best_exact = -1.0
    for epoch in range(1, args.epochs + 1):
        model.train()
        started = time.time()
        running = 0.0
        batches = 0
        for src, src_len, tgt_in, tgt_out, _ in train_loader:
            src, src_len = src.to(device), src_len.to(device)
            tgt_in, tgt_out = tgt_in.to(device), tgt_out.to(device)
            src = apply_src_dropout(src, args.src_dropout)
            logits = model(src, src_len, tgt_in)
            loss = criterion(
                logits.reshape(-1, logits.size(-1)), tgt_out.reshape(-1)
            )
            optimizer.zero_grad(set_to_none=True)
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            running += float(loss.item())
            batches += 1

        metrics = evaluate(model, val_loader, tgt_vocab, device)
        ood_metrics = (
            evaluate(model, ood_loader, tgt_vocab, device) if ood_loader else None
        )
        scheduler.step(metrics["exact"])
        elapsed = time.time() - started
        ood_text = (
            f" ood={ood_metrics['exact']:.4f}" if ood_metrics is not None else ""
        )
        print(
            f"epoch {epoch:02d} loss={running / max(1, batches):.4f} "
            f"tok_acc={metrics['token_acc']:.4f} exact={metrics['exact']:.4f} "
            f"(asl={metrics['asl_exact']:.4f} isl={metrics['isl_exact']:.4f})"
            f"{ood_text} {elapsed:.0f}s"
        )

        if metrics["exact"] > best_exact:
            best_exact = metrics["exact"]
            checkpoint = {
                "model": model.state_dict(),
                "metrics": metrics,
                "epoch": epoch,
            }
            if ood_metrics is not None:
                checkpoint["ood"] = ood_metrics
            torch.save(checkpoint, out_dir / "best.pt")
            print(f"  saved best.pt (exact={best_exact:.4f})")

    print(f"done. best val exact={best_exact:.4f} -> {out_dir / 'best.pt'}")

    if test_loader is not None:
        checkpoint = torch.load(out_dir / "best.pt", map_location=device)
        model.load_state_dict(checkpoint["model"])
        test_metrics = evaluate(model, test_loader, tgt_vocab, device)
        print(
            f"test tok_acc={test_metrics['token_acc']:.4f} "
            f"exact={test_metrics['exact']:.4f} "
            f"(asl={test_metrics['asl_exact']:.4f} isl={test_metrics['isl_exact']:.4f})"
        )
        if ood_loader is not None:
            ood_final = evaluate(model, ood_loader, tgt_vocab, device)
            print(
                f"ood  tok_acc={ood_final['token_acc']:.4f} "
                f"exact={ood_final['exact']:.4f} "
                f"(asl={ood_final['asl_exact']:.4f} isl={ood_final['isl_exact']:.4f})"
            )


if __name__ == "__main__":
    main()
