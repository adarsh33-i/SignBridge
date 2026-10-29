/// Fit rig parameters to a signer's landmark track.
///
/// Input is one clip from `training/video/data/fit/` (see `export_fit_tracks.py`):
/// the 21 MediaPipe hand points per hand per frame, in the corpus body frame —
/// origin at the shoulder midpoint, unit one shoulder width. That is the frame
/// `audit_avatar_rig.py::to_rig` already maps into the rig canvas, so a fitted
/// sign and an audited sign are measured against one convention.
///
/// The corpus has no elbow. A video of a signing hand says where the wrist went,
/// not how the arm got there, so every limb here is *solved* with
/// [AvatarPainter.armTo] from the observed wrist, and the fit is judged by
/// reprojection: run the solved pose back through `armOf` and `digitBones` and
/// measure how far its knuckles and fingertips land from the clip's.
///
/// Two numbers come out per key, and they mean different things. Placement error
/// is in rig units, where a shoulder is 0.336, and is comparable with the audit's
/// `POSITION_GAP`. Shape error is normalised by each hand's own palm, because the
/// rig draws one fixed hand size and a clip does not: comparing tip positions
/// absolutely would charge the fit for the signer standing closer to the camera.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sign_bridge/services/avatar/rig/avatar_painter.dart';
import 'package:sign_bridge/services/avatar/rig/sign_animation.dart';
import 'package:sign_bridge/services/avatar/rig/sign_pose.dart';

/// The rig's own shoulder line, copied from `AvatarPainter`'s unit constants.
const double _shoulderWidth = 0.336;
const double _shoulderMidY = 0.405;

/// MediaPipe's knuckle and tip indices, in the same triples the audit uses:
/// (MCP, PIP, TIP), so the angle is measured at the same joint on both sides.
const List<List<int>> _fingerPoints = [
  [5, 6, 8],
  [9, 10, 12],
  [13, 14, 16],
  [17, 18, 20],
];
const int _wristPoint = 0, _thumbTipPoint = 4;

/// A hand leaves the body frame only when its wrist hangs below this, in
/// shoulder widths — the audit's `ENGAGED_Y`, kept here so both tools drop the
/// same frames.
const double _hangingWristY = 0.85;

/// Change-point thresholds for keyframing. A segment holds one handshape at one
/// place; the citation form is the sequence of segments.
///
/// These are the gap between *noise* and *motion*, measured in the units each
/// quantity is compared in: rig units for the wrist (a shoulder is 0.336), degrees
/// for a fold or an aim. A wrist threshold of 0.05 — which is a seventh of a
/// shoulder width — sits above the whole travel of a tap, so EAT, NO and WATER
/// came out of the round trip as one static pose and lost their movement. 0.012
/// is a thirtieth of a shoulder width: still above frame-to-frame landmark
/// jitter, but small enough that a real hold and a real move separate. Tuned
/// against clean synthetic tracks; the first run on real clips has to re-check it,
/// because MediaPipe jitter is what could over-segment here.
const double _shapeChangeDeg = 20.0;
const double _placeChange = 0.012;
const double _bearingChangeDeg = 25.0;

/// A run of one frame is a flicker on the way between two poses, not a pose the
/// avatar should hold; [fitWith] merges each one into the neighbour it agrees with.
const int _minSegmentFrames = 2;
const int _maxKeys = 4;

/// The gates a fitted sign has to clear before the library may take it.
///
/// A fit is not trustworthy because it was computed — it is trustworthy because
/// drawing it back lands on the landmarks it was fitted to. These are the numbers
/// that decide, and they are the corpus audit's own where the audit already has a
/// word for the same thing, so an authored sign and a fitted one are judged by one
/// standard.
///
/// A slot has to be seen this many times to be believed as a *second* hand. This
/// is the audit's `MIN_SHAPE_FRAMES`: below it a detection is a flicker, and one
/// flicker frame of a non-signing hand was enough to drag HELLO, MOTHER and WATER's
/// arms across the body in the first run on real clips. The clip's longest slot is
/// held to the lower [minDriverFrames] instead.
const int minSlotFrames = 6;

/// Frames enough for the *longest* slot in a clip to be the signing hand.
///
/// One clip per word means the signing hand is sometimes all the clip has: in 6
/// of the pilot's 23 clips the longest slot ran 4 or 5 frames, and in 4 of those
/// it was the clip's only slot. Refusing them lost the word, not a bad take, and
/// 4 frames at the corpus's 10 fps is the 400 ms a citation form is held for.
/// The floor stays above what this ladder exists to refuse — the shortest second
/// hands across the same 23 clips were 1 to 3 frames — and after it only
/// `asl/keep`, whose best slot ran 2 frames, gets no fit at all.
const int minDriverFrames = 4;

/// How far a keyframe may reproject its own wrist, in rig units (a shoulder is
/// 0.336).
///
/// The audit's `POSITION_GAP` of 0.12 asks a much weaker question — whether an
/// authored sign is *anywhere near* the observed path — and a fit that only clears
/// that has put the hand up to a third of a shoulder away from where the clip
/// showed it. 0.024 is two of the fit's own movement cuts: the hand lands back
/// inside the distance at which the fitter itself would call two frames the same
/// place, and at the 237 px card that is about six pixels.
const double maxPlacementError = 0.024;

/// Mean PIP-angle disagreement allowed, in degrees — the audit's `SHAPE_MATCH`,
/// the same statistic on the same four joints, so a fitted handshape is supported
/// by exactly the evidence an authored one has to be.
///
/// The audit applies this to authored hands and knows it is generous there: the rig
/// cannot close past [minDrawablePip], and `docs/avatar_corpus_audit.md` records
/// corpus fists at 5-50 degrees. [FitVerdict] therefore separates a fold failure the
/// fit caused from one the renderer caused, and calls the second one
/// `fold ceiling`.
const double maxPipError = 30.0;

/// How far a drawn finger may aim away from the clip's, in degrees, measured from
/// the wrist to the fingertip with each signer's own finger length divided out.
///
/// This is the gate the first 23-clip pilot asked for. Those clips landed 0.33 to
/// 0.90 palm lengths off in joint *position* — the number that used to reject them
/// — and a fingertip that far off is its aim times its radius plus its fold plus
/// the length of a finger the rig does not have, so the position figure could not
/// say which of four things was wrong. `asl/area` failed it with fingers folded
/// 79.6° out and aiming 21° off; `isl/will` failed it while aiming 13.5° and
/// folding 22.6°, which is a handshape the avatar draws. Aim and fold are the two
/// angular halves of that same measurement, and each one names its own fix.
///
/// 30° is the audit's `SHAPE_MATCH` again, for the same reason: at the card's ten
/// pixel finger it is five pixels of tip, which is how much disagreement a sign
/// already in the library is allowed.
const double maxAimError = 30.0;

/// Above this palm-normalised joint disagreement the fit says so in a note.
///
/// Reported, never gated: it is the sum of aim, fold and the difference between a
/// cartoon hand's fixed finger lengths and this signer's, and the pilot showed no
/// way to read a number back out of it. A clip that passes every gate and still
/// lands here is a hand we draw a bit differently, which the note now says out
/// loud instead of calling a rejection.
const double shapeNoteFloor = 0.20;

/// A keyframe held for fewer clip frames than this is a transition, not a pose:
/// the audit trims approach and release from the path before it measures anything.
const int minKeyFrames = 3;

/// The rig's rest wrist height and its highest useful reach, both in rig units.
/// [fitLift] maps a wrist between them onto the rig's `lift`, which is the only
/// out-of-plane term the rig has: a 2D track cannot report a shoulder rotation,
/// so how high the hand sits is the best available proxy for how raised the arm
/// is. It is a proxy and the reprojection error is what shows when it is wrong.
const double _restWristY = 0.687, _topWristY = 0.25;

/// One hand, one frame: its ordinal on the clip clock and 21 points in corpus
/// units. The ordinal is kept because a slot only carries the frames where that
/// hand was visible, so the two hands cannot be lined up by list position.
class TrackFrame {
  const TrackFrame({required this.ordinal, required this.points});
  final int ordinal;
  final List<Offset> points;
}

/// One clip slot: the frames where that hand was detected and in signing space.
class TrackHand {
  const TrackHand({required this.slot, required this.frames});
  final String slot;
  final List<TrackFrame> frames;

  /// A hand whose median wrist hangs below the shoulder line is not signing.
  ///
  /// `export_fit_tracks.py` already drops those frames, so this only catches a
  /// track built some other way — the round-trip test being the one that exists.
  bool get hanging => frames.isEmpty ||
      _median([for (final f in frames) f.points[_wristPoint].dy]) >
          _hangingWristY;
}

/// A corpus clip: two slots plus the clock the frames were sampled on.
class LandmarkTrack {
  const LandmarkTrack({
    required this.key,
    required this.frameMs,
    required this.hands,
  });

  final String key;
  final double frameMs;
  final List<TrackHand> hands;

  static LandmarkTrack load(String path) {
    final json = jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
    final frameMs = (json['frameMs'] as num).toDouble();
    final hands = <TrackHand>[];
    (json['hands'] as Map<String, Object?>).forEach((slot, raw) {
      // jsonDecode gives dynamic-nested lists, so every level is read as
      // List<Object?> / Map<String, Object?> and the numbers converted with `as
      // num` rather than a cast the decoder's types will not satisfy.
      final frames = (raw as List<Object?>).map((entry) {
        final frame = entry as Map<String, Object?>;
        return TrackFrame(
          ordinal: (frame['f'] as num).toInt(),
          points: [
            for (final p in (frame['p'] as List<Object?>))
              Offset(
                ((p as List<Object?>)[0] as num).toDouble(),
                (p[1] as num).toDouble(),
              ),
          ],
        );
      }).toList();
      hands.add(TrackHand(slot: slot, frames: frames));
    });
    return LandmarkTrack(
      key: json['key'] as String,
      frameMs: frameMs,
      hands: hands,
    );
  }
}

/// One frame's hand, already in rig units, with the measurements the fit needs.
class HandGeometry {
  const HandGeometry({
    required this.ordinal,
    required this.wrist,
    required this.bases,
    required this.tips,
    required this.thumbTip,
    required this.pip,
    required this.palm,
    required this.aspect,
    required this.thumbReach,
    required this.bearing,
  });

  /// The frame's ordinal on the clip clock, so a keyframe can be timed and the
  /// two hands can be read in the same window.
  final int ordinal;
  final Offset wrist;
  final List<Offset> bases;
  final List<Offset> tips;
  final Offset thumbTip;

  /// Four PIP angles in degrees, 180 = straight.
  final List<double> pip;
  final double palm;

  /// Across the knuckles over palm length: 1 for a frontal palm, low edge-on.
  final double aspect;

  /// Thumb tip from the wrist over palm length.
  final double thumbReach;

  /// Wrist → middle knuckle, in the rig's degrees-from-straight-down.
  final double bearing;
}

/// A fitted keyframe and what the fit cost.
class FitKey {
  const FitKey({
    required this.pose,
    required this.startMs,
    required this.holdMs,
    required this.frames,
    required this.placementError,
    required this.shapeError,
    required this.pipError,
    required this.aimError,
    required this.aspect,
    required this.observedPip,
  });

  final SignPose pose;
  final double startMs, holdMs;

  /// Clip frames this keyframe was fitted to, across both hands. Fewer than
  /// [minKeyFrames] and the key is a detection blip, not a held pose.
  final int frames;

  /// Rig units, where a shoulder is 0.336.
  final double placementError;

  /// Palm lengths, so it does not depend on how big the signer's hand looked.
  final double shapeError;

  /// Mean PIP-angle disagreement, in degrees.
  final double pipError;

  /// Mean angle between each drawn finger's aim and the clip's, in degrees, with
  /// each signer's own finger lengths divided out.
  final double aimError;

  /// The clip's knuckle span over palm length for this keyframe's own frames.
  ///
  /// Kept because it says *why* a shape error happened: below [rigMinAspect] the
  /// hand was rolled away from the camera, and no handshape in the rig can draw
  /// that. It is a fact about the footage, not a result of the fit.
  final double aspect;

  /// The clip's own mean PIP over its four fingers, in degrees, for these frames.
  ///
  /// The other half of the fold gate's cause: [pipError] says how far the drawn hand
  /// sits from the clip's, and this says whether *any* hand the rig owns could sit
  /// closer. Below `minDrawablePip - maxPipError` the clip folds past the ceiling on
  /// the renderer and the verdict names that instead of a disagreement.
  final double observedPip;
}

/// The whole fit for one clip.
class FitResult {
  const FitResult({
    required this.key,
    required this.reflected,
    required this.keys,
    required this.droppedSlots,
  });

  final String key;

  /// Whether the corpus was read mirrored across the body centre line.
  ///
  /// This is a property of the footage, not something the fit can decide: the rig
  /// is exactly symmetric about the body line — `armTo` and `digitBones` both
  /// mirror with `side` — so the two readings cost the same to the last decimal,
  /// measured on synthetic and on real clips alike. No reprojection error can pick
  /// a chirality. `false` is the default because the rig draws the signer as the
  /// viewer sees them and `toRig` already puts the image's left on the canvas's
  /// left; `true` is for a clip recorded in selfie view.
  final bool reflected;
  final List<FitKey> keys;

  /// Slots that were not believed as hands, and why they were dropped. A
  /// two-frame flicker of the non-signing hand is not a second arm, and leaving it
  /// in moved three of the first five real clips' arms across the body.
  final List<String> droppedSlots;

  /// Keyframes held long enough to be a pose the avatar will actually hold.
  ///
  /// A two-frame key is a transition between two shapes: it stays in [keys] for
  /// timing, but the gate and these summaries both read only this set, so a
  /// headline number can never disagree with the verdict printed under it.
  List<FitKey> get citableKeys => [
    for (final k in keys)
      if (k.frames >= minKeyFrames) k,
  ];

  /// The keys the reported errors are measured over. When nothing is held long
  /// enough to grade, that is every key rather than an empty set that would
  /// median to a flattering zero — [FitVerdict] rejects that fit anyway.
  List<FitKey> get _graded => citableKeys.isEmpty ? keys : citableKeys;

  double get placementError => _median([
    for (final k in _graded) k.placementError,
  ]);
  double get shapeError => _median([for (final k in _graded) k.shapeError]);
  double get pipError => _median([for (final k in _graded) k.pipError]);
  double get aimError => _median([for (final k in _graded) k.aimError]);

  /// Whether the library may take this sign, and what stopped it if not.
  FitVerdict get verdict => FitVerdict(this);

  SignAnimation get animation => SignAnimation(
    id: 'fit_${key.split('/').last}',
    gloss: key.split('/').last.toUpperCase(),
    keys: [
      for (final k in keys)
        PoseKey(pose: k.pose, travelMs: 220, holdMs: k.holdMs.round()),
    ],
  );
}

/// The gate decision for one fit: [accepted] only when every check passed, with
/// every failure named rather than the first one only.
///
/// A rejected fit is not a lost sign — the reasons say whether the clip was too
/// short, the hand too edge-on, or the fit wrong, and those need different fixes.
class FitVerdict {
  FitVerdict(FitResult fit) {
    for (final (gate, detail) in _failures(fit)) {
      gates.add(gate);
      reasons.add(detail);
    }
    if (fit.droppedSlots.isNotEmpty) {
      notes.add(
        'dropped ${fit.droppedSlots.join(", ")}: fewer than $minSlotFrames frames '
        'and not the clip\'s longest slot, so not believed as a second hand',
      );
    }
    final blips = [
      for (final k in fit.keys)
        if (k.frames < minKeyFrames) k,
    ];
    if (blips.isNotEmpty) {
      notes.add(
        '${blips.length} keyframe(s) hold fewer than $minKeyFrames frames and were '
        'left out of the gate: transitions, not citation forms',
      );
    }
    // Only worth saying about a fit that passed: a rejected clip already has its
    // reason, and this number cannot tell a proportion gap from a bad pose.
    if (reasons.isEmpty && fit.shapeError > shapeNoteFloor) {
      notes.add(
        'accepted with the drawn joints ${fit.shapeError.toStringAsFixed(2)} palm '
        'lengths off the clip\'s: aim and fold are inside their gates, so this is '
        'the rig\'s fixed finger length against this signer\'s, which the avatar '
        'has no parameter to draw any other way',
      );
    }
  }

  final List<String> reasons = [];

  /// Which gate each [reasons] entry came from, without its measurement. Two
  /// clips can fail the placement gate at different amounts, and a pilot run has
  /// to count that as one gate being the problem, not two unrelated ones.
  final List<String> gates = [];

  /// Things that did not block the fit but are worth reading next to it.
  final List<String> notes = [];

  bool get accepted => reasons.isEmpty;

  static List<(String, String)> _failures(FitResult fit) {
    if (fit.keys.isEmpty) return [('no fit', 'no keyframes fitted')];
    // The gate reads the held keyframes only: a two-frame transition key can
    // reproject badly and it is not a pose the avatar will hold.
    final held = fit.citableKeys;
    if (held.isEmpty) {
      return [(
        'no citation form',
        'every keyframe holds fewer than $minKeyFrames clip frames: '
            '${fit.keys.length} transitions and no citation form',
      )];
    }
    final placement = _median([for (final k in held) k.placementError]);
    final pip = _median([for (final k in held) k.pipError]);
    final aim = _median([for (final k in held) k.aimError]);
    final aspect = _median([for (final k in held) k.aspect]);
    final observedPip = _median([for (final k in held) k.observedPip]);
    // A clip held tighter than the rig's ceiling fails the fold gate whatever the
    // search picks, and that is a different finding from a bad handshape: one needs
    // a renderer, the other needs a better fit. Counting them together would hide
    // how much of the pilot is the rig.
    final pastFoldCeiling = observedPip + maxPipError < minDrawablePip;
    return [
      if (placement > maxPlacementError)
        (
          'placement',
          'wrist reprojects ${placement.toStringAsFixed(4)} rig units, over the '
              '$maxPlacementError gate — the hand lands '
              '${(placement / _shoulderWidth).toStringAsFixed(2)} shoulder widths from '
              'where the clip showed it',
        ),
      // Cause before symptom: a rolled hand makes the aim and fold gates fail for
      // a reason the fit cannot fix, and saying so points at the footage.
      if (aspect < rigMinAspect * _aspectTolerance)
        (
          'rolled palm',
          'palm is rolled, not fitted: knuckles span ${aspect.toStringAsFixed(2)} of '
              'a palm against the narrowest the rig can draw, '
              '${rigMinAspect.toStringAsFixed(2)} — a 2D track cannot recover the roll and '
              'the rig has no term for it',
        ),
      if (pip > maxPipError)
        pastFoldCeiling
            ? (
              'fold ceiling',
              'fingers fold past what this rig can draw: the clip holds '
                  '${observedPip.toStringAsFixed(1)} degrees mean PIP and the tightest '
                  'hand `digitBones` makes is '
                  '${minDrawablePip.toStringAsFixed(1)}, so the ${pip.toStringAsFixed(1)} '
                  'degrees of disagreement is a ceiling on the renderer — no handshape '
                  'in the library could clear the $maxPipError gate on this clip',
            )
            : (
              'fold',
              'fingers disagree by ${pip.toStringAsFixed(1)} degrees mean PIP, over the '
                  '$maxPipError the audit gives an authored handshape',
            ),
      if (aim > maxAimError)
        (
          'aim',
          'fingers aim ${(aim - maxAimError).toStringAsFixed(1)} degrees past the '
              '$maxAimError gate (mean ${aim.toStringAsFixed(1)} from the wrist to '
              'the fingertip): the hand is in the right place and folded about '
              'right, but its fingers point somewhere the clip never pointed them',
        ),
    ];
  }
}

/// Map a corpus point into the rig canvas, optionally mirrored about the body.
Offset toRig(Offset p, {bool reflect = false}) {
  final x = 0.5 + p.dx * _shoulderWidth;
  return Offset(
    reflect ? 1 - x : x,
    _shoulderMidY + p.dy * _shoulderWidth,
  );
}

/// [toRig] backwards. Only used by the round-trip test, which has to hand the
/// fitter points in corpus units — the rig's own chains are drawn in unit space.
Offset fromRig(Offset p, {bool reflect = false}) => Offset(
  ((reflect ? 1 - p.dx : p.dx) - 0.5) / _shoulderWidth,
  (p.dy - _shoulderMidY) / _shoulderWidth,
);

/// The 21 corpus points of one rig-drawn hand, with the eight joints the fitter
/// reads filled in and the rest parked on the wrist.
///
/// [rigChains] drawn through [fromRig], so a synthetic track is exactly the
/// geometry the painter draws — nothing between the two sides of the round trip
/// is a guess about what MediaPipe would have reported.
List<Offset> corpusPointsOf(SignPose pose, double side) {
  final chains = rigChains(pose, side);
  final joints = AvatarPainter.armOf(pose, side);
  final points = List<Offset>.filled(21, fromRig(joints.wrist));
  for (var f = 0; f < 4; f++) {
    for (var j = 0; j < 3; j++) {
      points[_fingerPoints[f][j]] = fromRig(chains[f][j]);
    }
  }
  points[_thumbTipPoint] = fromRig(chains[4][2]);
  return points;
}

/// The rig-side geometry of one corpus frame.
HandGeometry geometryOf(TrackFrame frame, {bool reflect = false}) {
  Offset at(int i) => toRig(frame.points[i], reflect: reflect);
  final wrist = at(_wristPoint);
  final bases = [for (final f in _fingerPoints) at(f[0])];
  final tips = [for (final f in _fingerPoints) at(f[2])];
  final palm = (bases[1] - wrist).distance;
  return HandGeometry(
    ordinal: frame.ordinal,
    wrist: wrist,
    bases: bases,
    tips: tips,
    thumbTip: at(_thumbTipPoint),
    pip: _pipOf([
      for (final f in _fingerPoints) [at(f[0]), at(f[1]), at(f[2])],
    ]),
    palm: palm,
    aspect: (bases[0] - bases[3]).distance / math.max(palm, 1e-6),
    thumbReach: (at(_thumbTipPoint) - wrist).distance / math.max(palm, 1e-6),
    bearing: _bearing(wrist, bases[1]),
  );
}

/// Angle at the middle of each (base, knuckle, tip) chain, in degrees.
///
/// One definition used on both sides of the comparison — the corpus landmarks
/// and the rig's own [AvatarPainter.digitBones] chains — so a shape error is a
/// disagreement about the finger, not about where the protractor was put.
List<double> _pipOf(List<List<Offset>> chains) => [
  for (final chain in chains)
    _angleBetween(chain[0] - chain[1], chain[2] - chain[1]),
];

double _angleBetween(Offset a, Offset b) {
  final cosine =
      (a.dx * b.dx + a.dy * b.dy) /
      math.max(a.distance * b.distance, 1e-9);
  return math.acos(cosine.clamp(-1.0, 1.0)) * 180 / math.pi;
}

/// The rig's screen bearing of a direction: degrees from straight down, positive
/// swinging toward the viewer's right. This is `AvatarPainter._dir`'s own
/// convention, so a solved palm angle needs no conversion.
double _bearing(Offset from, Offset to) {
  final d = to - from;
  return math.atan2(d.dx, d.dy) * 180 / math.pi;
}

double _median(List<double> xs) {
  if (xs.isEmpty) return 0;
  final sorted = [...xs]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

double _maxAbs(List<double> xs) {
  var best = 0.0;
  for (final x in xs) {
    if (x > best) best = x;
  }
  return best;
}

/// How much a hand moves over the clip, in multiples of the change thresholds.
///
/// Wrist travel alone cannot pick the driver: EAT, NO and WATER sign at one fixed
/// point, so the hand doing the signing travels less than a support hand at rest
/// and would lose the vote. Shape and aim count as much as place, which is how
/// [_boundaries] judges a change in the first place.
double _motion(List<HandGeometry> gs) {
  var d = 0.0;
  for (var i = 1; i < gs.length; i++) {
    final a = gs[i - 1], b = gs[i];
    d +=
        (b.wrist - a.wrist).distance / _placeChange +
        (b.bearing - a.bearing).abs() / _bearingChangeDeg +
        _maxAbs([
          for (var f = 0; f < 4; f++) (b.pip[f] - a.pip[f]).abs(),
        ]) /
            _shapeChangeDeg;
  }
  return d;
}

/// The rig's own finger chains for one arm, in unit space — the same transform
/// `_paintHand` applies: rotate the hand-local bones by the palm angle, then
/// translate to the wrist.
List<List<Offset>> rigChains(SignPose pose, double side) {
  final arm = side < 0 ? pose.left : pose.right;
  final joints = AvatarPainter.armOf(pose, side);
  return chainsOf(arm.hand, joints.wrist, joints.palmAngle, side);
}

/// [rigChains] for a hand at an explicit place and aim, without an arm to solve.
List<List<Offset>> chainsOf(
  HandShape hand,
  Offset wrist,
  double palmAngle,
  double side,
) {
  final rotation = -degrees(palmAngle);
  final c = math.cos(rotation), s = math.sin(rotation);
  return [
    for (final chain in AvatarPainter.digitBones(hand, side))
      [
        for (final p in chain)
          Offset(
            wrist.dx + p.dx * c - p.dy * s,
            wrist.dy + p.dx * s + p.dy * c,
          ),
      ],
  ];
}

/// The curl steps the shape tables are sampled at. Twenty is finer than the rig
/// can show at card size and still cheap enough to rebuild per fit.
final List<double> _steps = [for (var i = 0; i <= 20; i++) i / 20];

HandShape _curlOnly(int finger, double curl) => HandShape(
  index: finger == 0 ? curl : 0,
  middle: finger == 1 ? curl : 0,
  ring: finger == 2 ? curl : 0,
  pinky: finger == 3 ? curl : 0,
);

/// The rig's PIP angle per finger at each curl step, other fingers extended.
///
/// Built from the painter, never from a guess about what curl 0.6 looks like:
/// the fold is capped at 112° so the mapping from a clip's 0-180° range onto the
/// rig's is a curve, and this is that curve.
final List<List<double>> _curlToPip = [
  for (var f = 0; f < 4; f++)
    _pipOf([
      for (final curl in _steps)
        AvatarPainter.digitBones(_curlOnly(f, curl), 1)[f],
    ]),
];

double _nearestStep(List<double> table, double target) {
  var best = 0.0, bestGap = double.infinity;
  for (var i = 0; i < _steps.length; i++) {
    final gap = (table[i] - target).abs();
    if (gap < bestGap) {
      bestGap = gap;
      best = _steps[i];
    }
  }
  return best;
}

double _rigAspect(HandShape hand) {
  final chains = AvatarPainter.digitBones(hand, 1);
  final palm = (chains[1][0] - Offset.zero).distance;
  return (chains[0][0] - chains[3][0]).distance / math.max(palm, 1e-6);
}

double _rigThumbReach(HandShape hand) {
  final chains = AvatarPainter.digitBones(hand, 1);
  final palm = (chains[1][0] - Offset.zero).distance;
  return (chains[4][2] - Offset.zero).distance / math.max(palm, 1e-6);
}

/// The palm-normalised disagreement between a drawn hand and an observed one.
///
/// Each of the nine joints a 2D track reports is measured from its own wrist and
/// divided by its own palm length, so this is the hand as a *shape* and nothing
/// else: where it sits and how big the signer's hand was belong to the arm solve
/// and to [FitKey.placementError], not here. Charging a fit for the distance
/// between the camera and the signer would penalise the correct shape.
///
/// It is still the sum of three different things — where each finger aims, how
/// much it folds, and how long the signer's are — and it cannot say which of them
/// moved. [FitVerdict] reports this and gates on [_aimGap] and [maxPipError],
/// which can.
double _jointGap(
  List<List<Offset>> chains,
  Offset rigWrist,
  double rigPalm,
  HandGeometry g,
) {
  final observedPalm = math.max(g.palm, 1e-6);
  var cost = 0.0;
  for (var f = 0; f < 4; f++) {
    cost +=
        ((chains[f][0] - rigWrist) / rigPalm -
                (g.bases[f] - g.wrist) / observedPalm)
            .distance;
    cost +=
        ((chains[f][2] - rigWrist) / rigPalm -
                (g.tips[f] - g.wrist) / observedPalm)
            .distance;
  }
  cost +=
      ((chains[4][2] - rigWrist) / rigPalm -
              (g.thumbTip - g.wrist) / observedPalm)
          .distance;
  return cost / 9;
}

/// The rig's palm rotation for a clip's observed wrist → middle-knuckle line.
///
/// They are not the same angle. The middle knuckle does not sit on the axis the
/// hand is rotated about: it is offset to one side, and the offset grows as the
/// fingers curl (measured off `digitBones`: 5.5° for a flat hand, 11.6° at curl
/// 0.5). Reading the aim straight off the knuckle therefore tilts every fitted
/// hand by that much — at a fingertip's radius that is a fifth of a palm, which
/// was most of the shape error the round trip first reported. The offset comes
/// from the shape the fit chose, because that is the hand being drawn, and it
/// flips sign with the side because the mirrored hand's knuckle offset does.
double palmOf(HandShape hand, double side, double bearing) =>
    bearing - side * _axisOf(hand);

double _axisOf(HandShape hand) {
  final knuckle = AvatarPainter.digitBones(hand, 1)[1][0];
  return math.atan2(knuckle.dx, knuckle.dy) * 180 / math.pi;
}

/// How far one candidate handshape is from what the clip showed, at the clip's
/// own wrist and aim. This is the number [fitShape] minimises.
double shapeCost(HandShape hand, HandGeometry g, double side) {
  final chains = chainsOf(hand, g.wrist, palmOf(hand, side, g.bearing), side);
  return _jointGap(
    chains,
    g.wrist,
    math.max((chains[1][0] - g.wrist).distance, 1e-6),
    g,
  );
}

/// The fields the shape descent moves, each with how to read and write it.
///
/// `thumbSpread` rides on `thumb` — an out thumb is an abducted thumb — because
/// the clip cannot separate the two: a 2D track sees where the tip landed, not
/// which joint put it there. `thumbUp` is its own field because the rig uses it
/// to pull the thumb swing back for the A and 5 hands, which moves the tip
/// without changing `thumb` at all.
final List<(double Function(HandShape), HandShape Function(HandShape, double))>
_fields = [
  (_readIndex, (h, v) => h.copyWith(index: v)),
  (_readMiddle, (h, v) => h.copyWith(middle: v)),
  (_readRing, (h, v) => h.copyWith(ring: v)),
  (_readPinky, (h, v) => h.copyWith(pinky: v)),
  (_readSpread, (h, v) => h.copyWith(spread: v)),
  (_readThumb, (h, v) => h.copyWith(thumb: v, thumbSpread: 0.35 * v)),
  (_readThumbUp, (h, v) => h.copyWith(thumbUp: v)),
];

double _readIndex(HandShape h) => h.index;
double _readMiddle(HandShape h) => h.middle;
double _readRing(HandShape h) => h.ring;
double _readPinky(HandShape h) => h.pinky;
double _readSpread(HandShape h) => h.spread;
double _readThumb(HandShape h) => h.thumb;
double _readThumbUp(HandShape h) => h.thumbUp;

/// The closest handshape the rig can draw to what the clip shows.
///
/// A first guess inverts each of the four curls on its own from [_curlToPip],
/// then spread and thumb against the hand those curls produced: cheap, and it
/// lands the big features. Then a coordinate descent polishes it, because the
/// rig's digits are not independent — the contact solve shortens a chain that
/// reaches into a neighbour, curling one finger drags its neighbours' knuckles
/// round, and `thumbUp` moves the thumb tip without touching `thumb`. The guess
/// alone leaves that coupling unexplained; the descent removes it. Every
/// candidate is scored by [shapeCost], which is the same measurement the fit
/// reports, so a keyframe carries the shape its own error will be judged on.
HandShape fitShape(HandGeometry g, double side) {
  final curls = [
    for (var f = 0; f < 4; f++) _nearestStep(_curlToPip[f], g.pip[f]),
  ];
  HandShape guess(double spread, double thumb) => HandShape(
    index: curls[0],
    middle: curls[1],
    ring: curls[2],
    pinky: curls[3],
    thumb: thumb,
    thumbSpread: 0.35 * thumb,
    spread: spread,
  );
  final spread = _nearestStep([
    for (final s in _steps) _rigAspect(guess(s, 0.5)),
  ], g.aspect);
  var best = guess(
    spread,
    _nearestStep([
      for (final t in _steps) _rigThumbReach(guess(spread, t)),
    ], g.thumbReach),
  );
  var bestCost = shapeCost(best, g, side);
  // Every move is a whole grid step and strictly improves the cost, so the walk
  // cannot cycle; in practice it settles in one or two passes.
  for (var pass = 0; pass < 8; pass++) {
    var moved = false;
    for (final (read, write) in _fields) {
      final current = read(best);
      for (final delta in [-1.0, 1.0]) {
        final value = (current + delta / 20).clamp(0.0, 1.0);
        if (value == current) continue;
        final candidate = write(best, value);
        final cost = shapeCost(candidate, g, side);
        if (cost < bestCost - 1e-9) {
          best = candidate;
          bestCost = cost;
          moved = true;
        }
      }
    }
    if (!moved) break;
  }
  return best;
}

/// The rig's `lift` for a wrist at this height. See [_restWristY].
double fitLift(Offset wrist) =>
    ((_restWristY - wrist.dy) / (_restWristY - _topWristY)).clamp(0.0, 1.0);

/// Solve one hand's arm and hand for one measured frame.
ArmPose solveArm(HandGeometry g, double side) {
  final hand = fitShape(g, side);
  return AvatarPainter.armTo(
    side: side,
    target: g.wrist,
    armLift: fitLift(g.wrist),
    palm: palmOf(hand, side, g.bearing),
    hand: hand,
  );
}

/// Which side of the body this hand is drawn on, from where its wrist landed.
double sideOf(HandGeometry g) => g.wrist.dx < 0.5 ? -1 : 1;

/// Median geometry of a run of frames: the shape and place the run holds.
HandGeometry _medianGeometry(List<HandGeometry> run) {
  Offset medianOffset(List<Offset> xs) => Offset(
    _median([for (final p in xs) p.dx]),
    _median([for (final p in xs) p.dy]),
  );
  final wrist = medianOffset([for (final g in run) g.wrist]);
  final bases = [
    for (var f = 0; f < 4; f++) medianOffset([for (final g in run) g.bases[f]]),
  ];
  return HandGeometry(
    ordinal: (run.first.ordinal + run.last.ordinal) ~/ 2,
    wrist: wrist,
    bases: bases,
    tips: [
      for (var f = 0; f < 4; f++) medianOffset([for (final g in run) g.tips[f]]),
    ],
    thumbTip: medianOffset([for (final g in run) g.thumbTip]),
    pip: [
      for (var f = 0; f < 4; f++) _median([for (final g in run) g.pip[f]]),
    ],
    palm: _median([for (final g in run) g.palm]),
    aspect: _median([for (final g in run) g.aspect]),
    thumbReach: _median([for (final g in run) g.thumbReach]),
    bearing: _median([for (final g in run) g.bearing]),
  );
}

/// How much two runs disagree, measured in multiples of the thresholds that cut
/// them apart in the first place: 1.0 means they sit exactly one cut's width away
/// from each other, and anything under it is a segment the boundary only made
/// because the hand drifted through it.
double _disagreement(List<HandGeometry> a, List<HandGeometry> b) {
  final x = _medianGeometry(a), y = _medianGeometry(b);
  return (y.wrist - x.wrist).distance / _placeChange +
      _maxAbs([
        for (var f = 0; f < 4; f++) (y.pip[f] - x.pip[f]).abs(),
      ]) /
          _shapeChangeDeg +
      (y.bearing - x.bearing).abs() / _bearingChangeDeg;
}

/// Where the hand changes shape, place or aim — the keyframe boundaries.
///
/// Measured against the frame the current segment *started* from, not the
/// previous one. A wave is a run of small steps and each step on its own is under
/// any threshold, so a frame-to-frame test merges the whole wave into one pose and
/// the sign loses its movement; compared with the segment's own reference, the
/// drift accumulates until the hand has actually gone somewhere, and that is where
/// a keyframe belongs.
///
/// Cut on one hand's own frames: a second hand that changes between two boundaries
/// of the first gets averaged, and the reprojection error is what reports that
/// rather than a guess made here.
List<int> _boundaries(List<HandGeometry> gs) {
  final cuts = <int>[0];
  var reference = gs.first;
  for (var i = 1; i < gs.length; i++) {
    final g = gs[i];
    final shape = _maxAbs([
      for (var f = 0; f < 4; f++) (g.pip[f] - reference.pip[f]).abs(),
    ]);
    final moved = (g.wrist - reference.wrist).distance;
    final turned = (g.bearing - reference.bearing).abs();
    if (shape > _shapeChangeDeg ||
        moved > _placeChange ||
        turned > _bearingChangeDeg) {
      cuts.add(i);
      reference = g;
    }
  }
  cuts.add(gs.length);
  return cuts;
}

/// Fit one clip.
///
/// [reflect] reads the body across the centre line. It is a caller's decision
/// about the footage, not something this function can search for: the rig is
/// exactly symmetric about the body line, so both readings cost the same and a fit
/// would be guessing. Use `true` for a clip recorded in selfie view; the default
/// matches the rig, which draws the signer as the viewer sees them.
FitResult? fitTrack(LandmarkTrack track, {bool reflect = false}) =>
    fitWith(track, reflect);

/// The fit for one clip read in one chirality: both slots, the moving hand's
/// keyframe grid, and the reprojection error of what comes out.
///
/// Exposed for the pilot report, which has to show both readings side by side.
@visibleForTesting
FitResult? fitWith(LandmarkTrack track, bool reflect) {
  final hands = <String, List<HandGeometry>>{};
  final dropped = <String>[];
  // The longest slot in the clip is the signing hand wherever the rest of the clip
  // lost it, so it gets the lower floor. Every arm-hijack this gate exists to stop
  // was 1 to 3 frames in the pilot's 23 clips, while 6 of those clips' longest
  // slot ran 4 or 5 — the same ladder, but it has to keep the sign as well as
  // refuse the flicker.
  final longest = track.hands
      .where((hand) => !hand.hanging)
      .map((hand) => hand.frames.length)
      .fold(0, math.max);
  for (final hand in track.hands) {
    // The evidence ladder, same as the audit's: a hand has to be seen often
    // enough to be a hand. One or two frames of the idle hand are a flicker, and
    // in the first run on real clips a flicker was enough to pull HELLO, MOTHER
    // and WATER's arms to the wrong side of the body — the rig has one arm per
    // side, so an extra hand anywhere joins the arm already there.
    if (hand.hanging) {
      dropped.add('${hand.slot} (hanging)');
      continue;
    }
    final gs = [
      for (final frame in hand.frames) geometryOf(frame, reflect: reflect),
    ];
    final isDriver = gs.length == longest && gs.length >= minDriverFrames;
    if (gs.length < minSlotFrames && !isDriver) {
      dropped.add('${hand.slot} (${gs.length} frames)');
      continue;
    }
    hands[hand.slot] = gs;
  }
  if (hands.isEmpty) return null;
  // The hand that moves most drives the keyframe grid; the other one is read
  // through the same windows rather than getting a grid of its own, so both hands
  // change on the same clock. Frame count cannot pick it — the support hand of a
  // one-handed sign is tracked in every frame and moves none of them.
  final driver = hands.values.reduce(
    (a, b) => _motion(a) >= _motion(b) ? a : b,
  );
  final cuts = _boundaries(driver);
  final runs = <List<HandGeometry>>[];
  for (var c = 0; c + 1 < cuts.length; c++) {
    final run = driver.sublist(cuts[c], cuts[c + 1]);
    if (run.isEmpty) continue;
    runs.add(List.of(run));
  }
  // Merge down to the keyframe budget, and merge away any single-frame run, one
  // least-disagreeing neighbour at a time.
  //
  // Both steps use the same measure because they are the same decision: which two
  // segments are least of a loss to join. Measuring in multiples of the thresholds
  // that cut them apart keeps the budget from choosing for itself — shortest-run
  // merging throws away a quick move to the extreme of a wave and keeps its middle,
  // which is the opposite of what a keyframe timeline is for.
  //
  // A short run joins the neighbour it *agrees* with, left or right, and that is
  // the whole difference from merging it into whatever came before. HELLO's clip
  // cuts into one real hold and five single frames along the hand's travel down
  // from the temple; chained into the previous run they made a six-frame keyframe
  // whose median wrist is a place the hand was never at, and the fit scored 0.14 —
  // four times the gate — on a clip whose every frame solves exactly.
  while (runs.length > 1) {
    final short = runs.indexWhere(
      (run) => run.length < _minSegmentFrames,
    );
    if (runs.length <= _maxKeys && short < 0) break;
    if (short < 0) {
      var merge = 0, smallest = double.infinity;
      for (var i = 0; i + 1 < runs.length; i++) {
        final d = _disagreement(runs[i], runs[i + 1]);
        if (d < smallest) {
          smallest = d;
          merge = i;
        }
      }
      runs[merge].addAll(runs[merge + 1]);
      runs.removeAt(merge + 1);
      continue;
    }
    final intoLeft = short > 0
        ? _disagreement(runs[short - 1], runs[short])
        : double.infinity;
    final intoRight = short + 1 < runs.length
        ? _disagreement(runs[short], runs[short + 1])
        : double.infinity;
    if (intoRight < intoLeft) {
      runs[short].addAll(runs[short + 1]);
      runs.removeAt(short + 1);
    } else {
      runs[short - 1].addAll(runs[short]);
      runs.removeAt(short);
    }
  }
  final keys = <FitKey>[];
  for (final run in runs) {
    final start = run.first.ordinal * track.frameMs;
    final hold = (run.last.ordinal - run.first.ordinal + 1) * track.frameMs;
    final pose = _poseFor(hands, run);
    final observed = _window(hands, run);
    var placement = 0.0, shape = 0.0, pip = 0.0, aim = 0.0;
    for (final g in observed) {
      final error = _reproject(pose, sideOf(g), g);
      placement += error.$1;
      shape += error.$2;
      pip += error.$3;
      aim += error.$4;
    }
    keys.add(
      FitKey(
        pose: pose,
        startMs: start,
        holdMs: hold,
        frames: observed.length,
        placementError: placement / observed.length,
        shapeError: shape / observed.length,
        pipError: pip / observed.length,
        aimError: aim / observed.length,
        aspect: _median([for (final g in observed) g.aspect]),
        observedPip: _median([for (final g in observed) _mean(g.pip)]),
      ),
    );
  }
  if (keys.isEmpty) return null;
  return FitResult(
    key: track.key,
    reflected: reflect,
    keys: keys,
    droppedSlots: dropped,
  );
}

/// Every hand's geometry inside the run's clock window.
///
/// The driver supplies the boundaries, but both slots are scored: a support hand
/// that the fit put in the wrong place has its own frames in this window, so its
/// error shows up here instead of hiding behind the driver's numbers.
List<HandGeometry> _window(
  Map<String, List<HandGeometry>> hands,
  List<HandGeometry> run,
) {
  final first = run.first.ordinal, last = run.last.ordinal;
  return [
    for (final gs in hands.values)
      for (final g in gs)
        if (g.ordinal >= first && g.ordinal <= last) g,
  ];
}

/// The pose one keyframe draws.
///
/// One arm per side of the body, which is all the rig has: the observed hands
/// are grouped by the side their wrist landed on and each group is solved to its
/// median geometry. Two hands on the same side therefore merge into one — the
/// shape error is what reports that, not a guess made here. A hand with no frames
/// in the window is absent, so that arm rests.
SignPose _poseFor(
  Map<String, List<HandGeometry>> hands,
  List<HandGeometry> run,
) {
  final observed = _window(hands, run);
  ArmPose armFor(double side) {
    final gs = observed.where((g) => sideOf(g) == side).toList();
    if (gs.isEmpty) return ArmPose.resting;
    final g = _medianGeometry(gs);
    return solveArm(g, side);
  }

  return SignPose(
    name: 'fit',
    left: armFor(-1),
    right: armFor(1),
    face: FacePose.neutral,
  );
}

/// The narrowest palm the rig can draw, in the clip's own aspect units.
///
/// The rig has one hand size and draws the knuckles wherever `digitBones` puts
/// them: fingers together, the span across the index and pinky knuckles is 0.58 of
/// a palm and that is the floor — curling the fingers does not narrow it, because
/// the knuckles do not move. A clip measured below it therefore shows a hand rolled
/// about the wrist-to-fingers axis, foreshortened by projection, and MediaPipe has
/// no depth channel to tell us by how much. This is the one gate that is not about
/// fit quality at all: the footage cannot be fitted by this rig, and saying so is
/// more useful than reporting a shape error with no cause.
///
/// Read off `digitBones` rather than typed in, so the number moves if the hand rig
/// moves.
double get rigMinAspect {
  final chains = AvatarPainter.digitBones(HandShape.flat, 1);
  return (chains[0][0] - chains[3][0]).distance /
      (chains[1][0] - Offset.zero).distance;
}

/// How far a drawn hand may be from the narrowest the rig can go before the clip
/// is called rolled rather than merely tight. Landmark jitter moves the knuckles by
/// about a tenth of a palm on a still hand.
const double _aspectTolerance = 0.90;

/// The tightest mean PIP the rig is able to draw, in degrees.
///
/// A fold stops turning at `_maxFold` and the PIP takes 72% of what is left, so
/// past that the curl is spent shortening the drawn segment instead of closing the
/// finger — the thing that stopped a fist drawing a hairpin. Read off `digitBones`
/// at full curl, so it moves with the renderer, exactly like [rigMinAspect].
///
/// This is a ceiling on the footage, not on the fit: a clip held tighter than
/// `minDrawablePip - maxPipError` cannot clear the fold gate whichever handshape the
/// search picks, and [FitVerdict] says which of the two it is looking at rather than
/// reporting a disagreement that no library hand could have avoided.
double get minDrawablePip {
  final chains = AvatarPainter.digitBones(
    HandShape(index: 1, middle: 1, ring: 1, pinky: 1, thumb: 1),
    1,
  );
  return _mean([
    for (final chain in chains.take(4))
      _angleBetween(chain[0] - chain[1], chain[2] - chain[1]),
  ]);
}

/// Mean of [xs]; [_median] is the robust one, but these are per-frame statistics of
/// one hand, where the average of four fingers is what the audit compares.
double _mean(List<double> xs) =>
    xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;

/// How far the drawn hand lands from the observed one: (placement, shape, fold,
/// aim).
///
/// Placement is the wrist in rig units — where the hand is. Shape is [_jointGap]
/// of the rig's own chains for the *solved* arm, so it charges the fit for the arm
/// as well as the hand: a solved pose whose palm ends up aiming somewhere the clip
/// never pointed it has to carry that in its shape error.
///
/// The third number is the mean disagreement about the four PIP angles, in
/// degrees. [_jointGap] answers "is the hand drawn the same size and shape as the
/// one in the clip"; this answers the same question the corpus audit asks of an
/// authored handshape, through the joint a video measures directly rather than
/// through a projected position, so a fitted sign and an audited sign are judged
/// for fold by one number and one threshold.
///
/// The fourth is [_aimGap]: the same question about where each finger points, with
/// the signer's finger lengths divided out.
(double, double, double, double) _reproject(
  SignPose pose,
  double side,
  HandGeometry g,
) {
  final joints = AvatarPainter.armOf(pose, side);
  final chains = rigChains(pose, side);
  return (
    (joints.wrist - g.wrist).distance,
    _jointGap(
      chains,
      joints.wrist,
      math.max((chains[1][0] - joints.wrist).distance, 1e-6),
      g,
    ),
    _pipGap(_pipOf([for (var f = 0; f < 4; f++) chains[f]]), g.pip),
    _aimGap(chains, joints.wrist, g),
  );
}

/// Mean absolute difference between two sets of four PIP angles, in degrees.
double _pipGap(List<double> drawn, List<double> observed) {
  var cost = 0.0;
  for (var f = 0; f < 4; f++) {
    cost += (drawn[f] - observed[f]).abs();
  }
  return cost / 4;
}

/// How far each drawn finger aims from where the clip's did, in degrees.
///
/// The angle of the wrist→fingertip line, so a finger the rig draws shorter or
/// longer than the signer's still matches: what is left is the thing the fit
/// actually controls — palm angle, spread and curl — and the thing a viewer reads
/// as the same handshape. The pilot's clips ran 9.7° to 51.8°, against 0.0° for a
/// track the rig drew itself.
double _aimGap(List<List<Offset>> chains, Offset wrist, HandGeometry g) {
  var cost = 0.0, seen = 0;
  void compare(Offset drawnTip, Offset observedTip) {
    final a = drawnTip - wrist, b = observedTip - wrist;
    if (a.distance < 1e-6 || b.distance < 1e-6) return;
    final cos =
        (a.dx * b.dx + a.dy * b.dy) / (a.distance * b.distance);
    cost += math.acos(cos.clamp(-1.0, 1.0)) * 180 / math.pi;
    seen++;
  }

  for (var f = 0; f < 4; f++) {
    compare(chains[f][2], g.tips[f]);
  }
  compare(chains[4][2], g.thumbTip);
  // A hand whose tips all collapse on the wrist is not a hand; say so with the
  // worst aim there is rather than a flattering zero.
  return seen == 0 ? 180.0 : cost / seen;
}
