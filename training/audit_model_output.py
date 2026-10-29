#!/usr/bin/env python3
"""Audit the exported gloss model against the caption-to-gloss invariants.

The Dart audit (`test/services/caption_gloss_audit_test.dart`) measures the
rule engine. This measures the model the app actually loads — the int8 ONNX
export — on the same corpus splits, and applies the invariants that do not
depend on which path produced the gloss:

  empty             a non-empty caption must not produce an empty gloss
  label             every token must look like gloss notation
  negation lost     a negated caption must keep NOT / NO / NEVER / [headshake]
  WILL lost         a future caption must keep WILL
  untraced token    a content token must trace to a caption word, its lemma, a
                    documented rewrite or the engine's own gloss for that row;
                    a distilled student may drift, so this is capped (default
                    1% of output tokens), not held at zero
  non-deterministic the same caption must give the same signs when the batch is
                    run again unchanged
  padding shift     the same caption must give the same signs when the batch is
                    padded to a different width — otherwise a gloss depends on
                    what else the app batched with it

Gates apply to the splits in `--gate-splits` (default val and test). The OOD
split is a zero-shot diagnostic, not a target: it is built from compound
templates that never appear in training, and the app falls back to the rules
for that kind of prose, so it is reported but never gated.

Reported, not gated: exact-match against the rule engine's own target, the
share of caption tokens outside the model's vocabulary (the app's hybrid
trigger), and a per-caption-length breakdown of every metric.

Usage:
  python3 training/audit_model_output.py --run training/runs/gloss_rnn_v7
  python3 training/audit_model_output.py --split test --samples 512 \
      --out /tmp/model_audit.txt
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from export_onnx import vocab_from_itos  # noqa: E402
from train import load_rows, tokenize_source  # noqa: E402

MAX_SRC = 24

# Caption length in prepared tokens. The model is distilled from short everyday
# captions, so the audit reports every metric per bucket: it is the evidence
# for where the runtime should hand a caption back to the rule engine.
LENGTH_BUCKETS = ("1-6", "7-10", "11-14", "15-20", "21-24")
EOS = 3

GLOSS_NAME = re.compile(r"^[A-Z0-9][A-Z0-9'’\-_.&/,(): ]*[?!]?$")
NMM_MARKER = re.compile(r"^\[[^\[\]]+\]$")
NATIVE = re.compile(r"[\u0900-\u097F\u0B80-\u0BFF\u0D00-\u0D7F]")
LOWERCASE = re.compile(r"[a-z]")

# Tokens the app may show as gloss but that are not a word of the caption.
ADDITIONS = {
    "FINISH",
    "WILL",
    "NOT",
    "NOT-CAN",
    "CANNOT",
    "NO",
    "NEVER",
    "MUST",
    "CAN",
    "IX",
    "IX-A",
    "IX-B",
    "IX-C",
    "IX-D",
    "ME",
    "MY",
    "YOUR",
    "WE",
    "US",
    "THEY",
    "THEM",
    "OUR",
    "THEIR",
    "THIS",
    "THAT",
    "TODAY",
    "YESTERDAY",
    "NOW",
    "LATER",
    "BECAUSE",
    "HAVE",
    "IF",
}

# Rewrites the rule engine documents (see caption_gloss_audit_test.dart).
REWRITES = {
    "when": ["during"],
    "while": ["during"],
    "iced": ["cold-brew"],
    "minute": ["time"],
    "yeah": ["yes"],
    "incredibly": ["very"],
    "quite": ["very"],
    "badly": ["severe"],
    "severely": ["severe"],
}

PRONOUNS = {
    "them": {"they"},
    "they": {"they"},
    "he": {"ix", "he"},
    "she": {"ix", "she"},
    "it": {"ix", "it"},
    "i": {"me"},
    "us": {"we"},
    "we": {"we"},
    "my": {"my"},
    "mine": {"my"},
    "your": {"your"},
    "yours": {"your"},
    "their": {"their"},
}

NUMERALS = {
    "zero": "0",
    "one": "1",
    "two": "2",
    "three": "3",
    "four": "4",
    "five": "5",
    "six": "6",
    "seven": "7",
    "eight": "8",
    "nine": "9",
    "ten": "10",
    "eleven": "11",
    "twelve": "12",
}

NEGATION_SOURCE = {"not", "no", "never", "none", "nobody", "nothing", "cannot"}
NEGATION_TARGET = {"NOT", "NO", "NEVER", "NONE", "CANNOT", "NOT-CAN"}
FUTURE_SOURCE = {"will", "shall"}

DOUBLED_TAIL = re.compile(r"(.)\1$")


def undouble(base: str) -> str:
    return base[:-1] if DOUBLED_TAIL.search(base) else base


def stem_forms(word: str) -> set[str]:
    forms = {word}
    if "'" in word or "’" in word:
        forms.update(part for part in re.split(r"['’]", word) if part)
    for suffix in ("ies", "ied"):
        if word.endswith(suffix) and len(word) > 4:
            forms.add(word[:-3] + "y")
    if word.endswith("s") and len(word) > 3:
        forms.add(word[:-1])
        if word.endswith("es") and len(word) > 4:
            forms.add(word[:-2])
    if word.endswith("ing") and len(word) > 4:
        base = word[:-3]
        forms.update({base, base + "e", undouble(base)})
    if word.endswith("ed") and len(word) > 3:
        base = word[:-2]
        forms.update({base, base + "e", word[:-1], undouble(base)})
    return forms


def lookup_forms(word: str) -> set[str]:
    forms = stem_forms(word)
    expanded = set(forms)
    for form in forms:
        expanded.update(REWRITES.get(form, []))
    expanded.update(PRONOUNS.get(word, set()))
    return expanded


def built_from_caption(base: str, stems: set[str]) -> bool:
    for part in re.split(r"[-_]", base):
        if not part:
            continue
        for stem in stems:
            if part == stem:
                return True
            if len(part) < 4 or len(stem) < 4:
                continue
            if part.startswith(stem) or stem.startswith(part):
                return True
    return False


def is_label_leak(token: str) -> bool:
    if NMM_MARKER.match(token):
        return False
    if NATIVE.search(token):
        return True
    if LOWERCASE.search(token):
        return True
    if "(" in token or ")" in token:
        return True
    if re.search(r"_\d+$", token):
        return True
    if token in {"NEED-ID-GLOSS"}:
        return True
    return not GLOSS_NAME.match(token)


def traced(
    token: str,
    stems: set[str],
    numerals: set[str],
    gold: set[str],
) -> bool:
    upper = token.upper()
    if NMM_MARKER.match(token) or upper in ADDITIONS:
        return True
    # The engine's own gloss for this caption is the contract the student is
    # graded against; a token it also emits is a synonym mapping, not
    # invention. This audit only finds content the engine would not sign.
    if upper.rstrip("?!") in gold:
        return True
    parts = [p for p in re.split(r"[-_']", upper) if p]
    if not parts:
        return False
    for part in parts:
        lower = part.lower()
        if lower in stems or part in numerals:
            continue
        if built_from_caption(lower, stems):
            continue
        if len(part) == 1:
            # A fingerspelled letter is allowed only when some caption word is
            # spelled out that way; a lone letter for no word is a leak.
            if any(lower in word for word in stems):
                continue
            return False
        return False
    return True


def decode(ids: np.ndarray, itos: list[str]) -> list[str]:
    out = []
    for value in ids.tolist():
        if value == EOS:
            break
        if value < 4:
            continue
        out.append(itos[value])
    return out


def encode_rows(rows: list[dict], stoi: dict[str, int]) -> tuple[np.ndarray, np.ndarray]:
    encoded = [
        [stoi.get(tok, 1) for tok in tokenize_source(row["x"], row["system"])][:MAX_SRC]
        for row in rows
    ]
    length = np.array([len(e) for e in encoded], dtype=np.int64)
    src = np.zeros((len(encoded), max(int(length.max()), 1)), dtype=np.int64)
    for i, tokens in enumerate(encoded):
        src[i, : len(tokens)] = tokens
    return src, length


def pad_to(src: np.ndarray, width: int) -> np.ndarray:
    padded = np.zeros((src.shape[0], max(width, src.shape[1])), dtype=np.int64)
    padded[:, : src.shape[1]] = src
    return padded


def length_bucket(count: int) -> str:
    for name, limit in (("1-6", 6), ("7-10", 10), ("11-14", 14), ("15-20", 20)):
        if count <= limit:
            return name
    return "21-24"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", default="training/runs/gloss_rnn_v7")
    parser.add_argument("--export", default="training/export")
    parser.add_argument("--data", default="training/data")
    parser.add_argument("--split", action="append", default=None,
                        help="split to audit; repeatable (default val test ood)")
    parser.add_argument("--gate-splits", nargs="+", default=["val", "test"],
                        help="splits a failure makes the audit exit non-zero")
    parser.add_argument("--samples", type=int, default=0,
                        help="rows per split; 0 audits every row")
    parser.add_argument("--batch", type=int, default=256)
    parser.add_argument("--out", default="")
    parser.add_argument("--max-untraced", type=float, default=1.0,
                        help="allowed untraced tokens as a percent of output")
    parser.add_argument("--model-max-tokens", type=int, default=10,
                        help="longest prepared caption (in tokens) the model "
                             "serves; longer ones belong to the rule engine, "
                             "so their negation/WILL/untraced slips are "
                             "reported but not gated. 0 gates every row.")
    args = parser.parse_args()

    splits = args.split or ["val", "test", "ood"]
    run_dir = Path(args.run)
    meta = json.loads((run_dir / "vocab.json").read_text(encoding="utf-8"))
    stoi, itos = meta["src_itos"], meta["tgt_itos"]
    src_stoi = {token: i for i, token in enumerate(stoi)}

    export = Path(args.export)
    model_path = export / "gloss_seq2seq.int8.onnx"
    if not model_path.exists():
        model_path = export / "gloss_seq2seq.onnx"
        if not model_path.exists():
            raise SystemExit(f"no export under {export}")

    import onnxruntime as ort

    session = ort.InferenceSession(
        str(model_path), providers=["CPUExecutionProvider"]
    )

    print(f"model={model_path} ({model_path.stat().st_size / 1e6:.2f} MB)")
    print(f"vocab=src:{len(stoi)} tgt:{len(itos)}")

    failures: dict[str, list[str]] = defaultdict(list)
    samples_out: list[str] = []
    gated_untraced: Counter[str] = Counter()
    gated_tokens: Counter[str] = Counter()

    for split in splits:
        rows = load_rows(Path(args.data) / f"{split}.jsonl")
        if args.samples:
            step = max(len(rows) // args.samples, 1)
            rows = rows[::step][: args.samples]
        exact = 0
        unk_rows = 0
        split_counts = Counter()
        split_labels: Counter[str] = Counter()
        split_untraced: Counter[str] = Counter()
        buckets: dict[str, Counter] = defaultdict(Counter)
        by_system: dict[str, Counter] = defaultdict(Counter)

        for start in range(0, len(rows), args.batch):
            chunk = rows[start : start + args.batch]
            src, src_len = encode_rows(chunk, src_stoi)
            pred = session.run(
                None,
                {
                    "src": src,
                    "src_len": src_len,
                },
            )[0]
            outputs = [decode(row, itos) for row in pred]

            for row, tokens in zip(chunk, outputs):
                caption = row["x"].lower()
                gold = {
                    t.upper().rstrip("?!") for t in row["y"].split()
                }
                words = re.findall(r"[a-z0-9']+", caption)
                stems: set[str] = set()
                for word in words:
                    stems.update(lookup_forms(word))
                numerals = {
                    NUMERALS[w] for w in words if w in NUMERALS
                }
                src_tokens = tokenize_source(row["x"], row["system"])
                if any(tok not in src_stoi for tok in src_tokens[1:]):
                    unk_rows += 1

                prepared = len(src_tokens) - 1
                served = args.model_max_tokens <= 0 or prepared <= args.model_max_tokens
                bucket = buckets[length_bucket(prepared)]
                bucket["rows"] += 1
                split_counts["rows"] += 1
                split_counts["tokens"] += len(tokens)
                system = by_system[row["system"]]
                system["rows"] += 1
                system["tokens"] += len(tokens)
                if served:
                    split_counts["served_rows"] += 1
                    split_counts["served_tokens"] += len(tokens)
                    system["served_rows"] += 1
                    system["served_tokens"] += len(tokens)
                if not tokens:
                    split_counts["empty"] += 1
                    samples_out.append(f"empty\t{split}\t{row['x']}")
                if " ".join(tokens) == row["y"].strip():
                    exact += 1
                    bucket["exact"] += 1
                    system["exact"] += 1

                untraced = 0
                for token in tokens:
                    if is_label_leak(token):
                        split_counts["label"] += 1
                        split_labels[token] += 1
                    if not traced(token, stems, numerals, gold):
                        untraced += 1
                        split_counts["untraced"] += 1
                        split_untraced[token] += 1
                        if len(samples_out) < 4000:
                            samples_out.append(
                                f"untraced{' (served)' if served else ''}"
                                f"\t{split}\t{row['x']}\t{token}"
                            )
                if served:
                    split_counts["served_untraced"] += untraced
                    system["served_untraced"] += untraced
                system["untraced"] += untraced
                bucket["tokens"] += len(tokens)
                bucket["untraced"] += untraced

                negated = any(w in NEGATION_SOURCE for w in words)
                if negated:
                    split_counts["negated"] += 1
                    bucket["negated"] += 1
                    system["negated"] += 1
                    if served:
                        split_counts["served_negated"] += 1
                        system["served_negated"] += 1
                    if not any(t in NEGATION_TARGET for t in tokens) and \
                            "[headshake]" not in tokens:
                        split_counts["negation_lost"] += 1
                        bucket["negation_lost"] += 1
                        system["negation_lost"] += 1
                        if served:
                            split_counts["served_negation_lost"] += 1
                            system["served_negation_lost"] += 1
                        samples_out.append(
                            f"negation-lost\t{split}\t{row['x']}\t"
                            f"{' '.join(tokens)}"
                        )
                future = any(w in FUTURE_SOURCE for w in words) or (
                    "going" in words and "to" in words
                )
                if future:
                    split_counts["future"] += 1
                    bucket["future"] += 1
                    system["future"] += 1
                    if served:
                        split_counts["served_future"] += 1
                        system["served_future"] += 1
                    if "WILL" not in tokens:
                        split_counts["will_lost"] += 1
                        bucket["will_lost"] += 1
                        system["will_lost"] += 1
                        if served:
                            split_counts["served_will_lost"] += 1
                            system["served_will_lost"] += 1
                        samples_out.append(
                            f"will-lost\t{split}\t{row['x']}\t"
                            f"{' '.join(tokens)}"
                        )

        # Determinism: the same batch, run again unchanged, must give the same
        # gloss. A second pass padded to the full width checks the encoder does
        # not read the PAD of its batch — otherwise a caption's gloss depends
        # on how many words the app happened to batch with it. The shortest
        # rows are checked because their natural width is far below MAX_SRC, so
        # the padding really changes the scan length.
        check_rows = sorted(
            rows, key=lambda r: len(tokenize_source(r["x"], r["system"]))
        )[: min(64, len(rows))]
        src, src_len = encode_rows(check_rows, src_stoi)
        again = session.run(None, {"src": src, "src_len": src_len})[0]
        repeats = [decode(row, itos) for row in again]
        natural = [
            decode(row, itos)
            for row in session.run(
                None, {"src": src, "src_len": src_len}
            )[0]
        ]
        drift = sum(a != b for a, b in zip(natural, repeats))
        padded = pad_to(src, MAX_SRC)
        wider = session.run(None, {"src": padded, "src_len": src_len})[0]
        wide = [decode(row, itos) for row in wider]
        shifts = [i for i, (a, b) in enumerate(zip(natural, wide)) if a != b]
        for i in shifts[:5]:
            samples_out.append(
                f"padding-shift\t{split}\t{check_rows[i]['x']}\t"
                f"{' '.join(natural[i])}\t{' '.join(wide[i])}"
            )
        split_counts["nondeterministic"] = drift
        split_counts["padding_shift"] = len(shifts)

        print(f"\n[{split}]")
        print(
            f"  rows {split_counts['rows']} | tokens {split_counts['tokens']} | "
            f"exact {exact} ({exact / max(split_counts['rows'], 1):.4f}) | "
            f"unk source rows {unk_rows} "
            f"({unk_rows / max(split_counts['rows'], 1):.3f})"
        )
        print(
            f"  empty {split_counts['empty']} | label leaks "
            f"{split_counts['label']} | untraced {split_counts['untraced']} | "
            f"negation lost {split_counts['negation_lost']}/"
            f"{split_counts['negated']} | WILL lost {split_counts['will_lost']}/"
            f"{split_counts['future']} | nondeterministic "
            f"{split_counts['nondeterministic']} | padding shift "
            f"{split_counts['padding_shift']}"
        )
        if args.model_max_tokens > 0 and split_counts["rows"]:
            print(
                f"  model-served (<= {args.model_max_tokens} tokens): "
                f"{split_counts['served_rows']}/{split_counts['rows']} rows "
                f"({100 * split_counts['served_rows'] / split_counts['rows']:.1f}%), "
                f"{split_counts['served_tokens']} output tokens"
                f" | untraced {split_counts['served_untraced']} | "
                f"negation lost {split_counts['served_negation_lost']}/"
                f"{split_counts['served_negated']} | WILL lost "
                f"{split_counts['served_will_lost']}/{split_counts['served_future']}"
            )
        gated = split in args.gate_splits
        for name in (
            "empty",
            "label",
            "nondeterministic",
            "padding_shift",
        ):
            if split_counts[name] and gated:
                failures[name].append(f"{split}: {split_counts[name]}")
        for name in ("served_negation_lost", "served_will_lost"):
            if split_counts[name] and gated:
                failures[name[7:]].append(f"{split}: {split_counts[name]}")
        if gated:
            gated_untraced["all"] += split_counts["served_untraced"]
            gated_tokens["all"] += split_counts["served_tokens"]

        print("  by caption length (prepared tokens) — exact / untraced / neg lost")
        for name in LENGTH_BUCKETS:
            counts = buckets.get(name)
            if not counts or not counts["rows"]:
                continue
            print(
                f"    {name:<6} rows {counts['rows']:<5} "
                f"exact {100 * counts['exact'] / counts['rows']:5.1f}%  "
                f"untraced {counts['untraced']:>4}/{counts['tokens']:<5}  "
                f"neg lost {counts['negation_lost']}/{counts['negated']}"
            )

        if split_labels:
            print("  label leaks: " + ", ".join(
                f"{tok} x{n}" for tok, n in split_labels.most_common(8)))
        if split_untraced:
            print("  untraced: " + ", ".join(
                f"{tok} x{n}" for tok, n in split_untraced.most_common(8)))

        if len(by_system) > 1:
            print("  by system — exact / untraced (served) / neg lost (served) "
                  "/ WILL lost (served)")
            for system in sorted(by_system):
                counts = by_system[system]
                print(
                    f"    {system:<4} rows {counts['rows']:<5} "
                    f"exact {100 * counts['exact'] / counts['rows']:5.1f}%  "
                    f"untraced {counts['served_untraced']:>3}/"
                    f"{counts['served_tokens']:<5}  "
                    f"neg {counts['served_negation_lost']}/"
                    f"{counts['served_negated']:<4}  "
                    f"WILL {counts['served_will_lost']}/"
                    f"{counts['served_future']}"
                )

    gated_untraced_all = gated_untraced.get("all", 0)
    gated_tokens_all = gated_tokens.get("all", 0)
    untraced_pct = 100 * gated_untraced_all / max(gated_tokens_all, 1)
    if untraced_pct > args.max_untraced:
        failures["untraced_pct"].append(
            f"{untraced_pct:.2f}% of {gated_tokens_all} tokens "
            f"(limit {args.max_untraced:.2f}%)"
        )

    print(f"\n=== GATES (splits: {', '.join(args.gate_splits)}) ===")
    for name in (
        "empty",
        "label",
        "negation_lost",
        "will_lost",
        "nondeterministic",
        "padding_shift",
    ):
        state = "PASS" if not failures[name] else "FAIL " + "; ".join(
            failures[name]
        )
        print(f"{name:<16} {state}")
    scope = (f"rows <= {args.model_max_tokens} tokens"
             if args.model_max_tokens > 0 else "all rows")
    state = "PASS" if not failures["untraced_pct"] else "FAIL " + "; ".join(
        failures["untraced_pct"]
    )
    print(f"{'untraced %':<16} {untraced_pct:.2f}% <= "
          f"{args.max_untraced:.2f}%  {state}  ({scope})")
    if args.model_max_tokens > 0:
        print("negation/WILL/untranslated gates cover model-served rows only; "
              "longer captions belong to the rule engine")
    ungated = [s for s in splits if s not in args.gate_splits]
    if ungated:
        print(f"diagnostic only, not gated: {', '.join(ungated)}")

    if args.out:
        Path(args.out).write_text("\n".join(samples_out) + "\n", encoding="utf-8")
        print(f"\nsamples: {args.out} ({len(samples_out)} lines)")

    if any(failures.values()):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
