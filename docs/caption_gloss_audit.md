# Caption-to-gloss audit

This stage turns a spoken caption into the gloss tokens the chip shows and the
avatar signs. It runs *before* the sign-resolution audit: this one asks whether
the gloss says what the caption said, that one asks whether a gloss token has an
animation.

**Test:** `test/services/caption_gloss_audit_test.dart`
**Code under test:** `SpokenTextPrep.normalizeForGloss` → `SignLanguageCatalog.sequenceFor`
→ `SignGrammarEngine.applyRules` → `SignLexiconBuilder.resolve`
**Corpus:** the same fixtures as `sign_resolution_audit_test.dart` — 2,161 English
sentences plus 100 each of Hindi, Tamil and Malayalam (2,461 sentences,
17,737 gloss tokens), plus 4,716 noisy variants of the English fixtures.

Run it and keep the report:

```bash
CAPTION_GLOSS_AUDIT_OUT=/tmp/cg_audit.txt \
  flutter test test/services/caption_gloss_audit_test.dart
```

## What each number means

| Metric | Definition |
|--------|------------|
| authored | token id has a hand-authored pose in `SignLibrary.debugCore` |
| documented | ASL-LEX, `AslCoreLexicon` or the core lexicon knows the id, no pose yet |
| spelled | a fingerspelled letter |
| marker | a non-manual marker such as `[wh-q]` or `[headshake]` |
| number | a numeral or clock compound |
| passthrough | an English word uppercased because no sign was found |
| negation lost | caption has not/no/never/नहीं and the gloss carries no NOT, NO, NEVER or `[HEADSHAKE]` |
| WILL lost | caption has will/shall/going to and no WILL survived |
| past marking lost | caption states past and no FINISH, PAST or a past time anchor survived |
| past question unmarked | a past-tense question with no past marker; reported, the question face carries the frame |
| wh not final | a question clause whose WH sign is not the last content sign |
| time sign not first | the caption opened with a time phrase and the gloss did not |
| negation not clause-final | content followed NOT in a single-sentence caption outside a conditional |
| noisy captions | deterministic degraded variants (lowercase, an `um` prefix, a stutter) that broke an invariant |
| untraced token | a content token with no caption word, lemma or documented rewrite behind it |
| preview drift | the live preview showed a sign the final reordered pass then dropped |
| preview word in own script | a mid-sentence token still spelled in Devanagari, Tamil or Malayalam, so the chip showed text with no sign behind it |
| word reached a different sign | `AslSignLexicon.lookup(word)` returns an id that is not that word |

Meaning checks run on the words the rule engine actually sees: the caption after
`normalizeForGloss`, `splitWords` and `normalize`. Past is three-way in ASL —
FINISH, a past time anchor, or the question face — so the rubric counts a
caption as past when it carries `did`, `had`, a past-fronted irregular
(`went`, `left`), or a regular `-ed` in a finite position. A future auxiliary
scopes everything after it, so `the grade entered on the form` is a participle
and not a past statement, while `went blank, and now it won't` is. Regular `-ed`
only counts when its stem is a word this app signs, so `speed` and `unused` do
not trigger it. A WH sign inside a statement is not a violation, so the WH
check only runs on sentences ending in `?`. Provenance mirrors the engine's own
normalisation — suffix stripping, the now-public `SignGrammarEngine.irregularPast`
and `irregularPastParticiple` tables, contraction splits, and a short map of
documented rewrites (`when`/`while` → DURING, `iced coffee` → COLD-BREW,
`a few minutes` → TIME, `yeah` → YES, and the intensifiers
`very`/`quite`/`incredibly` → VERY plus `badly`/`severely` → SEVERE that a
degree recipe absorbs). Without that mirror the audit reported
1,149 "invented" tokens that were really just `left` → LEAVE.

## Result per language

| Lang | Sentences | Tokens | Authored | Documented | Spelled | Marker | Number | Passthrough |
|------|-----------|--------|----------|------------|---------|--------|--------|-------------|
| ENG | 2,161 | 16,791 | 10.3% | 60.1% | 0.2% | 2.5% | 0.0% | 26.8% |
| HI | 100 | 318 | 29.6% | 66.7% | 0% | 1.6% | 0% | 2.2% |
| TA | 100 | 314 | 29.3% | 66.9% | 0% | 1.6% | 0% | 2.2% |
| ML | 100 | 314 | 29.3% | 66.9% | 0% | 1.6% | 0% | 2.2% |

| Lang | Empty glosses | Preview drift | Preview words in own script | Untraced tokens |
|------|---------------|---------------|-----------------------------|-----------------|
| ENG | 0 | 74 clauses (3.4%) | 0 | 0 of 16,791 |
| HI | 0 | 33 clauses (33.0%) | 0 | 0 |
| TA | 0 | 4 clauses (4.0%) | 0 | 0 |
| ML | 0 | 3 clauses (3.0%) | 0 | 0 |

Corpus-wide: 17,248 of 17,248 content tokens trace to a caption word, 0
non-deterministic glosses, 0 labels outside gloss notation, 0 empty glosses.
Meaning: 89 negated clauses keep their negation, 134 future clauses keep WILL,
324 past clauses mark past, 22 yes/no questions carry `[y/n-q]`, no caption that
opens with time signs it later, and no single-sentence caption leaves content
after NOT. The 4,716 noisy variants break no invariant.

**Model artifacts:** the gloss corpus and `gloss_rnn_v7` were regenerated from
the fixed lexicon and the fixed encoder on 2026-10-27 — 95.36% val / 95.40%
test exact at 5.11M parameters (int8 graph: 95.33% / 95.40%), int8 ONNX
5.44 MB. `training/audit_model_output.py`
runs that int8 graph over every split and gates it against the invariants that
do not depend on which path produced the gloss: empty 0, label leaks 0,
negation lost 0 of 388 served val and 0 of 348 served test, WILL lost 0,
non-determinism 0, padding shift 0, untraced 0.33% of served output. All pass.
The OOD split (unseen compound templates, 3.19% exact) is reported, not gated:
it is built from nonsense sentences the corpus never models, and the rules cover
that prose. The audit also prints every split by sign language, because the two
grammars share one model: ASL 95.0% val / 94.8% test exact with 0.26% / 0.16%
untraced served tokens, ISL 95.7% / 96.0% exact with 0.54% / 0.41%, negation and
WILL 0 on both. Measurements in `training/README.md`.

## Gates in the test

| Gate | Limit | Why |
|------|-------|-----|
| Empty gloss per language | 0 | a clause that signs nothing is a dead card |
| Non-deterministic gloss | 0 | same caption must give same signs |
| Labels outside gloss notation | 0 | chip must never show Devanagari, Tamil or Malayalam text |
| Database key as a gloss label | 0 | finding 7, fixed 2026-10-27 — a variant index or SignBank paren is notation, not a word |
| Negation lost | 0 | finding 1, fixed 2026-10-27 |
| WILL lost | 0 | future tense survives everywhere |
| Untraced content token | 0 | finding 2, fixed 2026-10-27 — the engine may not sign a word the caption never said |
| Preview word left in its own script | 0 | finding 3, fixed 2026-10-27 — a mid-sentence Hindi/Tamil/Malayalam word has no letters to spell and no sign |
| Past marking lost | 0 | a past statement read as present |
| Past question unmarked | reported, not gated | the question face carries the frame; 6 captions |
| Time sign not first | 0 | ASL is Time + Topic + Comment |
| Negation not clause-final | 0 | a negation that leaves content after it reads as a hedge |
| Noisy caption broke an invariant | 0 | a degraded caption still may not blank the card, invent text or drop a negation |
| Preview drift | 5.0% ENG/TA/ML, 35.0% HI | the preview runs word by word, the final pass reorders; see finding 8 |
| Word reached a different sign | reported here, gated by `scripts/audit_asl_lexicon.py` | synonym mapping remains; the script checks every one of the 2,658 words a sign is named by, plus all 6,371 entries for plural and notation rules |

The model has its own gate set in `training/audit_model_output.py`, because a
distilled student can fail in ways the rules never do:

| Model gate | Limit | Why |
|------------|-------|-----|
| Empty gloss | 0 | a caption that signs nothing is a dead card |
| Label outside gloss notation | 0 | the chip must never show native script or a database key |
| Negation lost | 0 on served rows | finding 9 — a negated caption may not lose its NOT |
| WILL lost | 0 on served rows | future tense survives |
| Non-deterministic | 0 | the same batch twice must give the same gloss |
| Padding shift | 0 | the same caption padded wider must give the same gloss; broken until finding 10 |
| Untraced token | 1% of served output | a token that traces to no caption word, lemma or rewrite |
| OOD exact | reported, not gated | diagnostic of zero-shot composition, not a target |
| Captions over 10 prepared tokens | reported, not gated | the rule engine's job; the student drops from 94.3% to 4.5% exact there |

## Findings

**1. Conditional negation was deleted — fixed 2026-10-27.** 7 of 89 negated
clauses lost their NOT, because `_applyPostFixNegation` stripped every `not` and
`applyRules` suppressed the re-add for any sentence containing `if`. The fix
finds the condition/main boundary in the caption's own word order: a negation
inside the condition is inserted there (`_insertNotInCondition`), a negation in
the main clause still goes clause-final, and both survive when each half is
negated. Regression tests:
`test/services/sign_language_catalog_test.dart`, three cases.

**2. The engine invented WHY and a question marker for statements — fixed
2026-10-27.** It was 43 tokens across 45 untraced, and the same recipes deleted
content. `_reasonClause` now signs the junction the speaker used (BECAUSE / SO)
and adds no `[rh-q]`, so a statement keeps a statement face. `so` before an
adjective ("so happy", "so stressed") is read as an intensifier instead of a
clause junction. Every fixed-order recipe now passes `_recipeSaysAll`, which
asks whether the recipe can name each word in the clause before it rewrites the
order; if not, the generic reorder path runs and nothing is deleted. Tense and
negation markers are re-carried rather than dropped. Measured: untraced 45 → 0,
lexicon-signed words vanishing from the gloss 88 → 44 occurrences, past marking
loss 184 → 169.

**3. Function words and untranslated words leaked into the live preview — fixed
2026-10-27.** English preview drift was 636 clauses (29.4%): `The` alone
accounted for 399 strays, then ON 125, IN 82, A 29, DO 18, CAN 11, हो 6. Two
causes, both measured against every prefix of every corpus sentence.

- `applyRules` ends with `if (processed.isEmpty) return expanded;` — so a
  one-word prefix "The" returns THE and the avatar spells T-H-E, which the final
  pass drops. `SignGrammarEngine.isContentWord` and
  `SignLanguageCatalog.hasSignableContent` now answer whether a prefix has any
  word a gloss can sign, and `LocalTranslateService._liveSequence` waits for
  content instead of signing the opening. The never-empty rule is untouched, so
  a finished caption still cannot show a blank card.
- Hindi, Tamil and Malayalam reached their words only through
  `IslSpokenCorpus` whole-sentence rules. Any prefix — and any sentence that is
  not one of the memorised lines — fell through untranslated and put the
  Devanagari spelling on the chip with no sign behind it: 183 such tokens
  (HI 166 of 64 distinct words, TA 12, ML 5). The missing words are now in
  `IslHindiLexicon.supplement` and `SpokenTextPrep._hindiGrammarTokens`, the
  Tamil and Malayalam ones in `TAMIL_SUPPLEMENT` / `MALAYALAM_SUPPLEMENT` in
  `scripts/build_indic_lexicons.py`, and Devanagari digits fold to ASCII in
  `_canonicalNative`. Every gloss was taken from the phrase corpus's own
  translation of that word, so nothing was invented. Measured: native-script
  preview tokens 183 → 0, HI preview drift 46.0% → 33.0%.

What remains is the difference between a word-by-word run and a reordered final
pass — English 56 clauses (2.6%), Hindi 33 (33.0%), Tamil 4, Malayalam 3. A Hindi
caption is the worst case because its final pass often collapses several words
into one phrase gloss (`खाना खराब हो गया है` previews as EAT BAD GO and finishes
as FOOD SPOILED) and folds a postposition into the verb (`रसोई में` previews IN,
finishes KITCHEN-IN). Both are the preview showing a real word of the caption,
not a word that was lost. Reported, not gated.

**4. An intensifier glossed as AWFUL — fixed with finding 2.** `my throat feels
very dry` and `the weather is incredibly hot` used to answer AWFUL, a different
feeling. `_compactDegreeClause` now folds only the intensifiers whose own
lexicon entry is already that degree sign (`very`, `quite`, `incredibly` → VERY;
`badly`, `severely` → SEVERE) into the clause's degree sign, and the
`AslCoreLexicon.corpusGlosses` entry for `incredibly` reads VERY instead of
AWFUL.

**5. Lexicon selection picked a neighbouring sign — fixed 2026-10-27.** 3,322 of
8,181 English lookups returned an id that was not the word, over 716 distinct
words. Most are legitimate synonym mapping (`completely` → ALL-WAY, `during` →
WHILE, `quite` → VERY). Three classes were not, and all three lived in
`scripts/build_asl_sign_lexicon.py`:

- The `names` pool had no tiers, so frequency decided between a word's own lemma
  and a *more frequent* sign that merely listed the word among its dominant
  translations: `state` → STAMP_1, `pineapple` → PICKLE, `necklace` → BIB,
  `hammer` → CARVE, `pole` → CHIMNEY, `plow` → BULLDOZER, `hang` → POSSUM,
  `earn` → CREAM, `shave` → RAZOR, `perfect` → MATCH, `imagine` → THINK_EXPAND,
  `amazing` → ORANGE_EYES. The pool now carries a tier — a word's own lemma
  (2), an entry id or dominant translation (1), an English-equivalent list (0) —
  and frequency only breaks a tie inside one tier.
- A plural no sign names inherited nothing, because the claim lived in the
  translation list of a more frequent sign (`balls` → JUGGLE, `cars` → TRAFFIC,
  `flowers` → BRIDESMAID, `matches` → SHARPEN_1). A plural now takes its
  singular's sign whenever that sign is named by the singular, unless the
  plural names something else (`blinds`, `woods`, `greens`, `tears`).
- A lemma dotted out is ASL-LEX's fingerspelled notation (`w.h.a.t`), and its
  letters normalise to the word it spells, so it used to take the WHAT slot and
  every question spelled its question word. Such a row is now alias-only and
  loses to any real sign. Rows whose SignBank gloss is unassigned
  (`~NEED-ID-GLOSS`) make no claim at all: `skate`, `skates`, `ice-skates`,
  `ice-skating`, `mop2` and `teach2` no longer reach the chip as
  `NEED-ID-GLOSS`.

Measured: 45 rows of 6,376 changed (39 corrected glosses, 5 placeholder rows
removed, 1 plural inheritance), every id checked against the sign library, and
the resolution audit still reports `dead=0`. Lookups reaching a different sign
fell 3,322 → 3,282 over 712 distinct words; the count moves slowly because most
of the corrected words are rare in the corpus. Regression tests:
`test/services/sign_language_catalog_test.dart` (`amazing` end-to-end, plus a
lookup gate over one exemplar of each rule).

What is left in this class is alias-pool narrowing, where no sign is named by
the word at all: `tools` → PLIERS, `jam` → JELLY, `links` → COOPERATE,
`sites` → SIT. Each is the closest sign the table has, not a wrong one.

**6. 27.2% of English gloss tokens are an uppercased word with no sign behind
them** — THEIR 97, SUDDEN 56, HIGHLY 52, LET 48, DATA 47, ACCURATELY 47. That
is the animation gap the sign-resolution audit measures, not a gloss bug: the
gloss word is right, the pose does not exist. HI/TA/ML sit at 2.2% because the
ISL phrase maps resolve almost every word to a core gloss first.

**7. Database keys reached the chip as labels — fixed 2026-10-27.** 39 tokens
across 11 labels read like keys rather than words: `TALL_2` (9), `E(CALM-DOWN)`
(8), `SHOP_2` (8), `ORDER_1` (4), `PROBLEM_2` (4), `MECHANIC_1`, `MAGNIFY_1`,
`I(SNAP)`, `TALL_1`, `PICNIC_1`, `ARREST_2`. All came from the ASL-LEX asset,
where the gloss column is SignBank's key, not the sign's name. `normalize_gloss`
in `scripts/build_asl_sign_lexicon.py` now drops the notation: a trailing
variant index, a letter-prefixed paren around a mouth morpheme or interjection,
a `&=` action prefix (`&=CLAPS`), and a `_/_` alternative (`RELEASE_/_FREE`);
word separators become hyphens, the app's gloss notation everywhere else
(`TRAFFIC-ON-TOP`). 566 of 6,371 rows were relabelled, no gloss label carries
that notation any more, and the audit now gates the count at zero.

**8. Past and time were left in English order — fixed 2026-10-27.** The first
past rubric counted surface `-ed`, so it read `based`, `limited`, `speed` and
`needed` as past and pushed FINISH into statements that were not past. Replacing
it exposed four engine errors on the other side, all repaired in
`sign_grammar_engine.dart`:

- `did` and `had` are the past auxiliaries and are dropped as function words, so
  `did not originate` and `had to terminate` lost their past. Both now set
  `sawPast` before the word is omitted.
- FINISH was suppressed by a neutral time word (`this weekend`, `tonight`).
  Only a past-specific anchor (`yesterday`, `last week`, `ago`, `earlier`) may
  replace it.
- A future auxiliary scopes the verbs after it, so `the grade entered on the
  form` and `items left inside` are participles, not past statements. A past
  verb before the auxiliary still marks past: `went blank, and now it won't`
  signs WILL … FINISH NOT.
- An intransitive verb followed by a preposition is still the clause's verb
  (`the two ships arrived at the coordinate` earns FINISH); a transitive one
  there is a reduced relative (`the controls used in`).

The rubric and the engine now agree on a three-way definition: `did`/`had`, an
irregular past, or a regular `-ed` in a finite position. Measured: 324 past
clauses, 0 without a marker; time signs now front when the caption opens with
them (`Every Saturday morning, I clean …` starts EVERY SATURDAY MORNING instead
of putting the phrase after the object list), 0 of 2,161 English captions leave
time late, and 0 leave content after NOT. A 4,716-caption noisy corpus
(lowercase, `um` prefix, stutter) breaks no invariant. The price is preview
drift: the preview signs the prefix as it arrives, so a prefix ending on
`arrived` or `used` shows FINISH the full sentence may withdraw. That is 74
clauses (3.4%) against 56 (2.6%) before, gated at 5.0%.

**9. The student lost negation and invented signs on long prose — measured and
scoped 2026-10-27.** The first model-output audit ran the v6 int8 export over
val and test and failed three ways: 5 of 368 negated captions and 1 of 282
future captions lost their marker, and 383 of 33,463 output tokens traced to no
caption word, lemma or documented rewrite. All of it sat in long captions. Split
by prepared-caption length the picture is a cliff: 98.2% exact at 1-6 tokens,
94.3% at 7-10, 4.5% at 11-14 and 0% at 15-20. Every untraced cluster is in the
11+ buckets, and the dropped NOTs include "No, it's about a ten-minute walk." at
6 tokens.

The student is distilled from short everyday captions, so the fix is a scope,
not a parameter: the model serves captions up to 10 prepared tokens (97.4% of
val, 97.1% of test) and the rule engine serves the rest, which is what the rules
already do perfectly because they define the target. The audit now gates
negation, WILL and untraced over served rows only, prints the all-rows number
next to it, and prints the length table that justifies the threshold. On v7 the
served gates pass: negation lost 0 of 388 val and 0 of 348 test, WILL lost 0,
untraced 0.33% of 31,412 served output tokens. The v6 graph's short-caption
negation loss ("No, …") is also gone.

**10. The encoder read its batch's padding — fixed 2026-10-27.** The exported
graph changed a caption's gloss depending on what else was in the batch. The
encoder was one `nn.GRU(bidirectional=True)` scanned over the batch tensor, so
the backward pass started at the PAD that fills the batch out to its widest
caption: `h_bwd` was `out[:, 0]`, the state after scanning every pad. Rebuilding
the v6 graph and running the same 64 captions padded to 24 tokens instead of 19
changed 11 glosses on val and 6 on test — one produced `[cha]`, another inserted
`DOCUMENT`.

The encoder is now two unidirectional GRUs; the second is fed the sequence
gathered backwards from `src_len - 1`, so its last real step is the whole
sequence summary. That matches a `pack_padded_sequence` bidirectional reference
on valid positions to 2e-7, and it exports: the gather and clamp are ordinary
ONNX ops. v7 shifts 0 of 64 captions per split under the same padding change.
The audit gained a `padding shift` gate (it is what caught this), and the
retrain cost nothing measurable — 95.11% → 95.36% val, 95.40% test unchanged.
Out-of-distribution exact fell 4.93% → 3.19%, which the encoder change does not
explain; it is reported as an open item because OOD is nonsense templates and
not a target.

## Open items

- The audit's past rubric shares `isFinitePastSurface` with the engine, so the
  two cannot disagree about which `-ed` word is a verb. It can still miss a
  class both sides get wrong; the independent parts of the rubric are `did`,
  `had` and the irregular table. Watch the list of past clauses for readings
  that look present.
- WH-not-final (2) includes one clause where the marker set is arguably right
  (`How was it?` → `HOW IX [wh-q]`) and one where a fingerspelled OVERSLEEP
  pushed WHY out of last position.
- Findings 1–5, 7, 8 and 10 were fixed on 2026-10-27; all but 6 are gated at
  zero (5 by the whole-table lexicon audit, 7 by the label gate, 10 by the
  padding-shift gate). Finding 9 was measured and scoped rather than fixed: the
  student serves captions up to 10 prepared tokens, the rules serve the rest,
  and negation/WILL/untraced are gated over served rows. Finding 6 is the
  animation gap and stays open: 26.8% of English tokens are an uppercased word
  with no pose, which is a sign-authoring problem, not a gloss one.
- OOD exact match fell from 4.93% (v6) to 3.19% (v7) across the encoder fix.
  The fix only changes states that the old graph computed from PAD, so it should
  have moved OOD the other way, if at all. Left open: it is nonsense-template
  prose the model is not asked to serve, and the rules cover it, but the drop
  is not understood yet.
- The length cliff is measured, not removed. Below the 10-token boundary the
  student is 94.3% exact at 7-10 and 98.2% at 1-6; the 11-14 bucket is 4.5%.
  Raising the boundary would mean training on longer captions, which the corpus
  does not carry today. The routing rule is the guarantee until it does.
- Hindi preview drift is down to 33.0% but still the worst of the four
  languages, because the final pass folds a postposition into the verb
  (`रसोई में` → KITCHEN-IN) and collapses a clause into one phrase gloss
  (`खाना खराब हो गया है` → FOOD SPOILED) while the preview signs word by word.
  Cutting it further means the preview running the same phrase rules, not more
  words in the lexicon.
- The Indic per-word maps now sign every word the corpus fixtures use, but
  `normalizeForGloss` on a prefix still leaves 157 distinct inflected native
  forms untranslated (243 occurrences) where the sign lexicon happens to resolve
  the word directly — `तीखा` spells SPICY from the Hindi sign table without ever
  appearing in the English word map. Those forms are the next coverage list if
  a caption arrives in a script variant the sign table does not know.
