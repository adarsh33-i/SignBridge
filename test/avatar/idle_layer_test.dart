import 'package:flutter_test/flutter_test.dart';

import 'package:sign_bridge/services/avatar/rig/idle_layer.dart';
import 'package:sign_bridge/services/avatar/rig/sign_pose.dart';

/// The idle layer only has to hold one promise: it never overwrites a pose the
/// library authored, and it is a pure function of elapsed time.
void main() {
  SignPose raised({double right = 8, double left = 8}) => SignPose(
    name: 'test',
    left: ArmPose(shoulder: left),
    right: ArmPose(shoulder: right),
    face: FacePose.neutral,
  );

  group('breath', () {
    test('swings between flat and lifted over the cycle', () {
      expect(IdleLayer.apply(SignPose.resting, 0).breath, closeTo(0, 0.001));
      final mid = IdleLayer.apply(
        SignPose.resting,
        IdleLayer.breathCycleMs ~/ 2,
      );
      expect(mid.breath, closeTo(1, 0.001));
      expect(
        IdleLayer.apply(SignPose.resting, IdleLayer.breathCycleMs).breath,
        closeTo(0, 0.001),
      );
    });

    test('stays inside 0..1 across the whole cycle', () {
      for (var ms = 0; ms < IdleLayer.breathCycleMs; ms += 37) {
        final breath = IdleLayer.apply(SignPose.resting, ms).breath;
        expect(breath, inInclusiveRange(0, 1));
      }
    });
  });

  group('blink', () {
    test('once per cycle, shut at the peak, open everywhere else', () {
      expect(IdleLayer.blinkAt(0), 0);
      expect(IdleLayer.blinkAt(IdleLayer.blinkOpenMs), closeTo(1, 0.001));
      expect(IdleLayer.blinkAt(IdleLayer.blinkMs), 0);
      for (var ms = IdleLayer.blinkMs; ms < IdleLayer.blinkCycleMs; ms += 91) {
        expect(IdleLayer.blinkAt(ms), 0);
      }
    });

    test('rides on top of the pose rather than replacing it', () {
      final authored = SignPose.resting.copyWith(face: const FacePose(blink: 0.4));
      final shut = IdleLayer.apply(authored, IdleLayer.blinkOpenMs);
      expect(shut.face.blink, 1);
      final calm = IdleLayer.apply(authored, 1000);
      expect(calm.face.blink, closeTo(0.4, 0.001));
    });

    test('never fires under a mouthed or wide-eyed marker', () {
      final mouthed = SignPose.resting.copyWith(
        face: const FacePose(mouth: 0.45),
      );
      expect(IdleLayer.apply(mouthed, IdleLayer.blinkOpenMs).face.blink, 0);
      final wide = SignPose.resting.copyWith(face: const FacePose(eyes: 0.5));
      expect(IdleLayer.apply(wide, IdleLayer.blinkOpenMs).face.blink, 0);
      // A neutral face at the same instant still blinks.
      expect(IdleLayer.apply(SignPose.resting, IdleLayer.blinkOpenMs).face.blink, 1);
    });

    test('a held brow still blinks: a question lasts seconds', () {
      // The question face now spans the whole sentence, so suppressing the
      // blink for as long as the brow is raised would freeze the eyes for
      // every question. The brows carry grammar; the lids carry life.
      final furrowed = SignPose.resting.copyWith(
        face: const FacePose(brow: -0.85),
      );
      expect(
        IdleLayer.apply(furrowed, IdleLayer.blinkOpenMs).face.blink,
        1,
        reason: 'the held wh-question brow must not stop the blink',
      );
    });
  });

  group('gaze', () {
    test('turns toward the hand that is doing the signing', () {
      final rightUp = IdleLayer.apply(raised(right: 120), 0);
      final leftUp = IdleLayer.apply(raised(left: 120), 0);
      expect(rightUp.face.headTurn, greaterThan(0.4));
      expect(leftUp.face.headTurn, lessThan(-0.4));
    });

    test('drifts when both hands are down, so a resting body still moves', () {
      final early = IdleLayer.apply(SignPose.resting, 0).face.headTurn;
      final later = IdleLayer.apply(SignPose.resting, 1500).face.headTurn;
      expect(early, isNot(later));
      expect(later.abs(), lessThan(0.2));
    });

    test('an authored head shift wins: it carries grammar', () {
      final marker = SignPose.resting.copyWith(face: const FacePose(headTurn: -1));
      expect(IdleLayer.apply(marker, 2200).face.headTurn, -1);
    });
  });

  group('eyes', () {
    test('the pupils look where the head looks', () {
      final rightUp = IdleLayer.apply(raised(right: 120), 0);
      expect(rightUp.face.gaze, greaterThan(0.4));
      final leftUp = IdleLayer.apply(raised(left: 120), 0);
      expect(leftUp.face.gaze, lessThan(-0.4));
    });

    test('an authored gaze wins: it is a deliberate look', () {
      final posed = SignPose.resting.copyWith(face: const FacePose(gaze: 0.8));
      expect(IdleLayer.apply(posed, 2200).face.gaze, 0.8);
    });
  });

  group('rest expression', () {
    test('never invents a smile', () {
      // The layer used to force a 0.32 smile onto every still mouth. It made
      // the avatar look pleasant and completely frozen: the same expression
      // for every sign, regardless of what the sign meant.
      expect(IdleLayer.apply(SignPose.resting, 700).face.smile, 0);
      final mouthed = SignPose.resting.copyWith(face: const FacePose(mouth: 0.6));
      expect(IdleLayer.apply(mouthed, 700).face.smile, 0);
      final authored = SignPose.resting.copyWith(face: const FacePose(smile: 0.9));
      expect(IdleLayer.apply(authored, 700).face.smile, closeTo(0.9, 0.001));
    });
  });

  test('the same instant always renders the same pose', () {
    final base = raised(right: 90);
    expect(
      IdleLayer.apply(base, 3120).toJson(),
      IdleLayer.apply(base, 3120).toJson(),
    );
  });
}
