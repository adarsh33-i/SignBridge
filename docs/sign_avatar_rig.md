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
   nods, taps, circles, repetitions. Currently 66 ids: the everyday core set,
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

Two glosses used to fall through to letters and now carry their own motion. IX,
the ASL pointer that stands for "that one there", is solved to a place with
`armTo` — elbow out, forearm back down, index aimed away from the body — because
the arm is too long for the card to point straight sideways with a straight
elbow, and a lateral point would have to reach x 0.96. NOT keeps NO's snap and
changes only the hand to the curled N over the thumb: ASL writes negation twice
over, and spelling N-O-T made every negated sentence trail into letters.

Weather signs are authored as handshape plus one direction, held for two passes,
because a caption strings four or five of them together and a longer path stops
reading as a sign. That makes near-duplicates the failure mode: RAIN and SNOW
shared a handshape, CLOUD/STORM/WINDY shared a silhouette, and SUN/WEATHER/
LIGHTNING all raised one finger at the head. Each pair is now separated by the
handshape or by the zone it moves through.

`test/avatar/sign_library_test.dart` pins that no two of the 66 authored signs
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

  Getting *on* the face turned out to be the easy half. The same raise-and-fold
  that lands a palm on the lips parks the wrist at y 0.28 with a near-level
  palm, so the hand lies sideways across the face and its own height sweeps the
  eye band. Measured on a 237px render, EAT and CONSUME covered 34.7% of the
  eyes, WATER 36.8%, BLOW 37.4%, and the two signs whose hands start at the
  temples were far worse — HOME 66.5%, CLOUD 58.6%. The eyes are where question,
  negation and role-shift faces live, so that coverage deleted the grammar the
  same sign was carrying.

  The lower spots now come up under the jaw instead of over the brow: `mouth`
  146/148 and `cheek` 146/142, with each call site's `wrist` shifted about -8 to
  keep the hand's own rotation. The flat hand that used to lie across the face
  arrives at (0.618, 0.307) with its fingertips at the corner of the mouth, below
  the eye band, and EAT drops to 9.9%. HOME opens its elbow to 152 and touches
  the cheek beside the jaw (5.4%); CLOUD straightens both arms to 104 so the two
  hands drift past the hairline beside the head rather than in front of the brow
  (11.0%). `test/avatar/sign_library_test.dart` holds the line from here: it
  walks the head circle for every authored animation, keeps the frame that
  covers the most, and fails any sign over 30% of the eye band. SEE, VISION and
  SNOW are exempt because their handshape *is* a hand over the eyes, not because
  the rig cannot move them elsewhere.
- **Hand against hand.** A *mirrored pair of authored angles* can never meet:
  across every shoulder and elbow the rig reaches, the two wrists stop 0.21 of
  the card apart and a palm is 0.078, so 19 of the two-handed signs rendered as
  one symmetric shrug. The limit was in the authoring, not the body.
  `AvatarPainter.armTo` inverts `armOf` — a two-link solve in the rig's own
  angle convention, iterated because the shrug moves the shoulder joint the arm
  is measured from — so a hand is now placed at a point and the angles fall out
  of it. `_two` solves the non-dominant palm under the working hand, and `_both`
  takes a `meet` distance that slides a contact pair onto the centre line while
  keeping its authored height and palm direction. 20 of the 33 two-handed signs
  reach silhouette contact now. The 13 that do not are the weather pair, WANT,
  NEED and GO — two hands moving separately, which is correct — plus HUG and
  TODAY, which are open: HUG needs each hand to land on the *far* shoulder, and
  a centre-line meet cannot express a cross.

The face limit stands, including for a solved pair: a mirrored `_both` reaches
the temples at shoulder 134 with the fingertips still 0.14 apart, and past 142
the two hands overlap and cross the eyes, so a two-handed face sign has a window
about as wide as a hand. The hand-to-hand limit fell to a solve rather than a rig
change, so `ArmPose` still has one rotation plane plus a `lift` proxy; adding a
transverse adduction term is what would buy the crossed-arm signs, and it is a
rig change, not a sign change.

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
  under the head, which is where a hand at the cheek belongs. The shirt's bib
  and collar were the same bug one layer up: they were drawn at the end of
  `_paintHead`, which runs *after* the back arm, so the collar ate any forearm
  crossing the upper chest — which is every two-handed sign once its hands moved
  into the middle of the body. They are `_paintNeck` now, called between the
  torso and the back arm, because cloth is furniture and not foreground.
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

## Fitting signs from a video

The authored library covers a few hundred signs; the corpus of signer clips
covers thousands more. `test/tools/landmark_fitter.dart` turns one clip into one
`SignAnimation`, so a sign can be fitted from footage instead of invented.

It is a library, not a script, and it has to stay inside `test/` next to the rig
because every number it produces comes from the painter itself: `armOf` for where
a pose puts a wrist, `armTo` for the only arm that can reach an observed wrist,
`digitBones` for where that hand draws its knuckles. A fitter written in Python
would have to reimplement all three and would drift from the rig the moment the
rig moved.

```bash
# 1. clip landmarks -> JSON tracks in the corpus body frame
training/video/.venv/bin/python training/video/export_fit_tracks.py \
    --keys asl/hello asl/mother --out training/video/data/fit
# 2. JSON track -> keyframes, from a test that reads the file
LandmarkTrack.load('training/video/data/fit/asl__hello.json')
final animation = fitTrack(track)!.animation;
```

The clip frame is the one the audit already uses: origin at the shoulder
midpoint, one unit is a shoulder width. `toRig`/`fromRig` move between it and the
painter's 0..1 canvas.

**A 2D track has no elbow.** MediaPipe gives a wrist and finger tips, not the two
arm angles, so every limb is *solved* with `armTo` from the observed wrist — which
is also why the fit can be judged: reproject the solved pose and measure how far
the drawing lands from the landmarks it was fitted to. Every keyframe carries three
of those distances and they are the gate for accepting a fitted sign. Placement is
in rig units against a 0.336 shoulder, so it is comparable with the audit's
`POSITION_GAP`; shape is normalised by each hand's own palm length, so a big hand
is not penalised for being big; fold is the mean disagreement about the four PIP
angles in degrees, which is the same number the corpus audit charges an authored
handshape (`SHAPE_MATCH`, 30°) — one threshold for fitted and authored alike.

**One calibration cannot come out of a clip.** The rig's palm rotation axis is not
the wrist→middle-knuckle line the landmarks measure: a hand drawn at palm angle
`p` puts its middle knuckle at `p + side × 5.5°` (about 11.6° at half curl).
`palmOf` inverts that. Fitting without it left a 0.10–0.17 palm-length residual on
every handshape; with it, under 0.001. Applying it with the wrong sign doubles the
error, which is why `landmark_fit_test.dart` pins it directly.

Keyframes are cut where the moving hand stops and starts again — accumulated
against the segment's start, not against the previous frame, because a wave drifts
a few hundredths of a pixel per frame and totals a move. `_placeChange` is 0.012,
a thirtieth of a shoulder: at the obvious 0.05 a tap never exceeds the threshold
and EAT, NO and WATER each came out of the round trip as one static pose with no
movement at all. The hand that moves most drives that grid; the other is read
through the same windows, so both hands change on one clock. Frame count cannot
pick the driver — the support hand of a one-handed sign is tracked in every frame
and moves none of them.

**Mirroring is not something the fit can decide.** `fitTrack(track, reflect: true)`
reads the clip across the body centre line, which is what a selfie-view recording
needs. It used to try both readings and take the better by 10%, and that was always
a coin toss: the rig is exactly symmetric about the body line — `armTo` and
`digitBones` both mirror with `side` — so the two readings reproject to the same
three numbers to the twelfth decimal, on synthetic tracks and on real clips alike.
`landmark_fit_test.dart` pins that equality, so the day the rig grows an asymmetric
term that test is what says the mirror question has to be reopened. Chirality is an
argument the caller passes, not a result, and `FitResult.reflected` only records
what was asked for.

**A slot is not a hand until it is seen often enough.** MediaPipe reports the idle
hand for a frame or two whenever it half-enters frame, and a two-frame blob solved
through `armTo` still produces a plausible arm. The first five real clips put three
of those arms across the body, because a solved wrist with no evidence behind it is
only ever a guess. `fitWith` needs `minSlotFrames` (6, the audit's
`MIN_SHAPE_FRAMES`) before it believes a *second* hand, and a dropped one is named
in `FitResult.droppedSlots` and in the verdict's notes rather than silently missing.
The clip's longest slot is held to a lower bar — see the gate table below.

**Runs merge toward disagreement, not toward short.** Cutting makes one run per
gesture; `_maxKeys` (4) then forces merges. Merging the shortest run first — the
obvious rule — throws a wave's extremes away and keeps its middle, because the
extremes are the quick runs. The merge now pairs the two runs that agree most,
scored in multiples of the very thresholds that cut them (`_placeChange`,
`_shapeChangeDeg`, `_bearingChangeDeg`), and a run shorter than `_minSegmentFrames`
is folded into whichever of its two neighbours it agrees with first. On real clips
these two changes together — believing slots and merging on disagreement — cut
placement error 2-6x; merging chains element-wise had been averaging two different
hand positions into one keyframe.

The round trip is the standing check: `test/avatar/landmark_fit_test.dart` paints
a sign, exports its own landmarks back through `corpusPointsOf`, refits them, and
requires the same places and the same movement out. Twelve core signs come back
inside 0.005 rig units of placement error — 1.5% of a shoulder, about a pixel at
card size — and 0.02 palm lengths of shape, and the gate accepts every one of them.
If a sign the rig already draws correctly cannot come back out of the fitter,
nothing fitted from a real video can be trusted.

## Gating a fitted sign

A fit is not a suggestion. `FitVerdict` reads the same reprojection numbers the fit
was solved against and says, in as many sentences as it takes, whether the library
may take the sign:

| Gate | Value | Why there |
| --- | --- | --- |
| driver evidence | `minDriverFrames` = 4 | the clip's longest slot, see below |
| second-hand evidence | `minSlotFrames` = 6 | the audit's `MIN_SHAPE_FRAMES` |
| held evidence | `minKeyFrames` = 3 | a 1-2 frame key is a transition, not a citation form |
| placement | `maxPlacementError` = 0.024 | twice the cut threshold; ~6 px at card size |
| fold | `maxPipError` = 30° | the audit's `SHAPE_MATCH` for an authored handshape; named `fold ceiling` when the clip folds past `minDrawablePip` and no handshape could clear it |
| aim | `maxAimError` = 30° | the same `SHAPE_MATCH`, on where the finger points |
| roll | `rigMinAspect` × 0.90 | see below |

Only keyframes held for `minKeyFrames` or longer are graded; the summary getters on
`FitResult` read the same set (`citableKeys`), so the headline number and the
verdict under it cannot disagree. When nothing is held long enough, the verdict
says "no citation form" instead of grading a blur.

**Evidence is a ladder, not one number.** A second hand needs 6 frames, because one
flicker of the idle hand was enough to drag an arm across the body. But with one
clip per word the signing hand is sometimes all the clip has: in 6 of the pilot's 23
clips the longest slot ran 4 or 5 frames, and in 4 of those it was the clip's only
slot. Refusing those lost the word, not a bad take, so the clip's longest slot is
believed at `minDriverFrames` = 4 instead — 400 ms at the corpus's 10 fps, which is
how long a citation form is held for. The shortest second hands across those same
clips were 1 to 3 frames, and after the ladder only `asl/keep`, whose best slot ran
2 frames, gets no fit at all.

**Joint position is reported, never gated.** A fit used to be refused when its drawn
joints landed 0.20 palm lengths off the clip's. On real footage that number turned
out to be a sum of three things — where each finger aims, how far it folds, and how
long this signer's fingers are against the cartoon's fixed ones — and no action
could be taken on it. `asl/area` failed it with fingers folded 79.6° out and aiming
21° off; `isl/will` failed it while aiming 13.5° and folding 22.6°, which is a
handshape the avatar draws. Aim and fold are the two angular halves of the same
measurement and each one names its own fix, so those are the gates. `shapeError`
stays as a note above `shapeNoteFloor` = 0.20 palms on a clip that passes everything
else: our hand against this signer's, which the rig has no parameter to draw any
other way. `landmark_fit_test.dart` pins that with a clip whose every finger is 60%
longer than the rig's — it still has to be accepted, and still has to say so.

**Some footage this rig cannot represent at all.** A palm seen edge-on projects its
knuckle span onto almost nothing, and a 2D track has no depth channel to say by how
much. `rigMinAspect` reads the narrowest knuckle-span-per-palm the hand rig can
draw (0.58) from `digitBones`, and a clip below it is refused as *rolled, not
fitted* — cause named before the shape and fold errors it drags along, because the
fix for that is different footage, not a better fit. The export deliberately does
not filter these frames out: `export_fit_tracks.py` keeps them so the gate can say
what the clip was.

The other edge of shape space saturates quietly instead. The widest palm the rig can
draw spans 1.21 knuckle-to-palm, and the pilot measured real clips at 1.28-1.94
(`asl/area` 1.94, `isl/quickly` 1.78). Those are still hands a signer made, so they
are not refused; the fit draws the widest palm it can and the disagreement shows up
in `shapeError`, which is why that number is a report rather than a gate.

```bash
# per-clip, per-keyframe numbers and the gate that failed
FIT_REPORT_DIR=training/video/data/pilot \
    flutter test test/tools/fit_gate_report_test.dart
```

It prints every keyframe's own placement, shape, fold, aim and aspect, names the
slots it did not believe, and tallies which gate rejects. This is the instrument for
deciding whether a threshold sits in the right place rather than where the last clip
landed.

## The first pilot: 23 gap words

The 25 gap ids that carry the most tokens cover 21.9% of everything the library
cannot sign (2283 of 10425 gap tokens). One clip per (language, gloss) was exported
through `export_fit_tracks.py` and fitted: 23 of the 25 have usable footage.
`completely` has no clip in the cache at all, and `cannot` has two — the ASL take
gave MediaPipe 3 usable frames out of 9 and the ISL take's hand never entered
signing space — so it is the corpus that is short, not the fitter. To rebuild it:

```bash
training/video/.venv/bin/python training/video/export_fit_tracks.py \
    --keys asl/all asl/area asl/before asl/during asl/end asl/finish \
        asl/important asl/keep asl/leave asl/my asl/our asl/text asl/they \
        asl/train asl/travel asl/try asl/use asl/very asl/we asl/why \
        asl/your isl/quickly isl/will \
    --out training/video/data/pilot
```

3 of the 23 are accepted today: `asl/end`, `asl/very`, `isl/will`. The rejection
tally is what the pilot was for:

| Gate | Clips | What it says |
| --- | --- | --- |
| aim | 8 | 3 miss by under 3°; the other 5 aim 33.5-51.8° off |
| placement | 7 | 0.027-0.056 rig units — 6 to 13 px on a 237 px card |
| rolled palm | 7 | aspect 0.18-0.52, below anything `digitBones` can draw |
| fold | 6 | 5 of them fail a footage gate as well; only `isl/quickly` is refused for fold alone |
| fold ceiling | 3 | the clip folds past the tightest hand the rig owns |
| no fit | 1 | `asl/keep`: best slot 2 frames |
| no citation form | 1 | `asl/my`: 4 frames split into two 2-frame transitions |

A clip can fail more than one gate, so the column adds past 20.

**The rig's fist is shallow, and that is not what blocks the library.** The
tightest mean PIP `digitBones` can draw is 92.7°, read off the renderer by
`minDrawablePip` rather than typed in, so a clip holding below 62.7° cannot
clear the 30° fold gate whichever handshape the search picks. `FitVerdict` calls
that `fold ceiling` instead of `fold`, which is how the pilot found out how much of
the fold tally is the renderer: 3 clips of 9, and only `asl/area` — a real fist at
13.5° mean PIP — is refused by nothing else. `docs/avatar_corpus_audit.md` was right
that every closed rig hand reads shallower than a corpus fist, but on this footage it
is a minority cause. Aim and placement are what the pilot actually trips over.

**Which is why the gates are not the last word.** Seven placement rejections sit at
6-13 px on the card the app actually draws, and three aim rejections miss by less
than 3°; a threshold that refuses those may simply be measuring the difference
between a video and a cartoon rather than the difference between one sign and another.
The next instrument is a render, not a number: paint each rejected fit at card size
beside the clip's own landmarks and look at it, because what matters is whether the
avatar's hand reads as the signer's. Nothing here should be loosened to make the pass
rate look better — that is exactly the "threshold where the last clip landed" mistake
the report exists to catch.

What the fit cannot represent, for now:

- `lift` is a proxy from wrist height. A 2D track has no out-of-plane shoulder
  rotation, so an arm that reaches toward the camera and one that reaches sideways
  look the same to the fitter.
- Two hands on the same side of the body become one arm — the rig has one arm per
  side. The shape error reports the disagreement rather than hiding it.
- Four keyframes is the binding limit, not the merge rule: a long continuous travel
  (HELLO's wrist across a second of space) is cut into more than `_maxKeys` runs and
  whatever survives merging carries the average.
- `_placeChange` was tuned on clean synthetic tracks. Held keyframes on the pilot's
  23 real clips reproject 0.003-0.074 rig units, so the cut is the right order and
  7 clips still cross the placement gate. The report gives the size of that failure,
  not its cause; the two candidates are a hand travelling inside one keyframe window
  and a wrist the arm cannot reach, because `armTo` keeps the direction and takes up
  the slack when a target is out of span (`avatar_painter.dart:243`).
- Clips in the corpus are short: the pilot's slots run 1-22 usable frames, which is
  why the evidence ladder exists, and why one clip per word is thin. `asl/keep` has
  no fit at all. Most gap words will need more than one clip each before the gate
  can be trusted to say anything about them.

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
