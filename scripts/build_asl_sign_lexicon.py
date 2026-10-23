#!/usr/bin/env python3
"""Build ASL sign lexicon from ASL-LEX 2.0 SignData (CC BY-NC 4.0).

Source: https://asl-lex.org/download.html
CSV: scripts/data/asl_lex_signdata.csv (from ASL-LEX/asl-lex GitHub)

Output: assets/lexicon/asl_sign_lexicon.txt
  Format per line: english_word|GLOSS|sign_id
"""

from __future__ import annotations

import csv
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CSV_PATH = ROOT / "scripts/data/asl_lex_signdata.csv"
OUT_PATH = ROOT / "assets/lexicon/asl_sign_lexicon.txt"

# Corrections applied on top of ASL-LEX output (ASL-LEX glosses REST as WAIT).
GLOSS_OVERRIDES = {
    "rest": ("REST", "rest"),
    # Lists warmth as an English equivalent of the pointer-on-forearm sign,
    # but the word names the feeling, not the instrument.
    "warmth": ("WARM", "warm"),
    # HOT, THERMOMETER and WARM all claim "temperature" as an equivalent and
    # HOT is the most frequent of the three, so no tier rule settles it. In a
    # weather caption the word names the reading, which is what THERMOMETER is.
    "temperature": ("THERMOMETER", "thermometer"),
}


def normalize_word(word: str) -> str:
    return re.sub(r"[^a-z0-9'-]", "", word.strip().lower())


def normalize_id(value: str) -> str:
    cleaned = re.sub(r"[^a-zA-Z0-9]+", "_", value.strip().lower())
    return cleaned.strip("_")


def normalize_gloss(value: str) -> str:
    """ASL-LEX marks unconfirmed SignBank cross-references with a leading '~'.

    A tilde in a gloss would reach the app as part of a token id, so it is
    stripped here rather than filtered downstream.
    """
    return value.strip().lstrip("~").upper().replace(" ", "_")


def main() -> None:
    if not CSV_PATH.is_file():
        raise SystemExit(f"Missing source CSV: {CSV_PATH}")

    # Two tiers, because ASL-LEX attaches each sign two kinds of English and
    # only one of them is a translation. `names` holds the words a sign is
    # actually called (its lemma, entry id, dominant translation); `aliases`
    # holds words merely listed among its looser English equivalents, which
    # include things a Deaf signer might guess from a video clip. Aliases lose
    # to names no matter how often they are signed: the TEASE entry lists
    # "warm" — a SignBank transcription quirk — and TEASE is a more frequent
    # sign than WARM, so frequency alone put a teasing gesture on every warm
    # sentence in the weather corpus.
    names: dict[str, tuple[str, str, float]] = {}
    aliases: dict[str, tuple[str, str, float]] = {}

    def offer(
        pool: dict[str, tuple[str, str, float]],
        word: str,
        gloss: str,
        sign_id: str,
        frequency: float,
    ) -> None:
        if len(word) < 2:
            return
        prev = pool.get(word)
        if prev is None or frequency > prev[2]:
            pool[word] = (gloss, sign_id, frequency)

    with CSV_PATH.open(newline="", encoding="latin-1") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            try:
                frequency = float(row.get("SignFrequency(M)") or 0)
            except ValueError:
                frequency = 0.0

            lemma = (row.get("LemmaID") or "").strip().lower()
            entry = (row.get("EntryID") or "").strip().lower()
            bank = (row.get("SignBankLemmaID") or "").strip()
            dominant = (row.get("DominantTranslation") or "").strip().lower()
            translations = (row.get("SignBankEnglishTranslations") or "").strip()

            gloss = normalize_gloss(bank or lemma)
            sign_id = normalize_id(lemma or entry)

            # A lemma dotted out is ASL-LEX's notation for a fingerspelled
            # sign: `w.h.a.t` is the letters W-H-A-T, not a word. Its letters
            # normalise to "what", so left in the name tier it takes the slot
            # from the real WHAT entry, which is only slightly more frequent —
            # and every question in the app starts spelling its question word.
            for raw in filter(None, (lemma, entry, dominant)):
                pool = aliases if "." in raw else names
                offer(pool, normalize_word(raw), gloss, sign_id, frequency)
            if translations:
                for part in translations.split(","):
                    offer(
                        aliases,
                        normalize_word(part),
                        gloss,
                        sign_id,
                        frequency,
                    )

    best = {**aliases, **names}

    for word, (gloss, sign_id) in GLOSS_OVERRIDES.items():
        if word in best:
            best[word] = (gloss, sign_id, best[word][2])

    lines = [
        f"{word}|{gloss}|{sign_id}"
        for word, (gloss, sign_id, _) in sorted(best.items())
    ]
    OUT_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {len(lines)} ASL sign entries to {OUT_PATH}")


if __name__ == "__main__":
    main()
