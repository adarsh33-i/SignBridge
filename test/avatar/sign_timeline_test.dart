import 'package:flutter_test/flutter_test.dart';

import 'package:sign_bridge/services/avatar/rig/sign_library.dart';
import 'package:sign_bridge/services/avatar/rig/sign_pose.dart';
import 'package:sign_bridge/services/avatar/rig/sign_timeline.dart';
import 'package:sign_bridge/services/translate/asl_nmm_markers.dart';
import 'package:sign_bridge/services/translate/sign_language_system.dart';
import 'package:sign_bridge/services/translate/sign_token.dart';
import 'package:sign_bridge/services/translate/sign_gloss_mapper.dart';

SignToken token(String id) =>
    SignToken(id: id, gloss: id.toUpperCase(), system: SignLanguageSystem.asl);

void main() {
  const caption = 'hello thank you eat rain cold today i am very happy to meet you';

  group('one pass, end to end', () {
    SignTimeline timeline() => SignTimeline.of(SignGlossMapper.signSequence(caption, 'ENG'));

    test('starts and ends on the resting pose', () {
      // The wrap is the frame nobody watches in a still, and it is the one that
      // used to teleport the arms from a raised hand back to the side.
      final t = timeline();
      expect(t.poseAt(0).right.shoulder, ArmPose.resting.shoulder);
      expect(t.poseAt(t.totalMs).right.shoulder, ArmPose.resting.shoulder);
      expect(t.poseAt(t.totalMs - 1).right.shoulder, closeTo(ArmPose.resting.shoulder, 1.5));
    });

    test('a position outside the run is still at rest', () {
      // The settle curve is a cubic. Past its endpoints it does not clamp, it
      // extrapolates, and a shoulder asked for a second after the caption ended
      // came back at 3716 degrees. The player keeps its playhead inside the run,
      // but reading past the end should mean "hands down", not depend on that.
      final t = timeline();
      expect(t.poseAt(-400).right.shoulder, ArmPose.resting.shoulder);
      expect(t.poseAt(t.totalMs + 1000).right.shoulder, ArmPose.resting.shoulder);
      expect(t.poseAt(t.totalMs + 1000).left.shoulder, ArmPose.resting.shoulder);
      expect(t.glossAt(t.totalMs + 1000), isNull);
    });

    test('the gloss names each sign while the hands are on it', () {
      final t = timeline();
      // Marker cues (the [cha] on "very happy") are backstage labels: they
      // hold the previous gloss on the chip instead of flashing notation.
      final wanted = t.cues
          .where((c) => !c.animation.faceOnly)
          .map((c) => c.animation.gloss)
          .toSet();
      var seen = <String>{};
      var previousIndex = -1;
      for (var ms = 0; ms < t.totalMs; ms += 5) {
        final gloss = t.glossAt(ms);
        // Never a gap: the chip may not blank out in the middle of a caption.
        expect(gloss, isNotNull, reason: 'no gloss at $ms ms');
        final index = t.cueIndexAt(ms);
        expect(index, greaterThanOrEqualTo(previousIndex), reason: 'went backwards at $ms ms');
        previousIndex = index;
        expect(index, lessThanOrEqualTo(t.cues.length - 1));
        seen.add(gloss!);
      }
      expect(seen, equals(wanted));
      expect(t.glossAt(t.totalMs), isNull);
    });

    test('the loop is continuous, whatever its speed', () {
      // The property worth pinning is not how fast a joint moves — a hand does
      // swing, and the worst step here is a shoulder leaving a hold at 1100°/s —
      // but whether the path is continuous at all. Subdivide a real movement and
      // each step shrinks with the interval; subdivide a teleport and it does
      // not, because there is nothing between the two poses to sample. So the
      // ratio of the worst 2ms step to the worst 16ms step is the whole test:
      // eight for a continuous loop, one for a snap.
      //
      // It caught two real ones. A reversed pingpong pass inherited the opening
      // key's `travelMs: 0` and snapped every repeating sign back to its start
      // pose in a single frame, and the 120ms word break was too short to carry
      // a hand from the temple to the side.
      final t = timeline();
      double worst(int stepMs) {
        var max = 0.0;
        SignPose? previous;
        for (var ms = 0; ms <= t.totalMs; ms += stepMs) {
          final pose = t.poseAt(ms);
          if (previous != null) {
            for (var arm = 0; arm < 2; arm++) {
              final now = _joints(arm == 0 ? pose.right : pose.left);
              final before = _joints(arm == 0 ? previous.right : previous.left);
              for (var j = 0; j < now.length; j++) {
                final d = (now[j] - before[j]).abs();
                if (d > max) max = d;
              }
            }
          }
          previous = pose;
        }
        return max;
      }

      final coarse = worst(16);
      expect(coarse, lessThan(24.0), reason: 'a joint is moving faster than a hand can');
      expect(worst(2) * 8, lessThanOrEqualTo(coarse * 1.6),
          reason: 'subdividing did not shrink the worst step, so something jumps');
    });

    test('an empty caption leaves the rig at rest', () {
      final t = SignTimeline.of(const []);
      expect(t.isEmpty, isTrue);
      expect(t.totalMs, 0);
      expect(t.poseAt(0).name, 'rest');
      expect(t.glossAt(0), isNull);
    });
  });

  group('the clocks', () {
    test('the fingers do not arrive together', () {
      // Pinch to flat is the shape change inside EAT. The middle finger leads
      // and the pinky trails, so half-way through the travel they cannot have
      // covered the same fraction of their own distance.
      final animation = SignLibrary.forToken(token('eat'))!;
      final segment = animation.segments.first;
      final mid = animation.poseAt(Duration(milliseconds: (segment.startMs + segment.endMs) ~/ 2));
      final from = segment.from.right.hand;
      final to = segment.to.right.hand;
      double progress(double a, double b, double now) =>
          (now - a) / (b - a);
      final byFinger = {
        'index': progress(from.index, to.index, mid.right.hand.index),
        'middle': progress(from.middle, to.middle, mid.right.hand.middle),
        'ring': progress(from.ring, to.ring, mid.right.hand.ring),
        'pinky': progress(from.pinky, to.pinky, mid.right.hand.pinky),
      };
      expect(byFinger.values.reduce((a, b) => a > b ? a : b) -
          byFinger.values.reduce((a, b) => a < b ? a : b), greaterThan(0.05),
          reason: 'every finger is still on one clock: $byFinger');
      expect(byFinger['middle'], greaterThan(byFinger['pinky']!),
          reason: 'the pinky should trail the middle finger');
    });

    test('the limb arrives before the hand does', () {
      // The kinetic chain, stated as an ordering: the shoulder reaches its
      // target part-way through a travel and the thumb — the slowest digit —
      // uses the whole of it. If a future change puts everything back on one
      // clock, both arrival times collapse to the same fraction and this fails.
      final animation = SignLibrary.forToken(token('eat'))!;
      final segment = animation.segments.first;
      final span = segment.endMs - segment.startMs;
      double arrival(double Function(SignPose) read) {
        final target = read(segment.to);
        for (var s = 0; s <= 100; s++) {
          final ms = segment.startMs + (span * s / 100).round();
          if ((read(animation.poseAt(Duration(milliseconds: ms))) - target).abs() <
              0.001) {
            return s / 100;
          }
        }
        return 1.0;
      }

      final shoulder = arrival((p) => p.right.shoulder);
      final thumb = arrival((p) => p.right.hand.thumb);
      expect(shoulder, lessThan(0.95), reason: 'the shoulder never got there');
      expect(
        thumb - shoulder,
        greaterThan(0.1),
        reason: 'shoulder arrives at $shoulder, thumb at $thumb — one clock',
      );
    });

    test('both ends of a segment are still exact', () {
      // Everything the timeline stitching and the goldens rely on: a pose at the
      // end of a segment is the authored pose, not a near miss.
      for (final id in ['eat', 'hello', 'rain', 'work', 'friend']) {
        final animation = SignLibrary.forToken(token(id))!;
        expect(animation.poseAt(Duration(milliseconds: animation.totalMs)),
            same(animation.segments.last.to),
            reason: '$id does not finish on its last keyframe');
        expect(animation.poseAt(Duration.zero), animation.frames.first.pose);
      }
    });
  });

  group('face markers co-articulate with the hands', () {
    SignToken marker(String id) =>
        AslNmmMarkers.token(id, SignLanguageSystem.asl);

    double deviationFromRest(ArmPose a) => [
          (a.shoulder - ArmPose.resting.shoulder).abs(),
          (a.elbow - ArmPose.resting.elbow).abs(),
        ].reduce((p, q) => p > q ? p : q);

    test('a mid-sentence marker does not park the hands', () {
      // The face owns the grammar beat, not the arms: between HELLO and EAT
      // the hands are travelling temple to mouth, nowhere near the sides.
      final t = SignTimeline.of([token('hello'), marker(AslNmmMarkers.whQ), token('eat')]);
      final whCue = t.cues[1];
      final mid = whCue.startMs + whCue.animation.totalMs ~/ 2;
      final pose = t.poseAt(mid);
      expect(deviationFromRest(pose.right), greaterThan(25),
          reason: 'the hands dropped home in the middle of the marker');
      expect(pose.face.brow, lessThan(-0.5),
          reason: 'the furrow plays while the hands travel');
    });

    test('the marker run is one continuous travel, not three beats', () {
      // Gap + marker + gap is a single arm journey; a seam at either marker
      // edge would show up exactly where the old rest-parking did — the worst
      // fine step stops shrinking under subdivision.
      final t = SignTimeline.of([
        token('hello'),
        marker(AslNmmMarkers.whQ),
        token('eat'),
        marker(AslNmmMarkers.ynQ),
        token('rain'),
      ]);
      double worst(int stepMs) {
        var max = 0.0;
        SignPose? previous;
        for (var ms = 0; ms <= t.totalMs; ms += stepMs) {
          final pose = t.poseAt(ms);
          if (previous != null) {
            for (var arm = 0; arm < 2; arm++) {
              final now = _joints(arm == 0 ? pose.right : pose.left);
              final before = _joints(arm == 0 ? previous.right : previous.left);
              for (var j = 0; j < now.length; j++) {
                final d = (now[j] - before[j]).abs();
                if (d > max) max = d;
              }
            }
          }
          previous = pose;
        }
        return max;
      }

      final coarse = worst(16);
      expect(coarse, lessThan(24.0), reason: 'a joint is moving faster than a hand can');
      expect(worst(2) * 8, lessThanOrEqualTo(coarse * 1.6),
          reason: 'subdividing did not shrink the worst step, so something jumps');
    });

    test('the chip never shows marker notation', () {
      final t = SignTimeline.of([
        marker(AslNmmMarkers.ynQ),
        token('hello'),
        marker(AslNmmMarkers.whQ),
      ]);
      final seen = <String?>{};
      for (var ms = 0; ms <= t.totalMs; ms += 5) {
        seen.add(t.glossAt(ms));
      }
      expect(seen, isNot(contains(isNull)),
          reason: 'the chip went blank around a marker');
      for (final gloss in seen) {
        expect(gloss!.startsWith('['), isFalse,
            reason: 'stage direction "$gloss" reached the chip');
      }
    });

    test('a trailing marker settles with the arms, not before them', () {
      // [wh-q] after the last sign: at the hold's midpoint the furrow is fully
      // down and the elbow is still measurably off rest (measured: ~15
      // degrees) — the grammar overlaps the settle instead of waiting for it.
      // Under the old rest-parking every joint read exactly 0 for the whole
      // cue, which is the regression this pins.
      final t = SignTimeline.of([token('hello'), marker(AslNmmMarkers.whQ)]);
      final end = t.poseAt(t.totalMs);
      expect(end.right.shoulder, ArmPose.resting.shoulder);
      expect(end.left.shoulder, ArmPose.resting.shoulder);
      final whCue = t.cues[1];
      final holdMid = whCue.startMs + whCue.animation.totalMs ~/ 2;
      final pose = t.poseAt(holdMid);
      expect(pose.face.brow, lessThan(-0.8),
          reason: 'the furrow is not holding at the marker midpoint');
      final deviations = [
        (pose.right.elbow - ArmPose.resting.elbow).abs(),
        (pose.left.elbow - ArmPose.resting.elbow).abs(),
      ];
      final elbowDeviation =
          deviations.reduce((p, q) => p > q ? p : q);
      expect(elbowDeviation, greaterThan(10),
          reason: 'the arms were already parked when the face marked');
    });
  });
}

List<double> _joints(ArmPose a) => [
      a.shoulder,
      a.elbow,
      a.wrist,
      a.palm,
      a.lift,
      a.hand.index,
      a.hand.middle,
      a.hand.ring,
      a.hand.pinky,
      a.hand.thumb,
    ];
