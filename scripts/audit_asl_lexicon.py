#!/usr/bin/env python3
"""Check the built ASL sign lexicon against the ASL-LEX source it came from.

The catalogue test pins one exemplar of each builder rule
(`sign_language_catalog_test.dart`). This checks the whole table with the same
rules, straight from the CSV and the built asset:

  own name     a word some sign is *named* by (its lemma), or whose singular is,
               must reach a sign of that name — never a more frequent sign that
               merely lists the word among its English equivalents
  plural       a plural that no sign names takes its singular's sign
  placeholder  no entry points at NEED-ID-GLOSS
  notation     no gloss label keeps SignBank notation (variant index, paren,
               action prefix, `_/_` alternative)

Usage:
  python3 scripts/audit_asl_lexicon.py
  python3 scripts/audit_asl_lexicon.py --samples 20
"""

from __future__ import annotations

import argparse
import csv
from collections import defaultdict
from pathlib import Path

from build_asl_sign_lexicon import (
    CSV_PATH,
    GLOSS_OVERRIDES,
    OUT_PATH,
    PLACEHOLDER_GLOSSES,
    PLURAL_EXCEPTIONS,
    normalize_gloss,
    normalize_word,
)


def read_asset() -> dict[str, tuple[str, str]]:
    entries = {}
    for line in OUT_PATH.read_text(encoding="utf-8").splitlines():
        parts = line.strip().split("|")
        if len(parts) < 3:
            continue
        entries[parts[0]] = (parts[1], parts[2])
    return entries


def own_names() -> dict[str, set[str]]:
    """Words a sign is named by: its lemma, minus fingerspelled rows."""
    names: dict[str, set[str]] = defaultdict(set)
    with CSV_PATH.open(newline="", encoding="latin-1") as handle:
        for row in csv.DictReader(handle):
            lemma = (row.get("LemmaID") or "").strip().lower()
            if not lemma or "." in lemma:
                continue
            gloss = normalize_gloss((row.get("SignBankLemmaID") or lemma).strip())
            if gloss in PLACEHOLDER_GLOSSES:
                continue
            names[normalize_word(lemma)].add(gloss)
    return names


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", type=int, default=10,
                        help="violations to print per class")
    args = parser.parse_args()

    asset = read_asset()
    names = own_names()
    print(f"asset={len(asset)} entries names={len(names)} words")

    own_violations = []
    for word, glosses in sorted(names.items()):
        hit = asset.get(word)
        if hit is None:
            continue  # the word is not claimed by the table at all
        if hit[0] in glosses:
            continue
        override = GLOSS_OVERRIDES.get(word)
        if override and hit[0] == override[0]:
            continue
        own_violations.append(f"{word}: {hit[0]} ({hit[1]}) != {sorted(glosses)}")

    plural_violations = []
    for word, (gloss, sign_id) in sorted(asset.items()):
        if word in names or word in PLURAL_EXCEPTIONS:
            continue
        if not word.endswith("s") or len(word) < 4:
            continue
        stems = (word[:-2], word[:-1]) if word.endswith("es") else (word[:-1],)
        for stem in stems:
            singular = asset.get(stem)
            if singular and singular[0] != gloss:
                plural_violations.append(
                    f"{word}: {gloss} != {stem} {singular[0]}"
                )
            break

    placeholder = [
        f"{word}: {gloss}"
        for word, (gloss, _) in sorted(asset.items())
        if gloss in PLACEHOLDER_GLOSSES
    ]

    notation = [
        f"{word}: {gloss}"
        for word, (gloss, _) in sorted(asset.items())
        if "_" in gloss or "(" in gloss or "&=" in gloss
    ]

    print("\n=== GATES ===")
    for name, rows in (
        ("own name", own_violations),
        ("plural", plural_violations),
        ("placeholder", placeholder),
        ("notation", notation),
    ):
        print(f"{name:<12} {'PASS' if not rows else f'FAIL {len(rows)}'}")
        for row in rows[: args.samples]:
            print(f"  {row}")

    if own_violations or plural_violations or placeholder or notation:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
