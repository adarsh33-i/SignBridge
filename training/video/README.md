# Video signer model: clip → landmark track → gloss retrieval

Recognises a sign from the camera without any paid model. It learns from the
ASL and ISL signer clips already in the R2 bucket (`signbridge-sign-videos`,
served by the `sign_assets` worker), so nobody has to record and label clips
through the app first.

Everything here runs locally and free: `uv` + PyTorch on the Metal GPU,
MediaPipe for landmarks, `onnxruntime` for the shipped encoder. No subscription
API is called at any stage.

This is a second, independent model. The deterministic caption→gloss student in
`training/README.md` and the rule-based live recognizer in
`lib/services/vision/` are untouched and still serve as fallback.

## Why retrieval, not a classifier

The bucket has one clip per gloss (11,346 clips, 4,475 ASL + 6,965 ISL). A
11k-way softmax would memorise the clip it was trained on rather than the sign,
so there is nothing to supervise a classifier with. Instead a small GRU encoder
maps a 1.6 s window of landmarks onto a 128-d unit vector, trained with NT-Xent
so that two different windows of the same clip land closer together than either
lands to any other clip. At recognition time the app embeds the live window and
takes the nearest reference in a pre-computed bank.

Dot-product nearest neighbour over ~34k 128-d vectors is a few hundred
microseconds; a DTW search over 11k references would not run on a phone.

## Feature layout

Per frame, 94 floats, sampled at 10 fps and cut into 16-frame windows with
stride 8:

| block | floats | what |
| --- | --- | --- |
| hand slot 0 / slot 1 | 46 each | 21 landmarks as x,y in a body frame, plus spread, palm-roll sin and cos, and a present flag |
| pose present | 1 | whether the body landmarks anchored this frame |
| hand count | 1 | how many hands were detected |

The body frame is what makes the track independent of where the signer stood.
On Android the same 21 points come from the same MediaPipe landmarker, so the
features reproduce.

Hand slots are assigned by handedness, not left-to-right, so a signer who turns
around does not swap hands mid-window.

## The frame the phone can actually build

The landmarker on a phone reports the 21 points of each hand and nothing about
the body. So the only frame the device can produce is: origin at the mean of the
wrists of the hands that survive into the row, unit of length 2.6 x the mean
wrist-to-middle-knuckle of exactly those hands. It is scale-free, so it does not
care how far the signer stood.

`video_corpus.wrist_frame` converts the shoulder-normalised corpus into that
frame, and `extract_tracks.py --no-pose` extracts it directly. Training and
export use the converted corpus; `train_match.py --native-frame` keeps shoulder
normalisation and exists only as a baseline, because no live query can be
compared against it.

Two guards decide when a hand is not usable:

* a palm under 5% of its own fingertip span (`MIN_PALM_FRACTION`) is a collapsed
  detection, not a small hand. Dividing a row by it multiplies tracker jitter, and
  a hand dropped from the row must not quietly set the ruler for the one that
  stays - `extract_tracks._body_frame` and `wrist_frame` apply the same test for
  exactly that reason.
* a hand shorter than 100 storage steps (`MIN_PALM_STEPS`) cannot be described by
  a row kept at half precision, so `load_tracks` empties the row instead of
  training the model on a frame the phone would report differently.

`check_wrist_frame.py` proves this against ground truth rather than arguing about
it: the same 1,813 clips extracted twice, once with pose and once without,
compared row for row. Which slots a row trusts, how many hands it counts and
whether an unanchored row is empty have to match exactly, because those are the
rule; the landmark numbers get a tolerance, and that tolerance is judged against
the tracker's own movement, not a preference.

| run | result |
| --- | --- |
| float32 pair, tolerance 1e-4 | rule exact on all 46,973 hand rows and all 33,105 empty rows; worst difference 0.00017, in the `spread` column of two hands at the collapsed-detection gate (span/palm 17.9-19.6 against a corpus median of 1.65), where the field is a ratio over a near-vanishing palm |
| shipped float16 corpus vs that ground truth, tolerance 0.02 | rule exact; the loader empties 1,203 rows (2.56%) that half precision cannot carry, worst difference left 0.026 |
| reference | the mean landmark of one hand moves 0.0886 wrist units between consecutive sampled frames, so the corpus is wrong by less than a third of a real frame step |

## Honest evaluation

Reference windows come from the first half of each clip, queries only from the
second half, so a hit can never be a copy of the same frames. That is what
`video_corpus.split_windows`, `verify_video_match.disjoint_bank_windows` and the
tests in `test_video_corpus.py` protect — `test_the_shipped_whole_clip_bank_would_leak`
pins the reason the deployed bank (whole clips, 3 windows each) is deliberately
not the bank these scores are computed against.

What the numbers measure: robustness to sign phase, speed, framing and
hand-mirroring. What they cannot measure: **a different signer**. Every gloss in
this corpus has exactly one clip by one signer, so cross-signer accuracy is
unknown and has to be measured on a phone, not here.

Absolute cosines are useless on this data (all similarities sit near 0.97), so
the acceptance threshold is set on the margin between the best and second-best
hit, and reported as a coverage curve.

### What the shipped frame scores

`runs/video_match_wrist` (240 epochs, 11,005 clips) is the run whose weights are
in the app. It was trained and verified through `video_corpus.wrist_frame`, so
these are the numbers a phone can hope to reproduce:

| measure | wrist frame | native frame (needs shoulders) |
| --- | --- | --- |
| single-window top-1 | 19.53% | 22.74% |
| 2-window top-1 | 34.81% | 41.06% |
| answered at margin 0.01 | 30.6% | 37.5% |
| answered at margin 0.02 | 28.6% | 35.6% |
| correct among those answered | 100% | 100% |

Losing the shoulders costs about 6 points of coverage. It is still the frame to
ship: the app has no body landmarks, so the native-frame column describes an
input the phone cannot produce. Chance is 0.0136%.

## Pipeline

```bash
uv venv training/video/.venv --python 3.11
training/video/.venv/bin/python -m pip install -r training/video/requirements.txt

# 1. corpus: fetch → extract landmarks → delete the mp4, ~1.5 GB peak disk
./training/video/build_corpus.sh 400 6

# 2. train the encoder in the phone's frame and build the retrieval bank
training/video/.venv/bin/python training/video/train_match.py \
  --epochs 240 --batch 1024 --views-per-clip 4 --export \
  --out training/video/runs/video_match_wrist

# 3. parity, latency, honest top-k, margin/coverage curve
training/video/.venv/bin/python training/video/verify_video_match.py \
  --run training/video/runs/video_match_wrist

# 4. the files the app bundles, and the device feature-row fixture
training/video/.venv/bin/python training/video/export_deployable.py \
  --run training/video/runs/video_match_wrist
training/video/.venv/bin/python training/video/export_row_parity.py \
  --cases 400 --seed 7

# 5. invariants
training/video/.venv/bin/python -m unittest discover -s training/video -p 'test_*.py'
```

The build is resumable: `data/downloaded.jsonl` and `data/tracks_index.jsonl`
record what is done, so a re-run skips it even after the mp4s are deleted. The
two free `.task` model files download themselves on first run.

| file | role |
| --- | --- |
| `fetch_r2_clips.py` | concurrent, resumable clip download through the public worker |
| `extract_tracks.py` | one clip → one normalised landmark `.npz`; `--no-pose` extracts the device frame directly |
| `build_corpus.sh` | the chunked fetch → extract → delete loop |
| `video_corpus.py` | windows, augmentation, the half-clip split, the wrist frame and its two guards (shared by training and export) |
| `train_match.py` | NT-Xent encoder + bank builder + ONNX export |
| `check_wrist_frame.py` | proves the wrist-frame conversion against a real no-pose extraction, rule and numbers separately |
| `verify_video_match.py` | ONNX↔torch parity, latency, honest scores, operating curve |
| `export_deployable.py` | the run → flat float32 weight blob, int8 bank, clip index, manifest and golden windows for the Dart test |
| `export_row_parity.py` | raw landmarks → the 94-float row the extractor writes, as the fixture `test/vision/sign_feature_row_test.dart` reads |

`export_deployable.py` writes into the run directory; the four files the phone
bundles are copied to `assets/models/video_match/` and the two the Dart tests
read are copied to `test/fixtures/video_match/`. `test/vision/video_match_model_test.dart`
pins the bundled copy to the measured export (11,005 clips, margin 0.02).

## Running the encoder on the phone without ONNX

`export_deployable.py` writes `video_embed.f32.bin` (145,761 float32, 0.58 MB),
`video_bank.i8.bin`, `video_bank_clip_index.bin`, a manifest and eight golden
windows with the embedding torch computed for each. `lib/services/vision/
landmark_encoder.dart` reads those and does the same arithmetic in pure Dart -
GRU, masked attention pooling, exact-erf GELU - and `test/vision/
landmark_encoder_test.dart` fails if it disagrees with torch by more than 1e-4.
`lib/services/vision/gloss_bank.dart` then searches the int8 bank and only answers
when the best clip beats the runner-up by the exported margin; a null result means
fall through to the rule recognizer, never guess.

Measured on the shipped wrist-frame run: pure Dart reproduces torch's embedding on
the eight golden windows to 2.2e-7, and `export_deployable.py` reports that of
the 962 golden windows that clear the shipped margin of 0.02, the int8 bank names
a different clip on 0, and moves the accept margin by at most 0.0042. Two of the
62 windows both banks already decline changed their nearest clip, which is a coin
toss the app never shows. That is why the gate is 0.02 and not 0.01: a
quantisation shift of a hundredth would otherwise be able to promote a tie into
an answer.

`lib/services/vision/sign_feature_row.dart` is the other half: it turns the 21
landmarks the phone reports into the row above, with the same collapsed-palm
guard, and `export_row_parity.py` generates its fixture from the extractor so a
Dart change that drifts from training fails. `gloss_segmenter.dart` sits on top
and turns a run of windows into one word, so a sign held for three seconds is not
repeated; a window with no hands in it ends the run instead of being queried.

## Provenance and licence

Clip list and gloss labels come from `assets/signs/manifest.json`.

- ASL: `ZahidYasinMittha/American-Sign-Language-Dataset`, listed as
  "MIT (verify scraped-source rights before commercial release)". **Check this
  before shipping.**
- ISL: `bridgeconn/sign-dictionary-isl`, CC-BY-SA-4.0.
