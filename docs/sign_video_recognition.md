# Reading a sign clip on the phone

The Talk → Sign camera watches a clip being signed and the app has to say what
was in it. Nothing here calls a paid model, and nothing here leaves the phone.

```
camera frames while the clip is watched → skin mask → one blob per frame
        → track features → hand-written rules → gloss
                           → caption + avatar re-signs it
```

## Why recognition runs on live frames

No part of this app decodes MP4 video, and no MP4 is written. `SignCameraRecorder`
streams the preview and samples it ten times a second; each sample is reduced to a
`HandFrame` before it is dropped, and those frames are all the recognizer ever
reads.

Recording an MP4 next to the stream is what forced this. `CameraPreview` trusts
the orientation frozen at the moment a recording starts while the Android plugin
keeps following the live device orientation, so tilting the phone after the record
tap turned the preview a quarter turn sideways mid-sign. Streaming alone also
removes the case that used to swallow every frame: the camera package refuses an
image stream while a video recording owns the camera, so a clip recorded this way
reached the recognizer with nothing in it. That now reports `nothingSeen`, the
same outcome an empty camera gives.

`CameraFrameReader.toGrid` accepts planar YUV420, semi-planar chroma, NV21 and
BGRA, and returns null for anything else. A frame it cannot read is dropped, not
guessed at. One step is used for both axes so cells stay square; the grid is
about 80 cells across, which is enough for shape and cheap enough to run at
camera rate.

## What a frame is turned into

`SkinMask` keeps pixels inside the BT.601 chroma bands for skin: luma above 80,
Cb between 77 and 127, Cr between 133 and 173. Luma rejects the shadows that sit
in the same chroma band. Grey lands exactly on the chroma centre and is rejected
by the band edges.

The largest 4-connected run of skin cells is the hand. Everything else is
background: a second face, a sleeve, sensor noise. A run below 2% of the grid is
not a hand at all. `GestureTrack` then reads the whole clip:

| Feature | What it is | Why it is there |
| --- | --- | --- |
| `meanCenterY` | height band: high < 0.36 ≤ mid < 0.64 ≤ low | height carries meaning in ASL |
| `fingerRuns` | most separate skin strips any one row crosses in the top 60% of the blob | the only honest open-hand test |
| `xSwings`, `ySwings` | direction changes bigger than 0.07 of the frame | a wave is two, jitter is none |
| `xTravel`, `yTravel` | how far the centre actually got | stillness, see below |
| `meanCoverage` | share of the grid the hand covers | a pushed-out palm is big |

Two of these were measured rather than assumed, and both were wrong before:

- **Openness.** Bounding-box fill ratio separates a fist (0.21–0.29) from an open
  hand (0.32–0.46) far too weakly to gate a rule on. A still fist was being
  announced as STOP. `fingerRuns` replaced it: a fist is one strip on every row,
  a spread hand is three or four, and the threshold sits at 2 because two already
  rules a fist out.
- **Stillness.** Path length accumulates jitter — a trembling hand walked 0.92 of
  the frame without going anywhere. `isStill` now uses travel (`xTravel < 0.1 &&
  yTravel < 0.1`), which is the box the hand stayed inside.

## The rules

`GestureClassifier.classify` returns a gloss or one of four typed refusals. The
first three rules win in order, so a held palm is never read as a wave.

| Gloss | Shape and motion required | Confidence |
| --- | --- | --- |
| `STOP` | mid height, open hand, coverage ≥ 5%, travel under 0.14 | 0.60 |
| `HELLO` | high, at least two sideways swings | 0.70 open, 0.55 closed |
| `YES` | nodding: two or more vertical swings, under two sideways, not high | 0.60 |
| `NO` | shaking: two or more sideways swings, under two vertical, not high | 0.60 |
| `PLEASE` | mid height, open, swinging in both axes | 0.50 |

`LocalSignCaptureService` answers at 0.5 confidence or not at all. Refusals:

| Outcome | When | What the user is told |
| --- | --- | --- |
| `nothingSeen` | hand in under 15% of frames, or no frame reached the recognizer | no hand was in frame |
| `tooShort` | fewer than 3 frames with a hand | too short to read |
| `heldStill` | the hand never got anywhere | your hand stayed still |
| `unclear` | no rule matched | could not tell, with the five signs it does know |

This vocabulary is deliberately small and it is the honest limit of shape plus
motion rules. It is not a gap to paper over: the class doc in
`LocalSignCaptureService` names the sentence this used to invent ("My name is
Alex. I am deaf.") for every clip, whatever was signed, and the reason it stopped.

## Where a bigger vocabulary comes from

Five signs is the reach of shape plus motion. Past it needs a model trained on
labeled hand clips, and that training set is built off the phone in
`training/video`: the ASL and ISL signer clips in the existing asset bucket are
already one-per-gloss, so nobody has to record and label clips through the app.
The app itself saves nothing. An earlier build put a **Save for training** action
on every refusal and kept an MP4 for it; that went with the MP4.

## Checks

```
flutter analyze --no-pub
flutter test test/vision test/services/sign_capture_service_test.dart \
  test/services/sign_capture_error_mapper_test.dart
```

`test/vision/synthetic_hand_frames.dart` draws a fist as a filled disc and an
open hand as four two-cell fingers with two-cell gaps, joined to a palm block so
the whole shape is one blob. The classifier tests assert the refusals as well as
the recognitions: a still fist must not become STOP, and a long drag with no
swing must name nothing.
