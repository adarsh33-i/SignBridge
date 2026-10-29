# Caption → gloss student model

A tiny on-device seq2seq model that learns the rule engine's caption→gloss
behavior (distillation). It is trained entirely locally — no paid APIs.

One model serves both grammars via a control token (`<asl>` / `<isl>`).
At runtime the app keeps the deterministic rules as fallback, so the model can
only replace the grammar stage, never the lexicon stage.

## Pipeline

```
caption
  → SpokenTextPrep.normalizeForGloss   (rule-based lexicon, stays in app)
  → [MODEL] word tokens → gloss tokens  (this model)
  → avatar renderer
```

Input is the prepared English token string (Hindi/Tamil/Malayalam captions are
normalized to English by the existing rule-based lexicon first). Targets are
the rule engine's gloss sequences, including NMM chips such as `[wh-q]`.

## 1. Generate the corpus

Corpus generation runs through `flutter test` so the Flutter asset lexicons
(`rootBundle`) load exactly as they do in the app:

```bash
GLOSS_CORPUS_OUT=training/data flutter test test/tools/gloss_corpus_generator_test.dart
```

Writes `train/val/test.jsonl` (~73k pairs, 50/50 ASL/ISL) from three sources:
fixture sentence pools, a curated everyday-conversation set (greetings, needs,
health, directions, politeness), and 34k synthetic template samples covering
statements, negation, questions, past/future, progressive, copula, imperatives,
modals, health and body, documents and appointments, meals, transport, daily
routine, actions, states, quantities and prices. Splits are grouped by caption
so the same sentence never lands in both train and val; curated conversation
captions stay in train so greetings are never held out.

Current corpus: 72,845 pairs (train 65,618 / val 3,617 / test 3,610) plus the
1,440-pair OOD split. Generation is seeded, so two runs of the same code
produce byte-identical files. It is not stable across code changes: the pools
are sampled with one rng, so adding or removing one caption reshuffles which
synthetic samples land in which split.

It also writes `ood.jsonl` (1,440 pairs): compound sentences built from
templates that never appear in training (`because`, `if`, `before/after`,
reported speech, relative clauses). This is a diagnostic of zero-shot
composition, not a training target.

## 2. Train

```bash
pip3 install -r training/requirements.txt
python3 training/train.py --out training/runs/gloss_rnn_v7
```

Model: 128-dim word embeddings, bidirectional GRU encoder built from two
unidirectional GRUs (2×160), GRU decoder (320) with additive attention, ~5.1M
parameters. The second encoder GRU is fed the sequence gathered backwards from
`src_len - 1`, so neither direction ever reads the PAD a batch needs for its
longest caption. Training uses label smoothing 0.05, 5% source-word dropout
(system control token protected) and the same held-out val split for
checkpoint selection. Apple Silicon MPS is used automatically; CPU works too.

Checkpoints go to `training/runs/gloss_rnn_v7/` (`best.pt`, `vocab.json`).
Metrics printed per epoch: teacher-forced token accuracy, greedy exact-match
(overall and per ASL/ISL), and zero-shot exact-match on `ood.jsonl`.

## 3. Export

```bash
python3 training/export_onnx.py --run training/runs/gloss_rnn_v7
```

Writes `training/export/gloss_seq2seq.onnx` (fp32) and
`gloss_seq2seq.int8.onnx` (weight-only int8), then verifies that ONNX output
matches the PyTorch greedy decoder on the held-out test split.

Quantization is weight-only: linear and embedding weights are rounded to int8
with per-channel scales, GRU weights per tensor, while activations stay fp32.
onnxruntime's dynamic quantizer (which also rounds activations per tensor)
collapses this model — outliers in the decoder concat destroy attention — so
the export inserts `DequantizeLinear` nodes itself. The int8 file is ~3.7x
smaller than fp32 with near-identical greedy output.

## Results (2026-10-27, run `gloss_rnn_v7`)

Corpus: 72,845 pairs (train 65,618 / val 3,617 / test 3,610, plus 1,440 OOD),
50/50 ASL/ISL, regenerated after the caption-audit fixes (negation, reason
clauses, ASL-LEX tiers, label notation, tense rubric) so the targets are the
glosses the app actually ships. 5.11M parameters, best epoch 25 of 40 on Apple
MPS. Vocabularies: 3,959 source / 3,658 target tokens.

| Split | Token acc | Exact | ASL exact | ISL exact |
| --- | --- | --- | --- | --- |
| val | 96.99% | 95.36% | 95.02% | 95.71% |
| test | 96.94% | 95.40% | 94.84% | 96.00% |

v7 exists because the encoder was reading its own padding. The old encoder was
one `nn.GRU(bidirectional=True)` scanned over the batch tensor, so its backward
pass started from the PAD that filled the batch out to its widest caption. A
caption's gloss therefore depended on what else was in the batch: rebuilding
the v6 graph and re-running it padded to 24 tokens changed 11 of 64 val and 6
of 64 test glosses. The encoder is now two forward GRUs — the second one fed
the sequence gathered backwards from `src_len - 1` — which matches a
`pack_padded_sequence` reference on valid positions to 2e-7 and shifts 0
captions when the padding changes. That is the first gate in
`audit_model_output.py` (below). In-distribution accuracy held (95.11% → 95.36%
val) and the target vocabulary dropped 3,666 → 3,658 as the retrain collapsed a
few unused aliases.

| Slice | n | Exact |
| --- | --- | --- |
| everyday synthetic captions (val) | 3,411 | 99.77% |
| everyday synthetic captions (test) | 3,409 | 99.62% |
| fixture prose (long, complex) | 201 | 23.88% |
| unseen compound templates (OOD) | 1,440 | 3.19% |

The student is distilled from everyday templates. It is near-perfect on that
distribution, while complex multi-clause prose and unseen compound structures
remain the rule engine's job. See `audit_model_output.py`: captions up to 10
prepared tokens are the model's; longer ones should be routed to the rules.

Fallback trigger rate: 18 of 3,610 test captions (0.5%) contain at least one
source token outside `src_itos`, which maps to UNK and sends the caption to the
rules path.

ONNX: `gloss_seq2seq.onnx` 20.71 MB, `gloss_seq2seq.int8.onnx` 5.44 MB. fp32
matches the PyTorch greedy decoder on all 8,667 evaluated captions; weight-only
int8 matches 3,607/3,617 val, 3,603/3,610 test and 1,348/1,440 OOD. All counts
are reproduced by `python3 training/verify_artifacts.py` (below).

### Previous runs

`gloss_rnn_v6` (same corpus, pre-fix encoder): 95.11% val / 95.40% test exact,
best epoch 23, 3,658 target tokens, OOD 4.93%; its ONNX export read batch
padding and its OOD score was higher than v7's 3.19%, which the encoder change
does not explain.

`gloss_rnn_v5`: 95.38% val / 95.37% test, best epoch 33, 3,666 target tokens,
OOD 1.60%. The target vocabulary fell 3,679 → 3,666 without losing coverage:
566 labels were relabelled by the lexicon rebuild (a variant index `TALL_2` →
`TALL`, a SignBank paren `E(CALM-DOWN)` → `CALM-DOWN`, `_` → `-`), and 45 words
resolve to their own sign instead of a more frequent neighbour, which both
renames targets and collapses aliases. 469 of 65,618 train rows changed.

### Previous run (2026-10-22, `gloss_rnn_v4`)

val 95.22% / test 95.18% exact, best epoch 23, 3,679 target tokens, int8
matching 3,611/3,617 val, 3,607/3,610 test and 1,396/1,440 OOD. Against v3 the
target vocabulary went 3,705 → 3,679: 12 tokens added (`THERMOMETER`, `BOX`,
`DONUT`, `DOWNLOAD`, `ERASE`, …) and 38 dropped, almost all of them the loose
ASL-LEX aliases the name-versus-alias tier removed (`GET`, `MAYBE`, `NO`,
`I-LOVE-YOU`, `NECKLACE`, …). Earlier runs: `gloss_rnn_v3` 94.97% val / 94.88%
test, `gloss_rnn_v2` 94.81% val / 94.36% test, and the earlier 3.77M model
92.14% test exact on the smaller 60.8k corpus. Each run was trained on a freshly
regenerated corpus, so the splits shuffle between them and these deltas are not
a controlled model comparison.

**Five authored signs are still outside the corpus.** `HUG`, `BLOW`, `WINDY`,
`THUNDER`, and `THANK_YOU` resolve to hand-authored animations the caption
pipeline never produces as targets (the corpus spells that last one
`THANK-YOU`, which is why the catalog keys signs by id and not by gloss), so the
model cannot predict them and those captions fall through to the rules. `NO` is
not among them — the grammar engine turns "no" into `NOT` plus a headshake
marker, so a bare `NO` is not a target the model is asked for.

## 4. Verify an artifact

```bash
python3 training/verify_artifacts.py --run training/runs/gloss_rnn_v7 --samples 4000
```

Read-only check of a trained run against the corpus: vocab sizes versus
state-dict shapes, greedy exact-match per split and per corpus source, UNK
rate, and PyTorch-versus-ONNX parity for both exported graphs. An artifact
older than v7 will not load: the encoder was split into two unidirectional
GRUs.

## 5. Audit the model output

```bash
python3 training/audit_model_output.py --run training/runs/gloss_rnn_v7 \
    --out /tmp/model_audit.txt
```

Runs the int8 graph the app would load over every split and applies the gloss
invariants, printing a per-caption-length breakdown of each:

| Gate | Limit | Why |
| --- | --- | --- |
| Empty gloss | 0 | a caption that signs nothing is a dead card |
| Label outside gloss notation | 0 | the chip must never show native script or a database key |
| Negation lost | 0 | a negated caption that signs no NOT/NO/headshake |
| WILL lost | 0 | a future caption that signs no WILL |
| Non-deterministic | 0 | the same batch twice must give the same gloss |
| Padding shift | 0 | the same caption padded to 24 tokens must give the same gloss |
| Untraced token | 1% | a token that traces to no caption word, lemma or rewrite |

Negation, WILL and untraced are gated over the rows the model serves — captions
up to `--model-max-tokens` (default 10) prepared tokens. Longer captions are the
rule engine's job; their numbers are printed but do not gate, because the rule
engine defines the target and cannot lose it. The OOD split is a zero-shot
diagnostic built from nonsense compound templates and is never gated.

v7 result: every gate passes on val and test. Empty 0, label leaks 0, negation
lost 0 of 388 served val / 0 of 348 served test, WILL lost 0 of 293 / 0 of 269,
padding shift 0 of 64 checked per split, untraced 0.33% of served output (62 val
+ 43 test tokens out of 31,412). The int8 graph scores 95.33% val / 95.40% test
exact against 95.36% / 95.40% for PyTorch greedy in the table above; the gap is
three val captions. The pre-fix v6 graph, rebuilt with the old
encoder, shifted 11 of 64 val and 6 of 64 test glosses when the same rows were
padded wider, and lost negation on the short caption "No, it's about a
ten-minute walk.". OOD, reported only: 3.19% exact, 27 of 186 negated captions
unmarked.

The length breakdown is the evidence for the routing threshold: 98.2% exact at
1-6 tokens, 94.3% at 7-10, then 4.5% at 11-14 and 0% at 15-20 (val; test is
98.5 / 95.4 / 1.4 / 9.1). Every untraced-token cluster and both negation losses
outside the served range sit in 11+ tokens, so the model is not asked to sign
prose.

Every split is also printed by sign language, so the ISL half is checked
independently of ASL. v7, served rows: ASL 95.0% val / 94.8% test exact,
untraced 22/8,399 and 13/8,310 tokens (0.26% / 0.16%), negation and WILL 0;
ISL 95.7% / 96.0% exact, untraced 40/7,437 and 30/7,266 (0.54% / 0.41%),
negation 0/181 and 0/172, WILL 0/130 and 0/140. The two grammars share one
model and one `<asl>`/`<isl>` control token; the per-system numbers are what
show neither half is carried by the other.

## 6. Runtime contract (for app integration)

- Tokenize prepared English with `[a-z0-9]+(?:'[a-z]+)?(?:-[a-z0-9]+)*` on
  lowercased text, prepend `<asl>` or `<isl>`, truncate to 24 tokens.
- Feed `src` (`int64[batch, seq]`) and `src_len` (`int64[batch]`). Padding
  values are ignored, so batch size and pad width cannot change the output.
- The graph returns `gloss_ids` (`int64[batch, 32]`). Decode with
  `vocab.json` `tgt_itos`, stopping at EOS (id 3); ids 0 (PAD) and 2 (BOS)
  are skipped.
- Route captions longer than 10 prepared tokens to the rule engine: the student
  is distilled from short everyday captions and drops to 4.5% exact beyond that
  length.
- If any source token is missing from `src_itos` (mapped to UNK), or the output
  is empty or malformed, fall back to the rule engine.

## Notes

- The corpus is regenerateable and git-ignored; checkpoints are git-ignored.
- The model cannot invent sign vocabulary: unknown words should be sent
  through the rules path (hybrid), which guarantees best-effort output.
- Tamil/Malayalam distributions are represented through prepared English
  (the rule lexicon normalizes them), not as native-script model tokens.
- `python3 scripts/build_indic_lexicons.py` rebuilds the Hindi/Tamil/Malayalam
  word maps in `lib/services/translate/`. Improving them improves the prepared
  English the model sees, so regenerate the corpus and retrain afterwards.
