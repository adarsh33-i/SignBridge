import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:sign_bridge/services/avatar/rig/avatar_painter.dart';
import 'package:sign_bridge/services/avatar/rig/sign_animation.dart';
import 'package:sign_bridge/services/avatar/rig/sign_library.dart';
import 'package:sign_bridge/services/avatar/rig/sign_pose.dart';

import '../tools/landmark_fitter.dart';

/// A clip a signer would have produced for an authored sign.
///
/// Every point comes from the painter's own chains, held five frames per keyframe
/// the way a 10 fps clip holds a citation form, so the only thing the round trip
/// can be wrong about is the fitter: if a sign the rig already draws correctly does
/// not come back out of it, nothing fitted from a real video can be trusted.
LandmarkTrack syntheticTrack(String id, SignAnimation animation) {
  final bySlot = <String, List<TrackFrame>>{'left': [], 'right': []};
  var ordinal = 0;
  for (final key in animation.frames) {
    for (var held = 0; held < 5; held++) {
      for (final side in [-1.0, 1.0]) {
        final arm = side < 0 ? key.pose.left : key.pose.right;
        if (!arm.visible) continue;
        bySlot[side < 0 ? 'left' : 'right']!.add(
          TrackFrame(ordinal: ordinal, points: corpusPointsOf(key.pose, side)),
        );
      }
      ordinal++;
    }
  }
  return LandmarkTrack(
    key: 'synthetic/$id',
    frameMs: 100,
    hands: [
      for (final entry in bySlot.entries)
        if (entry.value.isNotEmpty)
          TrackHand(slot: entry.key, frames: entry.value),
    ],
  );
}

/// Where a hand is and which way it aims — the movement a keyframe carries.
///
/// The handshape is deliberately not part of this: the fit quantises curls to the
/// shape table's grid and can reach the same drawn hand from a neighbouring curl
/// value, so comparing fields would fail on a fit that is visually identical.
typedef _Place = ({double dx, double dy, double palm});

_Place _placeOf(SignPose pose, double side) {
  final j = AvatarPainter.armOf(pose, side);
  return (dx: j.wrist.dx, dy: j.wrist.dy, palm: j.palmAngle);
}

bool _same(_Place a, _Place b) =>
    (a.dx - b.dx).abs() < 0.02 &&
    (a.dy - b.dy).abs() < 0.02 &&
    _turnGap(a.palm, b.palm) < 6;

double _turnGap(double a, double b) {
  final d = (a - b).abs() % 360.0;
  return d > 180 ? 360 - d : d;
}

/// The distinct places one hand visits over the authored sign, and whether it
/// visits more than one. A support hand that never leaves its rest pose has one
/// entry and is not a movement, so it is not what the keyframe test is about.
List<_Place> _authoredPlaces(SignAnimation animation, double side) {
  final places = <_Place>[];
  for (final key in animation.frames) {
    final arm = side < 0 ? key.pose.left : key.pose.right;
    if (!arm.visible) continue;
    final p = _placeOf(key.pose, side);
    if (!places.any((e) => _same(e, p))) places.add(p);
  }
  return places;
}

/// Signs whose per-hand movement the keyframe budget can represent: at most four
/// distinct places for each hand, which is what `FitResult` is allowed to keep.
const List<String> _roundTripIds = [
  'hello',
  'home',
  'mother',
  'thank_you',
  'eat',
  'no',
  'yes',
  'water',
  'rain',
  'talk',
  'watch',
  'see',
];

void main() {
  group('landmark fitter', () {
    test('the palm-axis correction cancels the knuckle offset', () {
      // The one calibration the fit cannot derive from a clip: a hand drawn at a
      // known palm angle has its middle knuckle a few degrees off that angle, and
      // `palmOf` has to give the angle back.
      for (final hand in [
        HandShape.flat,
        HandShape.fist,
        HandShape.point,
        HandShape(
          index: 0.5,
          middle: 0.55,
          ring: 0.6,
          pinky: 0.65,
          thumb: 0.5,
        ),
        HandShape(
          index: 0,
          middle: 0,
          ring: 0,
          pinky: 0,
          spread: 0.9,
          thumbUp: 1,
        ),
      ]) {
        for (final side in [-1.0, 1.0]) {
          for (var palm = 0.0; palm < 360; palm += 40) {
            final wrist = ui.Offset(0.5 + side * 0.12, 0.42);
            final chains = chainsOf(hand, wrist, palm, side);
            final d = chains[1][0] - wrist;
            final observed =
                (d.dx == 0 && d.dy == 0) ? palm : _bearingOf(d.dx, d.dy);
            expect(
              _turnGap(palmOf(hand, side, observed), palm),
              lessThan(0.01),
              reason:
                  'a $hand hand on side ${side.toInt()} drawn at palm $palm '
                  'reports its knuckle at $observed, and the correction must '
                  'round-trip that',
            );
          }
        }
      }
    });

    test('an authored sign comes back out of the fitter', () {
      for (final id in _roundTripIds) {
        final animation = SignLibrary.debugCore[id];
        expect(animation, isNotNull, reason: '$id is not an authored core sign');
        final fit = fitTrack(syntheticTrack(id, animation!));
        expect(fit, isNotNull, reason: '$id produced no fit');
        expect(
          fit!.reflected,
          isFalse,
          reason:
              '$id was drawn by the rig and fed back unmirrored, so the direct '
              'reading is the one to report; mirroring is an argument the caller '
              'passes, never something the fit picks',
        );

        // What the fit draws has to land where the clip showed a hand. Placement
        // is in rig units against a shoulder of 0.336 — 0.005 is 1.5% of a
        // shoulder, about a pixel at card size. Shape is in palm lengths and 0.02
        // is under the smallest curl step the rig can show.
        expect(
          fit.placementError,
          lessThan(0.005),
          reason: '$id: wrist reprojects ${fit.placementError * 100}% of a shoulder',
        );
        expect(
          fit.shapeError,
          lessThan(0.02),
          reason: '$id: handshape reprojects ${fit.shapeError}',
        );

        // And the movement has to survive: the same places, both directions.
        for (final side in [-1.0, 1.0]) {
          final authored = _authoredPlaces(animation, side);
          if (authored.length < 2) continue;
          final fitted = <_Place>[];
          for (final key in fit.keys) {
            final p = _placeOf(key.pose, side);
            if (!fitted.any((e) => _same(e, p))) fitted.add(p);
          }
          expect(
            fitted.length,
            lessThanOrEqualTo(4),
            reason: '$id: the fit made ${fitted.length} keyframes for one hand',
          );
          for (final f in fitted) {
            expect(
              authored.any((a) => _same(a, f)),
              isTrue,
              reason:
                  '$id side ${side.toInt()}: the fit invented a place at '
                  '${f.dx.toStringAsFixed(3)},${f.dy.toStringAsFixed(3)} '
                  'palm ${f.palm.toStringAsFixed(0)} that the sign never visits',
            );
          }
          for (final a in authored) {
            expect(
              fitted.any((f) => _same(f, a)),
              isTrue,
              reason:
                  '$id side ${side.toInt()}: the sign visits '
                  '${a.dx.toStringAsFixed(3)},${a.dy.toStringAsFixed(3)} palm '
                  '${a.palm.toStringAsFixed(0)} and the fit dropped it',
            );
          }
        }
      }
    });

    test('mirroring the clip costs exactly the same, so error cannot pick a chirality', () {
      // `fitTrack` used to compare the direct and mirrored readings and take the
      // better. It cannot: `armTo` and `digitBones` both mirror with `side`, so the
      // rig's two readings are congruent and any preference between them is
      // floating-point noise. This pins that, because the day the rig grows an
      // asymmetric term the whole "the mirror is a caller's argument" story breaks
      // and this is the test that says so.
      final track = syntheticTrack('hello', SignLibrary.debugCore['hello']!);
      final direct = fitTrack(track)!;
      final mirrored = fitTrack(track, reflect: true)!;
      expect(
        mirrored.placementError,
        closeTo(direct.placementError, 1e-12),
        reason: 'the mirrored fit should cost the wrist the same to the decimal',
      );
      expect(mirrored.shapeError, closeTo(direct.shapeError, 1e-12));
      expect(mirrored.pipError, closeTo(direct.pipError, 1e-12));
      expect(mirrored.keys.length, direct.keys.length);
    });

    test('a keyframe is timed on the clip clock, not on its own count', () {
      final fit = fitTrack(syntheticTrack('hello', SignLibrary.debugCore['hello']!));
      expect(fit, isNotNull);
      expect(fit!.keys.first.startMs, 0);
      for (final key in fit.keys) {
        expect(key.holdMs, greaterThan(0));
      }
      // Five frames held at 100 ms each: a keyframe that starts at 1000 ms has
      // seen ten clip frames, not five list entries.
      expect(fit.keys[1].startMs % 500, 0, reason: 'keys start on a held-run edge');
    });
  });

  group('fit gate', () {
    test('a clean clip is accepted', () {
      // The gate has to pass the evidence it was calibrated on, or it is only
      // ever going to say no.
      for (final id in _roundTripIds) {
        final fit = fitTrack(syntheticTrack(id, SignLibrary.debugCore[id]!));
        expect(
          fit!.verdict.accepted,
          isTrue,
          reason:
              '$id: a clip drawn by the rig itself should clear every gate: '
              '${fit.verdict.reasons.join("; ")}',
        );
        // The round trip is rig-against-rig, so every angular number in it is a
        // floor, not a target: aim can only be off by the curl table's own
        // granularity. 0.5 degrees is that granularity measured over twelve signs.
        expect(
          fit.aimError,
          lessThan(0.5),
          reason: '$id: a hand drawn by the rig should aim exactly where it drew it',
        );
      }
    });

    test('a hand that comes back keeps both of its places', () {
      // The chain-merge failure: a run shorter than the minimum used to be added
      // to whichever run came before it in the list. For a hand that leaves a
      // place and returns to it, the run before it is the *other* place, so the
      // two averaged into a position the hand was never at. HELLO's clip did
      // exactly that and scored four times the placement gate on a clip whose
      // every frame solves exactly.
      final a = SignLibrary.debugCore['hello']!.frames.first.pose;
      final b = SignLibrary.debugCore['home']!.frames.first.pose;
      final frames = <TrackFrame>[];
      var ordinal = 0;
      // A, a hold; B, one frame away; A again, held. The single B frame is the
      // one that must not be swallowed by the A run before it.
      for (final run in [
        (a, 4),
        (b, 1),
        (a, 4),
      ]) {
        for (var n = 0; n < run.$2; n++) {
          frames.add(
            TrackFrame(
              ordinal: ordinal++,
              points: corpusPointsOf(run.$1, 1),
            ),
          );
        }
      }
      final fit = fitTrack(
        LandmarkTrack(
          key: 'synthetic/zigzag',
          frameMs: 100,
          hands: [TrackHand(slot: 'right', frames: frames)],
        ),
      );
      expect(fit, isNotNull);
      for (final key in fit!.keys) {
        expect(
          key.placementError,
          lessThan(maxPlacementError),
          reason:
              'a keyframe is one place the hand was, but it reprojects '
              '${key.placementError} rig units — an average of two places',
        );
      }
      expect(
        fit.verdict.accepted,
        isTrue,
        reason: 'a clean zigzag clip must pass its own gate: ${fit.verdict.reasons}',
      );
    });

    test('a slot seen twice is not a hand', () {
      final animation = SignLibrary.debugCore['hello']!;
      final clean = syntheticTrack('hello', animation);
      // HELLO, MOTHER and WATER each had a two-frame flicker of the idle hand,
      // and because the rig has one arm per side of the body a flicker anywhere
      // hijacks the arm already there.
      final flicker = TrackHand(
        slot: 'left',
        frames: [
          for (var n = 0; n < 2; n++)
            TrackFrame(
              ordinal: n,
              points: corpusPointsOf(SignPose.resting, -1),
            ),
        ],
      );
      final fit = fitTrack(
        LandmarkTrack(
          key: 'synthetic/flicker',
          frameMs: clean.frameMs,
          hands: [...clean.hands, flicker],
        ),
      );
      expect(fit, isNotNull);
      expect(
        fit!.droppedSlots.any((s) => s.startsWith('left')),
        isTrue,
        reason: 'a two-frame slot must be dropped, and named as dropped',
      );
      expect(
        fit.verdict.notes.any((n) => n.contains('dropped left')),
        isTrue,
        reason: 'the report says what it threw away: ${fit.verdict.notes}',
      );
    });

    test('a four-frame signing hand is a sign, a four-frame second hand is not', () {
      // One clip per word means a signing hand the palm-range filter lost for half
      // the clip is all there is, so the clip's longest slot gets the lower floor.
      // The ladder still has a bottom: every arm-hijack flicker in the pilot was
      // 1 to 3 frames, and a slot that short is refused even when it stands alone.
      final pose = SignLibrary.debugCore['hello']!.frames.first.pose;
      TrackHand slot(String name, int frames, double side) => TrackHand(
        slot: name,
        frames: [
          for (var n = 0; n < frames; n++)
            TrackFrame(ordinal: n, points: corpusPointsOf(pose, side)),
        ],
      );
      FitResult? fit(List<TrackHand> hands) => fitTrack(
        LandmarkTrack(key: 'synthetic/driver', frameMs: 100, hands: hands),
      );

      final alone = fit([slot('right', 4, 1)]);
      expect(alone, isNotNull, reason: 'a 4-frame driver is the only take of this word');
      expect(alone!.droppedSlots, isEmpty);
      expect(alone.keys.last.frames, 4);
      expect(
        alone.verdict.accepted,
        isTrue,
        reason: 'a held rig-drawn pose should be citable: ${alone.verdict.reasons}',
      );

      final second = fit([slot('left', 7, -1), slot('right', 4, 1)]);
      expect(second, isNotNull);
      expect(
        second!.droppedSlots.any((s) => s.startsWith('right')),
        isTrue,
        reason:
            'the longest slot is the signing hand; a 4-frame hand beside a 7-frame '
            'one is the second hand, and the bar for that stays '
            '$minSlotFrames: ${second.droppedSlots}',
      );

      expect(
        fit([slot('right', 3, 1)]),
        isNull,
        reason: '3 frames is the longest flicker the pilot saw, not a citation form',
      );
    });

    test('a rolled palm is refused as footage, not fitted badly', () {
      // Compressing the knuckle span sideways is what a hand turned away from the
      // camera looks like to MediaPipe. The rig's narrowest drawable palm spans
      // 0.58 of a palm, so below that there is no handshape to fit to.
      final pose = SignLibrary.debugCore['thank_you']!.frames.first.pose;
      final points = corpusPointsOf(pose, 1);
      // Rolling a hand about its own wrist-to-fingers axis foreshortens it
      // *across* the knuckles and nothing else, so the compression goes along the
      // index-to-pinky line rather than along image x — a hand aimed sideways in
      // the frame would otherwise get its palm squashed and its aspect raised.
      final span = points[17] - points[5];
      final u = span / span.distance;
      final mid = ui.Offset(
        (points[5].dx + points[17].dx) / 2,
        (points[5].dy + points[17].dy) / 2,
      );
      final rolled = [
        for (final q in points) _compressAlong(q, mid, u, 0.45),
      ];

      final fit = fitTrack(
        LandmarkTrack(
          key: 'synthetic/rolled',
          frameMs: 100,
          hands: [
            TrackHand(
              slot: 'right',
              frames: [
                for (var n = 0; n < 8; n++)
                  TrackFrame(ordinal: n, points: rolled),
              ],
            ),
          ],
        ),
      );
      expect(fit, isNotNull);
      expect(
        fit!.keys.first.aspect,
        lessThan(rigMinAspect),
        reason: 'the roll should put the clip inside the rig\'s unreachable range',
      );
      expect(
        fit.verdict.reasons.any((r) => r.contains('rolled')),
        isTrue,
        reason:
            'a rolled hand should be named as rolled, not just as a shape error: '
            '${fit.verdict.reasons}',
      );
    });

    test('a fist tighter than the rig can fold is blamed on the rig', () {
      // The pilot's biggest rejection, and the one the fit has no part in: the
      // renderer stops closing a finger at `minDrawablePip`, so a clip folded past
      // it fails the same gate a handshape mistake fails. A tally that could not
      // tell those apart would read "the fitter is bad at fists" instead of "the
      // avatar cannot make a fist", which is the finding that needs a decision.
      final points = corpusPointsOf(SignLibrary.debugCore['thank_you']!.frames.first.pose, 1);
      const fingers = [[5, 6, 8], [9, 10, 12], [13, 14, 16], [17, 18, 20]];
      // Bending a tip about its own PIP joint moves nothing else: the knuckle span,
      // the palm and the wrist all stay where the rig drew them, so this clip can
      // only fail on fold.
      final tight = [...points];
      for (final chain in fingers) {
        tight[chain[2]] = _bendTo(
          points[chain[0]],
          points[chain[1]],
          points[chain[2]],
          20,
        );
      }
      final fit = fitTrack(
        LandmarkTrack(
          key: 'synthetic/tight-fist',
          frameMs: 100,
          hands: [
            TrackHand(
              slot: 'right',
              frames: [for (var n = 0; n < 8; n++) TrackFrame(ordinal: n, points: tight)],
            ),
          ],
        ),
      )!;
      // `docs/sign_avatar_rig.md` quotes both of these numbers, so a renderer
      // change has to move the doc with it.
      expect(
        minDrawablePip,
        closeTo(92.7, 0.1),
        reason: 'the tightest hand the rig draws, read off digitBones',
      );
      expect(fit.keys.first.observedPip, lessThan(25));
      expect(
        fit.verdict.gates,
        contains('fold ceiling'),
        reason:
            'the tightest hand the rig draws is ${minDrawablePip.toStringAsFixed(1)}° '
            'and this clip holds 20°, so no library handshape could clear '
            '$maxPipError: ${fit.verdict.reasons}',
      );
      expect(
        fit.verdict.gates,
        isNot(contains('fold')),
        reason: 'a renderer ceiling must not also count as a fit failure',
      );
      expect(
        fit.verdict.reasons.any((r) => r.contains('past what this rig can draw')),
        isTrue,
        reason: '${fit.verdict.reasons}',
      );
    });

    test('the gate reports the size of what failed, not just that it did', () {
      // A rejection has to say how far off it is, because that is the difference
      // between "this clip needs a better camera angle" and "the fitter is wrong".
      final fit = fitTrack(syntheticTrack('hello', SignLibrary.debugCore['hello']!));
      expect(fit!.verdict.accepted, isTrue);
      expect(fit.verdict.reasons, isEmpty);
      final worst = fit.keys.reduce((a, b) => a.frames >= b.frames ? a : b);
      expect(
        worst.placementError,
        lessThan(maxPlacementError / 4),
        reason: 'a clean fit should clear its gate by miles, not by a hair',
      );
      expect(worst.pipError, lessThan(maxPipError / 3));
      expect(worst.aimError, lessThan(maxAimError / 3));
    });

    test('a signer with longer fingers than the rig is still a fit', () {
      // The 23-clip pilot rejected 16 clips for where their joints landed, and
      // that number cannot say what was wrong with any of them: a fingertip's
      // position is its aim times its radius, plus its fold, plus the length of
      // the finger the rig does not have. Growing every finger 60% from its own
      // knuckle leaves both angles exactly as they were — each finger's joints
      // move along the line that defines them — and the position number still
      // crosses the old floor on its own. So the position figure stays as the
      // reported gap between our hand and a signer's, and the gates are on the
      // three things a fit can be wrong about.
      final fit = fitTrack(
        _longerFingers(
          syntheticTrack('hello', SignLibrary.debugCore['hello']!),
          1.6,
        ),
      )!;
      expect(
        fit.shapeError,
        greaterThan(shapeNoteFloor),
        reason:
            'the grown hand has to miss the rig\'s joints or this tests nothing: '
            '${fit.shapeError}',
      );
      expect(
        fit.pipError,
        lessThan(maxPipError / 3),
        reason: 'folding is a length-independent measurement',
      );
      expect(
        fit.aimError,
        lessThan(maxAimError / 3),
        reason: 'a longer finger still points the same way from the wrist',
      );
      expect(
        fit.verdict.accepted,
        isTrue,
        reason: 'a long-handed signer is not a bad fit: ${fit.verdict.reasons}',
      );
      expect(
        fit.verdict.notes.any((n) => n.contains('finger length')),
        isTrue,
        reason:
            'the proportion gap has to be reported rather than silently gone: '
            '${fit.verdict.notes}',
      );
    });
  });
}

/// [track] with every finger's two free joints moved outward from their own
/// knuckle by [factor] — the same hand, longer.
LandmarkTrack _longerFingers(LandmarkTrack track, double factor) {
  const fingers = [[5, 6, 8], [9, 10, 12], [13, 14, 16], [17, 18, 20]];
  TrackFrame grow(TrackFrame frame) {
    final points = [...frame.points];
    for (final chain in fingers) {
      final mcp = points[chain[0]];
      for (final i in chain.skip(1)) {
        final d = points[i] - mcp;
        points[i] = ui.Offset(mcp.dx + d.dx * factor, mcp.dy + d.dy * factor);
      }
    }
    return TrackFrame(ordinal: frame.ordinal, points: points);
  }

  return LandmarkTrack(
    key: track.key,
    frameMs: track.frameMs,
    hands: [
      for (final h in track.hands)
        TrackHand(slot: h.slot, frames: [for (final f in h.frames) grow(f)]),
    ],
  );
}

double _bearingOf(double dx, double dy) => math.atan2(dx, dy) * 180 / math.pi;

/// [tip] rotated about its own PIP joint until the MCP-PIP-TIP angle reads
/// [targetDeg], with the finger's length kept.
///
/// Either sense of the rotation gives the same angle, and which way a finger curls
/// is not what this measures, so it just turns by the shortfall.
ui.Offset _bendTo(
  ui.Offset mcp,
  ui.Offset pip,
  ui.Offset tip,
  double targetDeg,
) {
  final a = mcp - pip, b = tip - pip;
  if (a.distance < 1e-6 || b.distance < 1e-6) return tip;
  final cosine = (a.dx * b.dx + a.dy * b.dy) / (a.distance * b.distance);
  final gap = math.acos(cosine.clamp(-1.0, 1.0)) * 180 / math.pi - targetDeg;
  final theta = gap * math.pi / 180;
  final c = math.cos(theta), s = math.sin(theta);
  return ui.Offset(
    pip.dx + b.dx * c - b.dy * s,
    pip.dy + b.dx * s + b.dy * c,
  );
}

/// [q] moved to [keep] of its distance along the unit direction [u] from [mid].
///
/// This is a roll about the palm's own axis, drawn as what a camera sees of it:
/// the hand gets narrower across the knuckles and no shorter.
ui.Offset _compressAlong(
  ui.Offset q,
  ui.Offset mid,
  ui.Offset u,
  double keep,
) {
  final d = q - mid;
  final along = (d.dx * u.dx + d.dy * u.dy) * (1 - keep);
  return ui.Offset(mid.dx + d.dx - along * u.dx, mid.dy + d.dy - along * u.dy);
}
