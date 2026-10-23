# Avatar rig audit against the ASL landmark corpus

Date: 2026-10-23

Scope: handshape, placement, motion, timing, off-hand participation, and
hand-to-face contact for the 60 signs authored in
`lib/services/avatar/rig/sign_library.dart`.

Out of scope: scoring facial expression against the corpus. The corpus has no
face or head landmarks, so no face score exists to compute. The faces were
checked by rendering at card size instead; see [Face and hand-to-face](#face-and-hand-to-face).

## Data

- 11,298 tracked clips: 4,447 ASL and 6,851 ISL.
- One hand-landmark track per clip: 21 landmarks x (x, y) at 10 fps in
  shoulder-width units, plus a pose-present flag.
- The audit reads only ASL clips whose id matches an authored sign: 55 of 60.
  Five authored signs have no matching track (BAD, FOG, ME, NEED, STORM) and
  are reported as unmeasured, not as passing.
- The anchor is the middle MCP (landmark 9), which is stable under finger curl
  and wrist rotation. Corpus to rig canvas: `x_rig = 0.5 + 0.336 x_c`,
  `y_rig = 0.405 + 0.336 y_c`.

The retained sample is 390 usable active-side frames across the 55 measured
signs. Median shape support is 1.00 across the 31 signs whose clip produced a
supported shape cluster.

## Evidence ladder

Each hand of each clip passes through four gates before it can produce a
finding:

| Stage | Requirement | Frames rejected |
| --- | --- | --- |
| present | MediaPipe hand detection | no hand in frame |
| pose | clip pose-present flag | detection on a non-signing frame |
| gated | palm 0.12 to 0.50 shoulder widths; wrist y at most 0.85 | off-body or collapsed palm |
| usable | palm aspect at least 0.40 | palm seen edge-on, finger angles are noise |

Shape findings require at least 6 usable frames (`MIN_SHAPE_FRAMES`). Below
that the side is `low_sample` and cannot produce a shape finding.

Placement, motion, and face findings require at least 8 usable frames
(`MIN_STATIC_FRAMES`). The 20% end trim only applies from 8 frames, so below it
the clip's fade-in and fade-out stay in the envelope and the median anchor is a
transition rather than the citation form. Eight signs sit between the shape
minimum and this line, at 6 or 7 usable frames, and are listed under
[Limited samples](#limited-samples): HELLO, HOME, HOT, KNOW, LOVE, MOTHER,
WATCH, WIND. Sides below 6 usable frames are `low_sample` and produce no shape
finding either.

A phrase in the corpus is not a licence to invent evidence. A gate that a clip
fails is reported, and a low sample never becomes a shape finding.

## Shape

- A finger counts as extended when its PIP angle is at least 145 degrees. The
  rig counts a finger as folded when its curl is at most 0.2.
- Families by extended count: open (4), partial (1 to 3), fist (0).
- A cluster is at least 3 frames within 30 degrees mean PIP, holding at least
  15% of the hand's usable frames.
- An authored hand supports a cluster when the mean PIP error over the four
  fingers is at most 30 degrees, against any key and either hand.
- A failure with the same extended count is `fold_depth` (medium). A failure
  with a different count is `count_conflict` (high).

The rig's total finger fold is capped at 112 degrees, and the PIP joint takes
72% of it. Corpus fists sit at 5 to 50 degrees PIP. Every closed rig hand
therefore reads shallower than a corpus fist, by a bounded amount. That is a
renderer limit, not a per-sign authoring error; see [Limitations](#limitations).

## Placement

The placement metric is the larger of the two directed median nearest-neighbour
distances between the corpus middle-MCP path and the rig middle-MCP path:
corpus to rig and rig to corpus. The median is used so one stray landmark
cannot set the distance.

Handedness is decided once per sign from the medians, not per frame. The
corpus has left and right slots, but the label does not always agree with the
signer's dominant hand; when the medians fall on opposite sides of the centre
the corpus path is reflected.

Threshold: `POSITION_GAP = 0.12` rig units, where the shoulder width is 0.336.
A gap over 0.12 means the authored hand is a palm length or more from where the
clip holds it.

## Motion

Motion size is the mean distance from the path's own centroid (radius of
gyration), on the trimmed corpus path and on the rig key envelope.

Two rules decided this metric:

- The median distance used in the first pass is not comparable across sample
  counts. With a three-key rig envelope the median is one of three distances,
  so a key that arcs out and returns still reads as a 0.02 move. The mean is
  unbiased at any count.
- The corpus path is trimmed by 20% at each end, so its entry and release are
  not counted as signing motion.

A motion finding requires corpus spread of at least 0.06, which excludes
near-static clips from judging a sign, and a rig/corpus ratio outside
0.30 to 2.00.

The rig envelope is the authored citation keys only. It has no approach from
rest, so rig motion is a lower bound.

## Timing

`timing_ratio` is the sign's total duration over the corpus span of gated
frames, `(last - first + 1) / 10` seconds. A finding needs a span of at least
0.4 s and at least 8 timing frames, with a ratio outside 0.40 to 2.20.

This is the least trustworthy metric. A clip that starts from rest or holds at
the end inflates the corpus span and makes the rig look too fast. A clip that
is cut tight makes the rig look too slow.

## Face contact

The corpus has no head landmarks. Contact is judged against the rig's own head
circle, `headUnitPath` at (0.5, 0.245) with radius 0.099.

- Contact is expected when the corpus fingertip reaches within 0.02 of that
  circle's surface on at least 2 usable frames (`MIN_FACE_CONTACT_FRAMES`) of a
  side with static support, so at least 8 usable frames.
- A single grazing frame is indistinguishable from landmark noise and does not
  create an expectation.
- The contact is missed when the rig's closest fingertip stays more than 0.06
  outside the surface.

This metric is approximate in both directions. It can miss a real contact when
the clip's head is not where the rig's head is, and it can expect contact when
a moving hand merely passes the inferred circle.

## Off hand

These flags describe evidence availability, not defects:

- `offhand_missing`: the rig is one-handed but the corpus engages both hands on
  at least 35% of at least 4 frames. This is the only off-hand flag that is
  evidence against the rig.
- `offhand_unobserved`: the rig is two-handed but the corpus never shows both
  hands together on 6 frames.
- `offhand_undetected`: the rig is two-handed but the corpus detected the second
  hand on fewer than 6 frames.

## Results

Audit version 3, run on the current rig export.

| Flag | Count | Meaning |
| --- | --- | --- |
| handshape_unmatched | 10 | 11 clusters: 8 fold depth, 3 count conflict |
| placement_gap | 12 | candidate placement defects, 2 shown to be corpus artifacts |
| motion_amplitude | 5 | rig anchor moves far less than the clip |
| timing | 9 | tempo ratio outside 0.40 to 2.20 |
| face_contact_missed | 2 | supported corpus contact the rig does not make |
| offhand_missing | 3 | corpus uses a second hand the rig does not |
| offhand_unobserved | 2 | evidence gap |
| offhand_undetected | 8 | evidence gap |

The first pass over the corpus, before the fixes below, flagged 16 handshape
mismatches, 17 placement gaps, and 6 face-contact misses. The 13 sign fixes and
the version 3 evidence rules reduced those to 10, 12, and 2.

## Applied fixes

Every row was checked against the clip frames as well as the metrics. The
"after" column is from the final version 3 run.

| Sign | Change | After |
| --- | --- | --- |
| ENJOY | Replaced the eight-hand with two flat palms, three rubbing keys | shape delta 3.0 deg, gap 0.044, motion 0.55, no flags |
| NO | Opens on the U hand, closes to a fist | family and extended count match; fold depth 43.9 and 56.3 remain |
| GO | One H hand became two mirrored index hands at chest height | shape delta 21.0, gaps 0.086 and 0.108, no flags |
| KNOW | Pointing hand became a flat B hand at the temple | delta 5.8, gap 0.068, face contact made; timing 0.29 only |
| HUG | Relaxed off hand became a fist in the crossed pair | gap 0.063; fold depth 58.1 remains |
| SHOWER | Claw above the crown, open flat hand on the drop | 1 usable frame, no statistical finding |
| WATCH | O hand became the hooked X hand that taps | fold depth 51.2; corpus detects the off hand on fewer than 6 frames |
| HOW | Bent hands became relaxed hands, placement narrowed | 4 usable frames, no statistical finding |
| WIND | One hand at the mouth became two mirrored flat hands | 6 usable frames, no flags; gap 0.125 and motion 0.29 miss their thresholds but are not findings below the 8-frame gate |
| WINDY | Two mirrored five-hands flutter chest to cheeks | delta 7.6, motion 0.43; placement and timing remain |
| CLOUD | C-hands became fanned five-hands at the head sides | delta 9.1, gap 0.039, motion 1.04, no flags |
| THUNDER | Two index hands at the temples, brow furrowed | delta 14.2; placement flag remains |
| SUN | Mid-arc pointing hand became an open five | delta 20.7, gap 0.049, motion 0.50, no flags |

Seven of the 13 now carry no flags; two of those, SHOWER and HOW, have too few
usable frames to produce one. Six still carry flags. NO and HUG keep the
structural fold depth; WATCH keeps fold depth plus an evidence gap; THUNDER
keeps a placement flag that the clip contradicts; WINDY keeps a slot-labelled
placement flag and a timing flag from a 5.1 s clip. KNOW keeps only a timing
flag.

## Open findings

### Shape

- Fold depth, 7 signs: ASSIST 66.3 deg, HUG 58.1, LOVE 68.0, NO 43.9/56.3,
  SORRY 73.5, WATCH 51.2, YOU 41.9. The extended count matches; the rig cannot
  fold as deep as the clip. This is the renderer cap described above.
- Count conflict, 3 signs: NAME 35.6 (corpus 4 extended, rig 2), TODAY 114.9
  (corpus 1, rig 4), YES 33.8 (corpus 1, rig 0). These need frame review. A
  loose open hand can measure as one extended finger when the PIPs sit near the
  145 degree line, so the count is not proof on its own. TODAY's clip shows two
  loose open hands, which does not look like the one-finger cluster.

### Placement

- Candidate defects: BUY 0.288, DOCTOR 0.213, FINANCE 0.122, HELP 0.147,
  MENTION 0.177, PLEASE 0.220, RAIN 0.213, SORRY 0.216, TODAY 0.224,
  YOU 0.239.
- THUNDER 0.144: the corpus anchor sits above the crown; the clip shows the
  index hands at the temples, which is where the rig puts them. Corpus outlier.
- WINDY 0.194: the active corpus slot has its anchor at x 0.169, left of the
  body centre, while the other slot gives 0.094 at the same shape match. This
  is a slot-labelling artifact; the rig's pair is symmetric.

### Motion

BUY 0.09, FINANCE 0.00, MENTION 0.06, RAIN 0.00, YOU 0.21.

RAIN is a metric blind spot: the rig moves fingers and wrists in place, and the
audit only sees the middle knuckle. The other four have a near-static rig
anchor while the clip hand travels, and need an authoring pass.

### Timing

CONSUME 2.41, DOCTOR 0.37, EAT 0.39, FATHER 0.25, FINANCE 0.31, HOME 0.31,
KNOW 0.29, WATER 0.31, WINDY 0.20.

The low ratios cluster around clips that include rest or a long hold. DOCTOR
has 22 usable frames and a low ratio, so it is the strongest candidate for a
real tempo issue. EAT (0.39) and KNOW (0.29) are the largest compressions
outside the band: their clips span 2.2 s and 1.4 s while the rig runs 0.86 s
and 0.40 s, on 22 usable frames for EAT and 13 gated frames for KNOW. Both
clips hold the sign, so the short rig may be correct. Low severity; no change
was made.

### Face contact

ASSIST (clip contact 7 frames, rig stops 0.102 outside) and YOU (2 frames, rig
0.074 outside). Both signs also have shape findings, so a face-only edit would
not fix them. No change was made.

### Off hand

- Missing, 3 signs: BLOW, VISION, WEATHER. The clip uses a second hand the rig
  leaves at rest.
- Evidence gaps, 10 signs: BUY and SNOW (unobserved) and FRIEND, GOOD, HOME,
  NEGATIVE, SCHOOL, TEMPERATURE, WATCH, WORK (undetected). These do not show
  the rig is wrong.

### Limited samples

HELLO, HOME, HOT, KNOW, LOVE, MOTHER, WATCH, WIND have fewer than 8 usable
frames on the active side, so placement, motion, and face contact were not
judged for them. Their shape findings are still reported.

## Face and hand-to-face

What the corpus can measure here is one thing only: whether a fingertip comes
within reach of an inferred head circle. It says nothing about brow, mouth,
eye openness, or timing of a non-manual marker, so no face expression was
scored against the corpus.

The face was checked by rendering the animation strips at the real card size,
284 px:

- KNOW: the flat hand sits on the brow while both eyes and the mouth stay
  readable. The face never disappears behind the palm.
- THUNDER: the two index fingers sit at the temples with the elbows out, and
  the furrowed brow is visible between them.
- CLOUD: the fanned hands frame the face at the cheeks and do not cross the
  eyes; the two hands stay a palm apart.
- SHOWER: the claw clears the crown with margin at the top of the card, then
  opens and drops to the side of the head without covering the face.
- SUN: the open five arcs outside the head between the two O keys.
- WINDY: the high key brings the fanned hands to the cheeks without crossing
  the face; the low key returns to the chest.
- WIND, GO, HOW, HUG, WATCH, ENJOY: two-handed poses stay clear of the face;
  the eyes and mouth remain visible in every rendered frame.

Goldens updated and inspected at 284 px: `face_know`, `sign_how`,
`weather_cloud`, `weather_thunder`, `weather_wind`, `weather_windy`. The other
changed signs have no golden entry, so their frames were checked from the
temporary 8-frame strips only.

## Limitations

1. The corpus has no head or face landmarks. Face contact is an inferred
   geometry check, not an observation.
2. Corpus handedness slots can disagree with the signer. The audit picks the
   side with the most engaged frames and reflects it once; WINDY shows the
   failure mode.
3. Clips include approach and release. Timing is affected most; placement and
   motion are affected below 8 usable frames, which is why those findings are
   gated.
4. A rig envelope has two or three keys. Motion is a citation-form lower bound,
   and the radius of gyration is coarse at that scale.
5. The rig caps total finger fold at 112 degrees. All closed-hand signs will
   read shallower than the clips until the hand model changes.
6. Clip variants differ. TODAY, YES, and NAME may be signed differently in the
   corpus than in the rig, which a count conflict cannot distinguish from an
   error.
7. Five authored signs have no matching clip and are unmeasured.

## Reproduction

```sh
RIG_AUDIT_OUT=build/audit flutter test test/tools/rig_audit_export_test.dart
python3 training/video/audit_avatar_rig.py
```

Artifacts:

- `build/audit/avatar_rig.json`: rig export, 1,305,381 bytes. Every number
  comes from the painter (`armOf`, `digitBones`, `handUnitPath`,
  `headUnitPath`), not re-derived.
- `build/audit/avatar_corpus_audit.json`: audit output, version 3, thresholds
  included.
- `training/video/audit_avatar_rig.py`: the audit.
- `test/tools/rig_audit_export_test.dart`: the exporter.

The audit is deterministic. It reads fixed `.npz` tracks and the exported rig
JSON and uses no randomness.

## Verification

- `test/avatar/sign_library_test.dart`: 101 tests, including a new `corpus
  audit` group that pins the corrected shapes, the mirrored wrists, the
  two-handed participation, and the updated face-reach map.
- `test/avatar/rig_render_test.dart`: goldens regenerated and inspected at
  284 px.
- Full Flutter suite: 521 tests passed after the golden and library test updates.
