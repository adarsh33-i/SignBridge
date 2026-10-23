#!/usr/bin/env python3
"""Train the landmark embedding and build the retrieval bank.

One clip per gloss means there is nothing to supervise a classifier with, so
this trains a *matcher* instead: a small GRU encoder maps a 1.6 s window of hand
landmarks onto a 128-d unit vector, trained so that two different windows of the
same clip land closer together than either lands to any other clip (NT-Xent,
with every other clip in the batch as a negative). At recognition time the app
embeds the live window and takes the nearest reference in the bank.

The evaluation is deliberately awkward: the reference is the first half of each
clip and the queries come from the second half, so a hit cannot be a copy of the
same frames. That measures phase and speed robustness. It does not measure
cross-signer transfer, which this corpus cannot measure at all.

    python3 training/video/train_match.py --epochs 240 --batch 1024 --views-per-clip 4 \
        --export --out training/video/runs/video_match_wrist

Rows are converted to the wrist frame by default, because that is the only frame
the phone can build; `--native-frame` keeps shoulder normalisation and is a
baseline to compare against, not something to ship. `video_corpus.load_tracks`
drops the rows half-precision storage cannot describe - see `check_wrist_frame.py`
for the measurement behind that.
"""

from __future__ import annotations

import argparse
import json
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import torch
from torch import nn

import video_corpus as vc

EMBED_DIM = 128
HIDDEN_DIM = 96
BANK_WINDOWS = 6
MIN_TRACKED_FRAMES = 6
BATCH = 512
SEED = 20261023


class TrackEmbedder(nn.Module):
    def __init__(self, in_dim: int = vc.FEATURES_PER_FRAME) -> None:
        super().__init__()
        self.frame = nn.Sequential(nn.Linear(in_dim, HIDDEN_DIM), nn.GELU())
        self.temporal = nn.GRU(HIDDEN_DIM, HIDDEN_DIM, batch_first=True, bidirectional=True)
        self.attend = nn.Linear(HIDDEN_DIM * 2, 1)
        self.head = nn.Linear(HIDDEN_DIM * 2, EMBED_DIM)

    def forward(self, features: torch.Tensor, mask: torch.Tensor) -> torch.Tensor:
        hidden = self.frame(features) * mask.unsqueeze(-1)
        out, _ = self.temporal(hidden)
        scores = self.attend(out).squeeze(-1).masked_fill(mask < 0.5, -1e4)
        pooled = (out * torch.softmax(scores, dim=1).unsqueeze(-1)).sum(1)
        return nn.functional.normalize(self.head(pooled), dim=1)


@dataclass
class Corpus:
    tracks: list[vc.Track]
    skipped_short: int
    skipped_no_hand: int

    @property
    def size(self) -> int:
        return len(self.tracks)


def load_corpus(limit: int, wrist_frame: bool = True) -> Corpus:
    """Load the clips, in the wrist frame by default.

    The phone has hand landmarks and nothing else, so a bank built in the
    shoulder frame could never be matched against a live query. `vc.wrist_frame`
    converts the stored tracks into the frame the device produces; `--native-frame`
    keeps the extractor's own normalisation for comparison runs only.
    """
    usable, short, no_hand = [], 0, 0
    for track in vc.load_tracks(to_wrist_frame=wrist_frame):
        if track.tracked_frames() < MIN_TRACKED_FRAMES:
            no_hand += 1
        elif track.length < vc.WINDOW:
            short += 1
        else:
            usable.append(track)
    if limit:
        usable = usable[:limit]
    return Corpus(tracks=usable, skipped_short=short, skipped_no_hand=no_hand)


def stack(samples: list[vc.Sample], device: torch.device) -> tuple[torch.Tensor, torch.Tensor]:
    return (
        torch.from_numpy(np.stack([s.features for s in samples])).to(device),
        torch.from_numpy(np.stack([s.mask for s in samples])).to(device),
    )


@torch.no_grad()
def embed(model: nn.Module, samples: list[vc.Sample], device: torch.device) -> torch.Tensor:
    model.eval()
    chunks = [model(*stack(samples[start : start + BATCH], device)) for start in range(0, len(samples), BATCH)]
    return torch.cat(chunks) if chunks else torch.empty(0)


def train_epoch(
    model: nn.Module,
    corpus: Corpus,
    optimizer: torch.optim.Optimizer,
    device: torch.device,
    rng: np.random.Generator,
    batch: int,
    temperature: float,
    views_per_clip: int = 1,
) -> tuple[float, float]:
    """NT-Xent over two distorted views of the same clip, other clips in the
    batch acting as negatives. A margin triplet loss collapses on this data:
    every embedding equal already satisfies it.

    `views_per_clip` repeats the pass because one pair per clip is only ~20
    steps an epoch at full corpus size, which is nowhere near enough for a
    contrastive task with a few thousand classes.
    """
    model.train()
    losses: list[float] = []
    hits: list[float] = []
    for _ in range(views_per_clip):
        order = rng.permutation(corpus.size)
        for start in range(0, len(order) - batch + 1, batch):
            picks = [corpus.tracks[i] for i in order[start : start + batch]]
            pairs = [vc.sample_pair(track, rng) for track in picks]
            anchor_features, anchor_mask = stack([pair[0] for pair in pairs], device)
            positive_features, positive_mask = stack([pair[1] for pair in pairs], device)
            embedding = model(
                torch.cat([anchor_features, positive_features]),
                torch.cat([anchor_mask, positive_mask]),
            )
            rows = embedding.shape[0]
            size = rows // 2
            similarity = (embedding @ embedding.t()) / temperature
            similarity = similarity.masked_fill(
                torch.eye(rows, dtype=torch.bool, device=device), -1e4
            )
            targets = torch.cat(
                [
                    torch.arange(size, device=device) + size,
                    torch.arange(size, device=device),
                ]
            )
            loss = nn.functional.cross_entropy(similarity, targets)
            optimizer.zero_grad()
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 5.0)
            optimizer.step()
            losses.append(float(loss.detach()))
            with torch.no_grad():
                hits.append(float((similarity.argmax(dim=1) == targets).float().mean()))
    return float(np.mean(losses or [float("nan")])), float(np.mean(hits or [float("nan")]))


def bank_windows(track: vc.Track) -> list[vc.Sample]:
    """Up to BANK_WINDOWS undistorted references, spread over every stride
    position in the clip.

    Density matters more than anything else here: scoring one reference window
    per clip gives 25% top-1, two gives 46% (see training/video/README.md),
    because a sign is only recognisable from the part of its motion it is caught
    mid-way through. Overlapping windows cost bank size, not accuracy.
    """
    length = vc.WINDOW
    if track.length <= length:
        return [vc.Sample.from_block(track.features, length)]
    starts = list(range(0, track.length - length + 1, vc.WINDOW_STRIDE))
    if len(starts) > BANK_WINDOWS:
        picks = np.linspace(0, len(starts) - 1, BANK_WINDOWS).round().astype(int)
        starts = [starts[int(p)] for p in picks]
    return [vc.Sample.from_block(track.features[start : start + length], length) for start in starts]


def build_bank(model: nn.Module, corpus: Corpus, device: torch.device) -> tuple[torch.Tensor, list[str]]:
    samples: list[vc.Sample] = []
    keys: list[str] = []
    for track in corpus.tracks:
        for sample in bank_windows(track):
            samples.append(sample)
            keys.append(track.key)
    return embed(model, samples, device), keys


@dataclass
class EvalReport:
    queries: int
    clips: int
    topk: dict[int, float] = field(default_factory=dict)
    baseline_topk: dict[int, float] = field(default_factory=dict)


def rank_of_correct(bank: torch.Tensor, queries: torch.Tensor, truth: np.ndarray) -> np.ndarray:
    """1-based position of each query's own reference in its similarity ordering.

    Chunked because the full corpus would need a 25k x 11k index matrix at once.
    """
    normalized_bank = nn.functional.normalize(bank, dim=1)
    normalized_queries = nn.functional.normalize(queries, dim=1)
    truth_tensor = torch.from_numpy(truth).to(bank.device)[:, None]
    ranks: list[np.ndarray] = []
    for start in range(0, normalized_queries.shape[0], BATCH):
        block = normalized_queries[start : start + BATCH]
        similarity = block @ normalized_bank.t()
        own = similarity.gather(1, truth_tensor[start : start + BATCH])
        ranks.append((similarity > own).sum(dim=1).cpu().numpy() + 1)
    return np.concatenate(ranks)


def evaluate(
    model: nn.Module,
    corpus: Corpus,
    device: torch.device,
    topk: tuple[int, ...] = (1, 5, 10),
) -> EvalReport:
    """Match second-half query windows against first-half references."""
    references: list[vc.Sample] = []
    queries: list[vc.Sample] = []
    truth: list[int] = []
    for track in corpus.tracks:
        if track.length < 2 * vc.WINDOW:
            continue
        reference, query_windows = vc.split_windows(track, vc.WINDOW)
        position = len(references)
        references.append(reference)
        for query in query_windows:
            queries.append(query)
            truth.append(position)
    if not references or not queries:
        return EvalReport(queries=0, clips=0)

    truth_array = np.asarray(truth)
    bank = embed(model, references, device)
    embeddings = embed(model, queries, device)
    ranks = rank_of_correct(bank, embeddings, truth_array)
    baseline = rank_of_correct(
        torch.from_numpy(np.stack([_mean_pool(s) for s in references])).to(device),
        torch.from_numpy(np.stack([_mean_pool(s) for s in queries])).to(device),
        truth_array,
    )
    return EvalReport(
        queries=len(queries),
        clips=len(references),
        topk={k: float(np.mean(ranks <= k)) for k in topk},
        baseline_topk={k: float(np.mean(baseline <= k)) for k in topk},
    )


def _mean_pool(sample: vc.Sample) -> np.ndarray:
    total = float(sample.mask.sum()) or 1.0
    vector = (sample.features * sample.mask[:, None]).sum(axis=0) / total
    return (vector / (float(np.linalg.norm(vector)) or 1.0)).astype(np.float32)


def format_report(report: EvalReport) -> str:
    chance = 1.0 / max(report.clips, 1)
    lines = [
        f"disjoint-window retrieval: {report.queries} queries against {report.clips} clip references",
        f"{'metric':<8}{'embedding':>11}{'mean-pool':>11}{'chance':>9}",
    ]
    for k in sorted(report.topk):
        lines.append(
            f"top-{k:<4}"
            f"{report.topk[k] * 100:>10.2f}%"
            f"{report.baseline_topk[k] * 100:>10.2f}%"
            f"{min(1.0, k * chance) * 100:>8.4f}%"
        )
    return "\n".join(lines)


def export_onnx(model: nn.Module, out_dir: Path, device: torch.device) -> Path:
    model.eval()
    target = out_dir / "video_embed.onnx"
    torch.onnx.export(
        model,
        (
            torch.zeros(1, vc.WINDOW, vc.FEATURES_PER_FRAME, device=device),
            torch.ones(1, vc.WINDOW, device=device),
        ),
        str(target),
        input_names=["features", "mask"],
        output_names=["embedding"],
        dynamic_axes={
            "features": {0: "batch"},
            "mask": {0: "batch"},
            "embedding": {0: "batch"},
        },
        opset_version=17,
        dynamo=False,
    )
    return target


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limit", type=int, default=0, help="cap clips for a smoke run")
    parser.add_argument("--epochs", type=int, default=12)
    parser.add_argument("--batch", type=int, default=BATCH)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--temperature", type=float, default=0.1)
    parser.add_argument(
        "--views-per-clip",
        type=int,
        default=4,
        help="pair draws per clip per epoch; sets the steps in an epoch",
    )
    parser.add_argument("--out", type=Path, default=vc.VIDEO_DIR / "runs" / "video_match_v1")
    parser.add_argument(
        "--native-frame",
        action="store_true",
        help="keep shoulder normalisation; the device cannot reproduce it",
    )
    parser.add_argument("--export", action="store_true")
    parser.add_argument("--seed", type=int, default=SEED)
    args = parser.parse_args(argv)

    torch.manual_seed(args.seed)
    rng = np.random.default_rng(args.seed)
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    args.out.mkdir(parents=True, exist_ok=True)

    corpus = load_corpus(args.limit, wrist_frame=not args.native_frame)
    print(
        f"corpus: {corpus.size} clips usable, {corpus.skipped_no_hand} without a hand track, "
        f"{corpus.skipped_short} too short, device={device}"
    )

    model = TrackEmbedder().to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    schedule = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)
    started = time.perf_counter()
    for epoch in range(1, args.epochs + 1):
        loss, train_top1 = train_epoch(
            model, corpus, optimizer, device, rng, args.batch, args.temperature, args.views_per_clip
        )
        schedule.step()
        report = evaluate(model, corpus, device)
        print(
            f"epoch {epoch:2d} loss {loss:.4f} batch-top1 {train_top1 * 100:.1f}% "
            f"top1 {report.topk[1] * 100:.2f}% top5 {report.topk[5] * 100:.2f}% "
            f"({time.perf_counter() - started:.0f}s)"
        )

    final = evaluate(model, corpus, device)
    text = format_report(final)
    print(text)
    (args.out / "eval.txt").write_text(text + "\n", encoding="utf-8")

    torch.save(model.state_dict(), args.out / "embed.pt")
    bank, keys = build_bank(model, corpus, device)
    np.savez_compressed(
        args.out / "bank.npz",
        keys=np.array(keys),
        vectors=bank.detach().cpu().numpy().astype(np.float16),
    )
    (args.out / "config.json").write_text(
        json.dumps(
            {
                "window": vc.WINDOW,
                "frame": "native" if args.native_frame else "wrist",
                "features_per_frame": vc.FEATURES_PER_FRAME,
                "embed_dim": EMBED_DIM,
                "bank_windows": BANK_WINDOWS,
                "clips": corpus.size,
                "epochs": args.epochs,
                "views_per_clip": args.views_per_clip,
                "temperature": args.temperature,
                "topk": final.topk,
                "mean_pool_topk": final.baseline_topk,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"bank: {len(keys)} vectors -> {args.out / 'bank.npz'}")

    if args.export:
        target = export_onnx(model, args.out, device)
        print(f"exported {target} ({target.stat().st_size / 1e6:.2f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
