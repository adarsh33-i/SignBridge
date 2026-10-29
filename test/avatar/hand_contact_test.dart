import 'package:flutter_test/flutter_test.dart';

import 'package:sign_bridge/services/avatar/rig/avatar_painter.dart';
import 'package:sign_bridge/services/avatar/rig/sign_pose.dart';

/// The contact crease between a hand and what it presses. It is intersection
/// geometry, not a glow, so a hand hovering in signing space casts no shadow
/// and a hand-on-face hold gets one exactly where the two silhouettes meet.
void main() {
  group('handUnitPath / headUnitPath', () {
    test('a hand translated to the wrist lands where it is placed', () {
      final hand = AvatarPainter.handUnitPath(
        const ArmPose(shoulder: 60, elbow: 140, hand: HandShape.flat),
        const Offset(0.40, 0.50),
        0,
        -1,
      );
      // The palm root sits at the wrist and the palm extends palm-length
      // along the palm angle (0 = straight down).
      expect(hand.contains(const Offset(0.40, 0.52)), isTrue);
      expect(hand.contains(const Offset(0.40, 0.50 + 0.06)), isTrue);
      // Nothing of the hand reaches back up to the origin.
      expect(hand.contains(const Offset(0.0, 0.0)), isFalse);
    });

    test('headUnitPath orbits the neck pivot but never shrinks at any tilt', () {
      // Measured from the untilted silhouette rather than copied out of the
      // painter: the skull radius is a proportion constant that moves whenever
      // the head/shoulder read is retuned, and this pin is about coverage at
      // whatever radius the head currently has.
      final rest = AvatarPainter.headUnitPath(
        const SignPose(
          name: 't',
          left: ArmPose.resting,
          right: ArmPose.resting,
          face: FacePose.neutral,
        ),
      ).getBounds();
      final radius = rest.width / 2;
      const centre = Offset(0.5, 0.245);
      for (final tilt in [-12.0, 0.0, 14.0]) {
        final pose = SignPose(
          name: 't',
          left: ArmPose.resting,
          right: ArmPose.resting,
          face: FacePose(headTilt: tilt),
        );
        final head = AvatarPainter.headUnitPath(pose);
        final bounds = head.getBounds();
        // The centre swings around the neck pivot (getBounds on the rotated
        // cubic is slightly inflated, hence the loose slack)…
        final centreShift = (bounds.center - centre).distance;
        expect(centreShift, lessThan(radius * 0.6));
        // …but the skull still covers the face it draws around.
        expect(head.contains(centre), isTrue);
        expect(head.contains(Offset(0.5, centre.dy - radius * 0.9)), isTrue);
      }
    });
  });

  group('contactShadow', () {
    test('two hands pressed together cast a shadow inside both', () {
      final a = AvatarPainter.handUnitPath(
        const ArmPose(shoulder: 60, elbow: 140, hand: HandShape.flat),
        const Offset(0.48, 0.50),
        0,
        -1,
      );
      final b = AvatarPainter.handUnitPath(
        const ArmPose(shoulder: 60, elbow: 140, hand: HandShape.flat),
        const Offset(0.52, 0.50),
        0,
        1,
      );
      final shadow = AvatarPainter.contactShadow(a, b);
      expect(shadow, isNotNull);
      // The overlap hugs the meeting line.
      final bounds = shadow!.getBounds();
      expect(bounds.left, greaterThan(0.44));
      expect(bounds.right, lessThan(0.56));
      expect(shadow.contains(const Offset(0.5, 0.52)), isTrue);
    });

    test('hands far apart cast nothing', () {
      final a = AvatarPainter.handUnitPath(
        const ArmPose(shoulder: 8, hand: HandShape.relax),
        const Offset(0.30, 0.60),
        0,
        -1,
      );
      final b = AvatarPainter.handUnitPath(
        const ArmPose(shoulder: 8, hand: HandShape.relax),
        const Offset(0.70, 0.60),
        0,
        1,
      );
      expect(AvatarPainter.contactShadow(a, b), isNull);
    });

    test('a hand at the forehead overlaps the tilted head silhouette', () {
      const pose = SignPose(
        name: 'touch',
        left: ArmPose(shoulder: 138, elbow: 118, hand: HandShape.flat),
        right: ArmPose.resting,
        face: FacePose(headTilt: 8),
      );
      final joints = AvatarPainter.armOf(pose, -1);
      final hand = AvatarPainter.handUnitPath(
        pose.left,
        joints.wrist,
        joints.palmAngle,
        -1,
      );
      expect(
        AvatarPainter.contactShadow(hand, AvatarPainter.headUnitPath(pose)),
        isNotNull,
        reason: 'a brow hold should land its shadow on the head',
      );
    });

    test('an arm resting at the side casts nothing on the head', () {
      const pose = SignPose(
        name: 'rest',
        left: ArmPose.resting,
        right: ArmPose.resting,
        face: FacePose.neutral,
      );
      final joints = AvatarPainter.armOf(pose, -1);
      final hand = AvatarPainter.handUnitPath(
        pose.left,
        joints.wrist,
        joints.palmAngle,
        -1,
      );
      expect(
        AvatarPainter.contactShadow(hand, AvatarPainter.headUnitPath(pose)),
        isNull,
      );
    });
  });
}
