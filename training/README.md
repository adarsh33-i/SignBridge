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
python3 training/train.py --out training/runs/gloss_rnn_v4
```

Model: 128-dim word embeddings, bidirectional GRU encoder (2×160),
GRU decoder (320) with additive attention, ~5.2M parameters. Training uses
label smoothing 0.05, 5% source-word dropout (system control token protected)
and the same held-out val split for checkpoint selection. Apple Silicon MPS is
used automatically; CPU works too.

Checkpoints go to `training/runs/gloss_rnn_v4/` (`best.pt`, `vocab.json`).
Metrics printed per epoch: teacher-forced token accuracy, greedy exact-match
(overall and per ASL/ISL), and zero-shot exact-match on `ood.jsonl`.

## 3. Export

```bash
python3 training/export_onnx.py
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

## Results (2026-10-22, run `gloss_rnn_v4`)

Corpus: 72,845 pairs (train 65,618 / val 3,617 / test 3,610, plus 1,440 OOD),
50/50 ASL/ISL, regenerated after the ASL-LEX name-versus-alias fix so the target
glosses match the lexicon the app actually ships. Model: 5.13M parameters, best
epoch 23 of 40 on Apple MPS. Vocabularies: 3,959 source / 3,679 target tokens.

| Split | Token acc | Exact | ASL exact | ISL exact |
| --- | --- | --- | --- | --- |
| val | 96.95% | 95.22% | 94.75% | 95.71% |
| test | 96.93% | 95.18% | 94.41% | 96.00% |

Prior runs: `gloss_rnn_v3` 94.97% val / 94.88% test, `gloss_rnn_v2` 94.81% val /
94.36% test, and the earlier 3.77M model 92.14% test exact on the smaller 60.8k
corpus. Each run was trained on a freshly regenerated corpus, so the splits
shuffle between them and these deltas are not a controlled model comparison.

What v4 does change is the target distribution, not the model. Against v3 the
target vocabulary went 3,705 → 3,679: 12 tokens added (`THERMOMETER`, `BOX`,
`DONUT`, `DOWNLOAD`, `ERASE`, …) and 38 dropped, almost all of them the loose
ASL-LEX aliases the name-versus-alias tier removed (`GET`, `MAYBE`, `NO`,
`I-LOVE-YOU`, `NECKLACE`, …). Source vocabulary is unchanged at 3,959.

**The corpus is older than the newest authored signs, and this is the known
gap.** Five glosses the app can now resolve to a hand-authored animation never
appear in any corpus split, so the model cannot predict them and the caption
falls through to the rules: `HUG`, `BLOW`, `WINDY`, `THUNDER`, and `THANK_YOU`
(the corpus spells that one `THANK-YOU`, which is why the catalog keys signs by
id and not by gloss). `NO` is not among them — the grammar engine turns "no"
into `NOT` plus a headshake marker, so a bare `NO` is not a target the model is
asked for. Regenerating the corpus from the current `SignLibrary` ids closes it;
until then those five are rule-engine-only.

Diagnostics over the whole test and OOD splits:

| Slice | n | Exact |
| --- | --- | --- |
| everyday synthetic captions | 3,409 | 99.38% |
| fixture prose (long, complex) | 201 | 23.88% |
| unseen compound templates (OOD) | 1,440 | 1.81% |

The student is distilled from everyday templates. It is near-perfect on that
distribution, while complex multi-clause prose and unseen compound structures
remain the rule engine's job; the runtime contract below keeps the rules as
fallback, so model errors cannot produce an empty or malformed gloss.

Fallback trigger rate: 18 of 3,610 test captions (0.5%) contain at least one
source token outside `src_itos`, which maps to UNK and sends the caption to the
rules path.

## 4. Verify an artifact

```bash
python3 training/verify_artifacts.py --run training/runs/gloss_rnn_v4 --samples 4000
```

Read-only check of a trained run against the corpus: vocab sizes versus
state-dict shapes, greedy exact-match per split and per corpus source, UNK
rate, and PyTorch-versus-ONNX parity for both exported graphs. For v4, ONNX
fp32 matches PyTorch greedy on all 8,667 evaluated captions; weight-only int8
matches 3,611/3,617 val, 3,607/3,610 test and 1,396/1,440 OOD (int8 drifts
where the model is already uncertain). Sizes: 20.78 MB fp32, 5.45 MB int8.

## 5. Runtime contract (for app integration)

- Tokenize prepared English with `[a-z0-9]+(?:'[a-z]+)?(?:-[a-z0-9]+)*` on
  lowercased text, prepend `<asl>` or `<isl>`, truncate to 24 tokens.
- Feed `src` (`int64[batch, seq]`) and `src_len` (`int64[batch]`).
- The graph returns `gloss_ids` (`int64[batch, 32]`). Decode with
  `vocab.json` `tgt_itos`, stopping at EOS (id 3); ids 0 (PAD) and 2 (BOS)
  are skipped.
- If any source token is missing from `src_itos` (mapped to UNK) or the
  output looks malformed, fall back to the rule engine.

## Notes

- The corpus is regenerateable and git-ignored; checkpoints are git-ignored.
- The model cannot invent sign vocabulary: unknown words should be sent
  through the rules path (hybrid), which guarantees best-effort output.
- Tamil/Malayalam distributions are represented through prepared English
  (the rule lexicon normalizes them), not as native-script model tokens.
- `python3 scripts/build_indic_lexicons.py` rebuilds the Hindi/Tamil/Malayalam
  word maps in `lib/services/translate/`. Improving them improves the prepared
  English the model sees, so regenerate the corpus and retrain afterwards.
