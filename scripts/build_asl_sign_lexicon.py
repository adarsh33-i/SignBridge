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
    # Two rows answer to this word. One has the lemma `send` but signifies
    # SUBMIT — its own translations include put away, throw away and toss out.
    # The sign a caption means is the SEND row, whose lemma is `dispatch` and
    # whose dominant translation is "send". Preferring the word's own lemma
    # would put the discard sign on every message that gets sent.
    "send": ("SEND", "dispatch"),
}

# ASL-LEX rows whose SignBank gloss is unassigned. The gloss would reach the
# chip verbatim, so a row that only offers a placeholder is no claim at all.
PLACEHOLDER_GLOSSES = {"NEED-ID-GLOSS"}

# Plurals that name a different thing from their singular. Inheriting the
# singular's sign would be wrong for these: blinds are window coverings, woods
# are a forest, greens are vegetables, and tears come from crying.
PLURAL_EXCEPTIONS = {
    "blinds": "window covering, not BLIND",
    "woods": "forest, not WOOD",
    "greens": "vegetables, not GREEN",
    "tears": "crying, not TEAR",
    # The plural names a related but different thing, so it keeps the sign its
    # own row claims instead of inheriting the singular's.
    "feelings": "emotions, not the sensation FEEL",
    "looks": "appearance, not the glance LOOK",
    "outfits": "clothes, not the act DRESS-UP",
    "siblings": "brothers and sisters, not TWINS",
    "thoughts": "ideas, not the act THINK",
    "tools": "instruments, not the singular's sign",
}


def normalize_word(word: str) -> str:
    return re.sub(r"[^a-z0-9'-]", "", word.strip().lower())


def normalize_id(value: str) -> str:
    cleaned = re.sub(r"[^a-zA-Z0-9]+", "_", value.strip().lower())
    return cleaned.strip("_")


def normalize_gloss(value: str) -> str:
    """Reduce a SignBank gloss to the sign's name, without database notation.

    The gloss is what the viewer reads on the chip, so the notation that only
    SignBank needs is dropped here: a leading '~' (unconfirmed cross-reference),
    a '&=' sound/action prefix, a letter-prefixed paren that wraps a mouth
    morpheme or interjection (`E(CALM-DOWN)`, `I(SNAP)`), a `_/_` alternative
    (`RELEASE_/_FREE`), and a trailing variant index (`TALL_2`). Word
    separators become hyphens, which is the app's gloss notation everywhere
    else (TRAFFIC-ON-TOP); ASL-LEX joins them with underscores because it uses
    the gloss as a key.
    """
    gloss = value.strip().lstrip("~").upper()
    if gloss.startswith("&="):
        gloss = gloss[2:]
    gloss = re.sub(r"^[A-Z]\((.+)\)$", r"\1", gloss)
    gloss = re.sub(r"_\d+$", "", gloss)
    gloss = re.sub(r"[\s_]+", "-", gloss)
    return re.sub(r"-{2,}", "-", gloss.replace("/", "")).strip("-")


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
    names: dict[str, tuple[str, str, float, int]] = {}
    aliases: dict[str, tuple[str, str, float, int]] = {}

    def offer(
        pool: dict[str, tuple[str, str, float, int]],
        word: str,
        gloss: str,
        sign_id: str,
        frequency: float,
        tier: int,
    ) -> None:
        if len(word) < 2 or gloss in PLACEHOLDER_GLOSSES:
            return
        prev = pool.get(word)
        # The tier settles a word two signs both claim: a sign whose own lemma is
        # the word names it, a sign that only lists it as the dominant
        # translation or entry id is second-hand, and an English-equivalent list
        # is a guess. Frequency decides only inside one tier — otherwise a
        # frequent sign whose translation list happens to contain the word takes
        # it from the word's own sign (state → STAMP_1, pineapple → PICKLE).
        if prev is None or (tier, frequency) > (prev[3], prev[2]):
            pool[word] = (gloss, sign_id, frequency, tier)

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
            # A row like that is a guess at how a word would be spelled, so
            # everything it claims goes to the alias tier where a real sign
            # always wins.
            spelled = "." in lemma
            for raw in filter(None, (lemma, entry, dominant)):
                if spelled or "." in raw:
                    pool, tier = aliases, 0
                else:
                    own = normalize_word(raw) == normalize_word(lemma)
                    pool, tier = names, (2 if own else 1)
                offer(
                    pool,
                    normalize_word(raw),
                    gloss,
                    sign_id,
                    frequency,
                    tier=tier,
                )
            if translations:
                for part in translations.split(","):
                    offer(
                        aliases,
                        normalize_word(part),
                        gloss,
                        sign_id,
                        frequency,
                        tier=0,
                    )

    # A plural that no sign names belongs to the sign of its singular when that
    # sign exists: `balls` was being answered with JUGGLE and `matches` with
    # SHARPEN_1, both more frequent signs that list the plural among their
    # English. A sign whose own lemma is the plural (`steps`) keeps it, and
    # PLURAL_EXCEPTIONS keeps the plurals that name something else.
    best = {**aliases, **names}
    for word, (gloss, sign_id, frequency, tier) in list(best.items()):
        if tier >= 2 or word in PLURAL_EXCEPTIONS:
            continue
        if not word.endswith("s") or len(word) < 4:
            continue
        stems = (word[:-2], word[:-1]) if word.endswith("es") else (word[:-1],)
        for stem in stems:
            singular = best.get(stem)
            if singular is not None and singular[3] == 2:
                best[word] = (singular[0], singular[1], frequency, tier)
                break

    for word, (gloss, sign_id) in GLOSS_OVERRIDES.items():
        if word in best:
            best[word] = (gloss, sign_id, best[word][2], best[word][3])

    lines = [
        f"{word}|{gloss}|{sign_id}"
        for word, (gloss, sign_id, _, _) in sorted(best.items())
    ]
    OUT_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {len(lines)} ASL sign entries to {OUT_PATH}")


if __name__ == "__main__":
    main()
