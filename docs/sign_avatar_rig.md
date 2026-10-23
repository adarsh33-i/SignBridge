# 2D signing avatar rig

Gloss sequences are rendered by a drawn character, not a video. The renderer is
pure Flutter (`CustomPainter`) and all motion is data, so a sign can be added
without touching drawing code.

```
gloss tokens → SignLibrary.forSequence → SignAnimation timeline → IdleLayer → AvatarPainter
```

## Joint convention

Angles are degrees measured from **straight down**, positive toward the
viewer's right, and the renderer mirrors them for the other arm.

| Field | Meaning |
| --- | --- |
| `shoulder` | 0 = arm at the side, 90 = out horizontal, 120 = raised past horizontal |
| `elbow` | flexion added on top of `shoulder`; ~170-200 puts the hand in front of the chest, ~100 with shoulder 118 puts it beside the temple |
| `wrist` | further rotation of the palm |
| `palm` | 0 = palm faces the viewer, ~150 = back of the hand |
| `lift` | elbow drawn outward, reads as reaching into signing space |

A flat 2D projection cannot express depth, so a hand that is really *in front of*
the chest is drawn as a nearly-folded elbow. Values above 180 are expected and
correct here; do not "fix" them.

One exception worth memorising: with the shoulder above ~100, an elbow flexion
past roughly 110 swings the forearm inward and lays the fingers across the
eyes. Head-height signs (`hello`, `father`, `home`, `see`, `know`) are authored
at elbow 98-106 so the wrist lands at the temple, beside the head rather than
in front of it. The face carries grammar, so it never gets covered.
`test/avatar/rig_render_test.dart` pins the first keyframe of each of those
signs as `goldens/face_*.png`.

## Handshapes

`HandShape` stores fractional curls (0 extended → 1 in the palm) plus thumb
placement and finger spread. Curls interpolate, so a sign that opens from a
fist to a flat hand moves the fingers instead of snapping them.

Two joints per finger, like a real one:

- the knuckle (`mcp`) takes the first 55% of the curl and leans the finger
  sideways,
- the middle joint (`pip`) carries the rest, so a curl of 1 closes the finger
  back onto its own palm instead of pushing it forward.

A fold stops turning at 112 degrees (`_maxFold`) and the rest of the curl is
spent shrinking the drawn segment instead. Turning further lays the second link
back beside the first and the finger becomes a hairpin: its tip surfaces under
its own knuckle and pokes past its neighbour, which drew a sawtooth on a fist
and a gear-tooth crown on a bent hand. Foreshortening is what a real finger
does past that angle in a flat front view — it sinks toward the knuckle line
rather than getting longer on screen.

Neighbouring fingers are separated by thread-thin seams cut out of the union,
kept only where two digit paths actually touch and the contact runs longer than
`_unitFinger * 0.6`. Below that cut a thread is a stray dash on the back of the
hand rather than the edge of a finger.

Thumb values are an arc, not a direction: `thumb` 0 tucks it across the palm
and 1 swings it out beside the index. `thumbUp` pulls that swing back to
vertical, which is what letters like A and fingerspelled R need. `spread`
widens the fan and `thumbSpread` pushes the thumb further from the palm.

Fingers fan from the hand's own centre line and the fan mirrors with the hand,
so the thumb always sits beside the index. The fan is deliberately gentle
(`-fan * 0.62`): wide enough that four fingers read as four, narrow enough that
they never cross and tangle their outlines.

No two fingers are the same size. `lengthScale` and `widthScale` in
`_paintHand` make the middle the longest and the pinky three quarters of it,
each a little narrower than its neighbour, so a hand is not four copies of one
finger.

`HandShape.relax` — the hand hanging at the side — stays nearly straight. A
relaxed hand cannot be drawn curling: in a flat front view, fingers curling
"forward" curl into the screen, so any real curl shows up as four fingers
bending sideways into a pile. The curl there is 0.06 to 0.12, and the rest is
done by the stagger between them.

`FingerspellShapes.letters` holds the 26 one-handed letters shared by ASL and
ISL. They are approximations, and `fingerspell` groups a word into one animation
whose gloss is the whole word, so the chip names the word being spelled rather
than leaving the viewer to read twenty-six separate letters.

## Coverage is tiered

1. **Authored motion** — `SignLibrary._core`. Real movement patterns: waves,
   nods, taps, circles, repetitions. Currently 56 ids: the everyday core set,
   the weather set (RAIN, SNOW, WIND, WINDY, CLOUD, STORM, THUNDER, LIGHTNING,
   FOG, WEATHER, COLD, HOT, SUN), and an everyday-verb set added when the gloss
   audit found words that had lost their authored sign to an alias — ASSIST,
   BLOW, CONSUME, ENJOY, FINANCE, HUG, MENTION, NEGATIVE, RELATIONSHIP, SHOWER,
   THERMOMETER, VISION, WATCH.
2. **Non-manual markers** — tokens whose id starts with `nmm_` animate the face
   only (brow, head tilt, head turn, mouth), never the hands.
3. **Fingerspell** — everything else is spelled letter by letter with a small
   drop between letters. An unknown gloss is never rendered as a random
   invented sign. A word written in a script the manual alphabet has no letters
   for is transliterated first (`IndicSpelling.toLatin`), so गर्म spells `garma`
   instead of freezing; that is what ISL does for a word with no sign of its
   own. An id with no letters left after that contributes no animation at all
   rather than a blank hold.

Two lookups sit in front of the fingerspell tier. ASL-LEX numbers the variants
of one sign (`snow_2`, `cloud_4`), so a numbered id resolves to its base sign,
and the `-y` weather words (cloudy, snowy, rainy, sunny, foggy, stormy) resolve
to the noun's sign; freezing and chilly take COLD and thermometer takes
THERMOMETER. That alias map is only for a word whose id names the very sign
already authored. It is not for a word that merely means something close: HUG
is not LOVE and CONSUME is not EAT, so those get their own animation.

Weather signs are authored as handshape plus one direction, held for two passes,
because a caption strings four or five of them together and a longer path stops
reading as a sign. That makes near-duplicates the failure mode: RAIN and SNOW
shared a handshape, CLOUD/STORM/WINDY shared a silhouette, and SUN/WEATHER/
LIGHTNING all raised one finger at the head. Each pair is now separated by the
handshape or by the zone it moves through.

`test/avatar/sign_library_test.dart` pins that no two of the 56 authored signs
open in the same pose. That check used to cover the weather set only; widening
it to everything immediately found a pre-existing collision between MOTHER and
THANK-YOU, which is now separated by MOTHER's palm.

Authoring more core signs is the ongoing work: add an entry to `_core` keyed on
the token id the gloss engine emits, then pin a frame in the golden test.

## Reach: what the joint model can and cannot touch

Two measured limits decide where a sign can be authored, and both were found by
sweeping `AvatarPainter.armOf` over the whole angle range rather than by
guessing.

- **The face.** The shoulder joint sits at x 0.68 of the card and the head
  spans 0.40–0.60, so an arm that reaches a facial feature has to point the
  upper arm almost straight up and fold the forearm back across the face. Below
  shoulder ~140 the wrist stops at x 0.60 and the hand sits *beside* the head,
  which is where most of the authored face signs started. `_FaceSpot` holds the
  angles for each landmark. The upper-face entries are deliberately the
  shallowest reach that still touches: the same sweep showed an open hand driven
  deeper lays across the eyes and erases the facial grammar the signs depend on,
  so `forehead` and `temple` stop at 138 and 130 while `eye`, which only narrow
  handshapes use, goes to 146.
- **Hand against hand.** The two hands of a `_two` pose can never actually
  meet. Across every shoulder and elbow the rig reaches, the closest the two
  wrists get is 0.21 of the card, and a palm is 0.078. The hanging support arm
  these signs were originally authored over left them 0.36 apart, so the support
  arm is now folded hard and lifted, which brings the base close enough for the
  dominant hand to finish the gesture onto it. A mirrored `_both` pair has the
  opposite problem: it reaches the temples at shoulder 134 with the fingertips
  still 0.14 apart, and past 142 the two hands overlap and cross the eyes.

Neither limit is fixable by authoring. Closing the hand-to-hand gap needs a
transverse adduction term in `ArmPose` — the arm currently has one rotation
plane plus a `lift` proxy — and that is a rig change, not a sign change.

A third limit is not a rig fault and will not go away: ASL puts a great many
signs on the forehead, so HELLO, FATHER, KNOW, RAIN, SNOW, SHOWER and WEATHER
share one silhouette family and are told apart by handshape and travel
direction, not by where the hand is. Rendered still at card size they look like
cousins; only the motion separates them. Judge them in the GIF, never as
thumbnails.

There is no reference footage in the repo: `assets/signs/asl/` is empty and the
manifest points at videos that were never downloaded. Every sign above is
authored from knowledge of ASL, not traced from a corpus, and the golden frames
are the only record of what they were judged to look like.

## Look: how the drawing is put together

`AvatarPainter` works in unit space (0..1, scaled by the shorter canvas axis),
so the character keeps its proportions at any card size. Two rules hold it
together:

- **Ink then fill.** Every silhouette is stroked in the outline colour and then
  filled, so the dark line survives only on the outside edge. The whole arm is
  one stroked path — shoulder, elbow, wrist — rather than two overlapping
  capsules, otherwise each joint grows a dark ring and the arm reads as a
  glove.
- **Depth from shade, not perspective.** The arm with the lower shoulder is
  drawn in a lerped skin tone, so a flat rig still says which side is nearer.
  It used to also be drawn *behind* the torso, and that was the bug: the shirt
  is a filled path, so it ate every part of that limb crossing the shoulder
  line, which is any far hand raised into signing space. Measured on a 360px
  render, 12 of the 30 authored signs lost 10-26% of the far arm's length to the
  shirt (`friend` and `name` worst, every frame), and the hand came out detached
  from its own arm. Both arms now go over the torso; the far one still goes
  under the head, which is where a hand at the cheek belongs.
  `test/avatar/shoulder_overlap_test.dart` checks this on rendered pixels, not
  on the geometry that produces it: it walks `AvatarPainter.armOf` for both arms
  across all 30 signs and 11 timeline positions and fails if any sample of a
  limb or hand comes back the shirt's own colour.
- **The sleeve only exists while the arm hangs off the shoulder.** Cloth
  attached to a shirt reads as cloth only while the upper arm drops into the
  shirt's own silhouette. Two things break that: lifting the arm clear of the
  body, and folding the elbow far enough that the forearm comes back up — the
  second is every sign whose hand sits at the face, and it left the band sitting
  directly under the wrist, reading as an armband. `_paintSleeve` therefore
  retracts the sleeve up the arm and off it, ramped by
  `_ramp(0.25, 0.55, raise)` against `_ramp(0.10, 0.45, forearmUp)`. Ramped, not
  switched: a hard threshold was measured jumping 1,194 sleeve pixels between two
  adjacent frames, which is a visible pop mid-sign.
- **The girdle moves with the arms.** Each shoulder has its own lift: an arm
  leaving the side of the body pulls its side of the shoulder line up and rolls
  it outward a hair, and the torso outline is built from those two live points.
  Without it a raised arm reads as a stick pinned to a statue. The lift is
  small on purpose (0.012 of a unit) — more than that swallows the neck.
- **Nothing soft-tissue is a capsule.** Fingers, brows, the neck and the limb
  clip are all built by `_taperedPath`, which takes a polyline of joints and a
  half-width at each one and returns a filled outline that is square at the
  root and round at the tip. That is what lets a finger narrow toward the tip
  and a brow end in a point.
- **The sleeve is clipped to the arm, and starts past the joint.** It is
  painted inside the limb's own outline instead of drawn on top of it. Free, the
  same shape floats off the limb as a pad; clipped, it can only ever be cloth on
  an arm. The clip begins half an ink-width above the shoulder point so the
  sleeve covers the arm's rounded cap. The raglan seam strokes were deleted for
  the same reason the cap was covered: lines that end in the middle of the chest
  read as drawstrings. Clipping is necessary but not sufficient — see the
  retract rule above for why a clipped sleeve still read as a pad on a raised or
  folded arm.
- **A cropped standing figure.** The shirt now ends in a hem over a hip and
  thigh block that runs past the bottom of the card. A torso that stops in
  mid-air reads as a dress, whatever the arms do.
- **The hand is one silhouette, built with a real boolean union.** Palm and all
  five digits are combined into a single `ui.Path` with
  `ui.Path.combine(PathOperation.union, …)` and only that merged contour is
  inked and filled. Inked part by part — even "ink every part, then fill every
  part" — each finger still leaks a sliver of its own outline where a
  neighbour's fill does not quite reach, and on the card those slivers *are* the
  "gaps between the fingers" complaint. A merged contour has no interior edge to
  leak.
- **The fingers get their separation back as inked threads, not as daylight.**
  Once merged, an open hand reads as a mitten, so each pair of neighbouring
  fingers is drawn with a hairline in the outline colour at `_ink * 0.34` — about
  1.1 device pixels on the card, thin enough to read as a shadow between digits
  rather than as five separate sticks. Where the thread goes is computed, not
  guessed: walk the line between the two fingers' knuckles and tips and keep only
  the samples that lie inside *both* digit paths, because that is exactly where
  the two touch. One rule then drops a candidate seam: a run shorter than 0.7
  finger widths is not drawn (a fist only touches for a few thousandths of a
  unit, and that lands as a row of dashes on the back of the hand rather than as
  fingers). That cut sits in the gap between the two populations it has to
  separate — on a 284px card every pair of a hand open to curl 0.6 or less
  touches for 4.0–6.1px, and no pair of a hand closed past curl 0.7 reaches
  3.9px. It used to be 1.2 finger widths, which also cut the ring/pinky thread
  out of every open hand (5.0px against a 5.8px cut), and an earlier version
  gated on the authored curls as well (`|curl[i] - curl[i+1]| > 0.35`); measured
  across the library, that comparison rejects nothing the length cut keeps.
  `test/avatar/hand_seam_test.dart` pins the result by calling
  `AvatarPainter.fingerSeams`: three threads for an open hand, none for a fist,
  a point hand or a fanned letter, the threads a mixed hand actually earns, and
  the invariant that no thread lands on the palm for any of the 625 four-finger
  curl combinations.
- **Fingers touch, and the union only works if the digit paths are simple.**
  `_unitFingerGap` (0.0136) is under a finger's width (0.0170) and the tip taper
  is only 3%, so adjacent digits intersect instead of leaving daylight — the
  union needs contact, and a finger that narrows toward the tip stops touching
  its neighbour exactly where the eye looks for contact. `spread` is allowed to
  break that contact on purpose — the daylight between V, K and W is the letter —
  and the hand stays one contour because the palm still bridges every finger
  base. The gotcha that hid this
  for a whole debugging pass: `_taperedPath` closes its round tip with
  `arcTo(..., useCenter: false)`. With `useCenter: true` the cap is routed back
  through the centre of the tip circle, the contour self-intersects, and
  `Path.combine` silently refuses to merge it — every finger keeps its own navy
  outline and the gaps come straight back. Nothing throws; the picture just looks
  like the union was never attempted. The same helper derives its direction
  one-sided at the ends of a chain, because centring the sample on the first and
  last joint collapses the difference to zero and falls back to "pointing down",
  which carves a notch where the round cap should be.

## Legibility floor

The card renders at roughly 270 pixels, and the head is about 53 of them.
Anything smaller than ~8 pixels stops reading as anatomy and starts reading as
dirt, so the rig draws only what survives at that size. This is why the hair is
one mass with one edge line instead of strands, why an ear is not drawn at all,
why the neck has a jaw shadow but no muscle lines, and why the face is brows,
two eyes, a nose and two lips.

Two different floors apply, and mixing them up caused most of the rework:

- **Area detail** (pores, nails, creases, strands) disappears below ~8 pixels.
- **Silhouette ink** has to scale with the part. A finger is ~5 pixels wide, so
  it takes `_ink * 0.44` where the torso takes a full `_ink`; the head, at a
  third the torso's width, takes `_ink * 0.7`. At the body's weight the outline
  outweighs the part and the part collapses into a blob.

Check both against a recording of the running app, not the 2400-pixel golden. A
goldens-only review passed a version of this rig whose hands read as brush
fringes and whose hair read as a hood. Detail is cheap to add and expensive to
remove from a silhouette.

## Face

`_paintFace` draws four things: two tapered brows, two almond eyes, a nose, and
two lips. Each eye is an almond of two arcs holding one iris, one pupil and one
highlight, under a lash line; the nose is a soft underside oval and two wide-set
alae; the mouth is an upper lip with a cupid's bow over a fuller lower lip, with
teeth only once `mouth` opens past 0.10.

Three clearances matter more than any feature's shape, and all three were wrong
until checked against a recording of the running app:

- the brow sits `0.050 * hs` above the eye line, because at 0.034 the brow and
  the lash line merged into one dark blob per eye;
- the iris is smaller than the eye's height, so a band of white survives under
  it — an iris that fills the almond reads as a bruise, not an eye;
- the hair's inner edge stays outside the eye socket at every height.

Hair is one mass behind the skull, a fringe over the top of the face, and two
side bands that are thick at the temple and thin to a soft tip at the jaw. Held
at even width, those bands and the fringe close into a ring and the face becomes
an opening in a hood. There are no ears: at six device pixels an ear takes the
body's outline weight and reads as a dark ring stuck to the skull, and the hair
covers the gap. The head's own outline is `_ink * 0.7` for the same reason.

Everything in `_paintFace` is multiplied by `hs`, the current head radius over
the radius the offsets were authored against, so the face still fits the skull
when the head is resized. The whole pass is clipped to the head path, which is
why a feature can run past the jaw line without leaking.

## Feel: how a sign moves

A `SignAnimation` is keyframes plus a pass structure: `repeat` runs the keys
again through `_restarted`, and `pingpong` interleaves `_backwards` between
passes so the sign returns the way it came. The flattened waypoints become timed
`PoseSegment`s, and every segment is interpolated by `settle`:

```
0.45 * t²(3 − 2t) + 0.55 * (1 − (1 − t)³)
```

A smoothstep alone arrives at the target with zero velocity, so a repeated tap
reads as two identical holds; the blended cubic tail gives the hand a real
arrival without losing the ease-in.

Nothing moves on that curve as a whole. Each part gets its own window inside the
segment, which is what makes a limb lead and a hand finish:

| Part | Window | Why |
| --- | --- | --- |
| shoulder, elbow | 0.00 – 0.78 | the limb travels first |
| wrist, palm, lift | 0.10 – 1.00 | the forearm follows the upper arm |
| index / middle / ring / pinky | 0.02–0.70, 0.00–0.64, 0.10–0.82, 0.18–0.96 | staggered, so a hand opening does not snap |
| thumb | 0.14 – 1.00 | last, because it opposes the fingers |
| spread, thumbUp, thumbSpread | 0.06 – 0.90 | the fan settles after the curl |
| breath | 0.00 – 1.00 | no chain, it is not a gesture |

`travelMs: 0` is only a no-op on the very first key of a sign, where it records
that the hand starts in position. Anywhere else it asks for a snap, and no
authored sign uses one: the restart and reversal passes mean a zero travel can
never be carried into a pass where the hand is already elsewhere.

`SignTimeline` puts the signs end to end. The gap between two of them is scaled
by how far the posture has to change — the largest of |Δshoulder| and |Δelbow|
across both arms, times 1.4 ms per degree, clamped to 120–420 ms — so a caption
that jumps from a chest sign to a forehead sign breathes, and two neighbours in
the same zone stay tight. 120 ms is `SignLibrary.restGap`, the word break. A
340 ms lead and a 300 ms tail bring the body from rest and back to it, so an
empty caption leaves the rig at rest rather than frozen mid-gesture.

## The player: one caption, one pass

`VectorSignAvatar` runs the timeline forward once and stops with it. Position is
kept as `_playedMs`, accumulated from the ticker's frame deltas rather than
derived from the wall clock, for two reasons: a caption that grows while it is
being signed has to carry on from where the hands stopped instead of jumping past
the new word, and a run that has reached `totalMs` has to stay there.

`didUpdateWidget` compares sequences by gloss rather than by identity, because
the parent rebuilds the list every frame. When the new sequence merely extends
the old one the clock carries over; anything else restarts at zero. Either way
the position is then clamped to the new total, so shortening a caption cannot
leave the playhead in a timeline that no longer exists.

The same clock answers a second question. `SignTimeline.glossAt(ms)` returns the
gloss of the cue the playhead is inside — a gap between cues counts as the cue it
leaves from, and the entry ramp counts as the first cue, so the answer never
flickers to nothing mid-caption, and null once the hands have settled. The player
reports it through `onGlossChanged` only when it changes, and `SignAvatarView`
forwards that through the talk session stages to the blue chip. This is what
keeps word and movement the same moment: the chip names the sign the hands are
carrying rather than the whole accumulated gloss string, and a fingerspelled word
keeps its own name for the length of its spelling.

Reporting happens from the tick, never from `didUpdateWidget`. Notifying the
parent from inside its own build calls `setState` during build and throws.

## Feel: the idle layer

`IdleLayer.apply(pose, ms)` runs after the timeline and before the painter. It
adds breathing (chest and head lift a few thousandths of a unit), a blink about
every four seconds, a slow gaze drift, gaze that turns toward the signing hand,
and a resting smile. It is a pure function of elapsed milliseconds, so frames
stay reproducible.

Authored values always win: if a pose sets `headTurn`, `headTilt`, `smile` or a
non-zero `mouth`, the idle layer leaves it alone, because those carry grammar.
The player feeds it the ticker's own elapsed clock rather than the position in
the caption, so a short caption does not blink once per word and the avatar keeps
breathing after it has finished signing.

## Verifying

```bash
flutter test test/avatar/                       # library rules + goldens
flutter test test/avatar/rig_render_test.dart --update-goldens   # after pose edits
```

Goldens in `test/avatar/goldens/` are the only check that a joint chain still
reads as an arm; always look at the regenerated PNGs before committing them.

For motion, dump frames of a sign sequence with a throwaway test that renders
`AvatarPainter` into a `PictureRecorder` at 50 ms steps:

```dart
final recorder = ui.PictureRecorder();
final canvas = ui.Canvas(recorder);
AvatarPainter(pose: pose).paint(canvas, const ui.Size(360, 360));
final picture = recorder.endRecording();
// write picture.toImage(...).toByteData(png) to /tmp/av_frames/fNNNN.png
```

`dart:ui as ui` and use `ui.Size` / `ui.Canvas`: a plain `test(...)` file
does not get `Size` in scope without `flutter/material.dart`. Then assemble it
with a generated palette — this ffmpeg build has no `palette` filter, so it is
`palettegen` and `paletteuse` wired together in one pass:

```bash
ffmpeg -framerate 20 -i /tmp/av_frames/f%03d.png \
  -vf "scale=320:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" \
  -loop 0 build/avatar_preview.gif
```

Use a plain `test(...)` for the dump, not `testWidgets`: inside a widget test the
harness runs on a fake clock, and `PictureRecorder.endRecording().toImage(...)`
awaits a real engine frame that never arrives, so the test hangs to its timeout.

The stills can lie about a hand. A finger that reads fine frozen can cross its
neighbour the moment it moves, and only the loop shows it.

## Judging the result

Goldens are rendered at 2400x1800 and tell you almost nothing about the real
card. Downscale one to the size the widget actually gets and look at that:

```bash
python3 - <<'PY'
from PIL import Image
im = Image.open('test/avatar/goldens/rig_resting.png').convert('RGB')
card = im.crop((300, 0, 2100, 1800)).resize((284, 284), Image.LANCZOS)
card.resize((568, 568), Image.LANCZOS).save('/tmp/card.png')
PY
```

Better still, record the running app and pull frames from the recording — that is
how the brush-fringe hands, the hood hair and the donut ears were found after the
goldens had all "passed":

```bash
ffmpeg -y -i "Screen Recording.mov" -vf fps=2 /tmp/rec/r%03d.png
```

When a bug is "the thing that should be merged isn't merged", do not reason about
the geometry — paint the merged path in one flat bright colour and look at it. A
correct union is a single blob; anything still showing an interior line is a path
`Path.combine` silently declined to merge. That is how the self-intersecting tip
cap above was found, after two rounds of tuning finger spacings that were already
right.
