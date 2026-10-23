import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sign_bridge/services/avatar/rig/avatar_painter.dart';
import 'package:sign_bridge/services/avatar/rig/fingerspell_shapes.dart';
import 'package:sign_bridge/services/avatar/rig/idle_layer.dart';
import 'package:sign_bridge/services/avatar/rig/sign_animation.dart';
import 'package:sign_bridge/services/avatar/rig/sign_library.dart';
import 'package:sign_bridge/services/avatar/rig/sign_pose.dart';
import 'package:sign_bridge/services/translate/sign_language_system.dart';
import 'package:sign_bridge/services/translate/sign_token.dart';

/// Visual harness for the 2D rig.
///
/// Goldens are the only way to check that a joint chain reads as an arm and a
/// curl value reads as a handshape, so each frame is pinned here. Regenerate
/// with `flutter test test/avatar/rig_render_test.dart --update-goldens`.
void main() {
  Widget frame(SignPose pose, {double size = 320}) {
    return MediaQuery(
      data: const MediaQueryData(devicePixelRatio: 1),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: CustomPaint(
          size: Size.square(size),
          painter: AvatarPainter(pose: pose),
        ),
      ),
    );
  }

  SignPose oneHand({
    required ArmPose right,
    ArmPose left = ArmPose.resting,
    FacePose face = FacePose.neutral,
    String name = 'pose',
  }) => SignPose(name: name, left: left, right: right, face: face);

  SignAnimation animationOf(String id) =>
      SignLibrary.forToken(
        SignToken(id: id, gloss: id.toUpperCase(), system: SignLanguageSystem.asl),
      )!;

  testWidgets('authored library signs at their peak frame', (tester) async {
    for (final id in [
      'thank_you',
      'eat',
      'name',
      'mother',
      'work',
      'friend',
    ]) {
      final animation = animationOf(id);
      final pose = animation.poseAt(
        Duration(milliseconds: (animation.totalMs * 0.5).round()),
      );
      await tester.pumpWidget(frame(pose));
      await expectLater(
        find.byType(CustomPaint),
        matchesGoldenFile('goldens/sign_$id.png'),
      );
    }
  });

  testWidgets('everyday conversation signs at their peak frame', (tester) async {
    // The words a live question is made of. ME is a body contact, HOW a
    // two-handed roll and TODAY a two-handed settle, so the pair is pinned at
    // the size a card renders it.
    for (final id in ['me', 'you', 'how', 'today']) {
      final animation = animationOf(id);
      final pose = animation.poseAt(
        Duration(milliseconds: (animation.totalMs * 0.5).round()),
      );
      await tester.pumpWidget(frame(pose));
      await expectLater(
        find.byType(CustomPaint),
        matchesGoldenFile('goldens/sign_$id.png'),
      );
    }
  });

  testWidgets('question markers change the whole face', (tester) async {
    // [wh-q] furrows, [y/n-q] raises. The difference has to read at card size
    // or question sentences look identical to statements.
    for (final id in ['nmm_whQ', 'nmm_ynQ']) {
      final animation = animationOf(id);
      final pose = animation.frames.last.pose;
      await tester.pumpWidget(frame(pose));
      await expectLater(
        find.byType(CustomPaint),
        matchesGoldenFile('goldens/face_$id.png'),
      );
    }
  });

  testWidgets('head-height signs keep the face readable', (tester) async {
    // Every sign that lifts a hand to head height can swing the forearm
    // inward and lay the fingers over the eyes, which erases the facial
    // grammar. Pin the first keyframe of each one that lives in that zone.
    for (final id in ['hello', 'father', 'home', 'see', 'know', 'sleep']) {
      final pose = animationOf(id).frames.first.pose;
      await tester.pumpWidget(frame(pose));
      await expectLater(
        find.byType(CustomPaint),
        matchesGoldenFile('goldens/face_$id.png'),
      );
    }
  });

  testWidgets('weather signs at their peak frame', (tester) async {
    // A weather caption runs four or five of these back to back, so each one
    // has to read as a different picture at card size. The mid frame is where
    // the hand is furthest into the face, which is the failure worth pinning.
    for (final id in [
      'rain',
      'snow',
      'wind',
      'windy',
      'cloud',
      'storm',
      'thunder',
      'lightning',
      'fog',
      'weather',
      'cold',
      'hot',
      'sun',
    ]) {
      final animation = animationOf(id);
      final pose = animation.poseAt(
        Duration(milliseconds: (animation.totalMs * 0.5).round()),
      );
      await tester.pumpWidget(frame(pose));
      await expectLater(
        find.byType(CustomPaint),
        matchesGoldenFile('goldens/weather_$id.png'),
      );
    }
  });

  testWidgets('fingerspelled unknown word mid-word', (tester) async {
    final animation = animationOf('zqx');
    final pose = animation.poseAt(
      Duration(milliseconds: (animation.totalMs * 0.6).round()),
    );
    await tester.pumpWidget(frame(pose));
    await expectLater(
      find.byType(CustomPaint),
      matchesGoldenFile('goldens/sign_fingerspell.png'),
    );
  });

  testWidgets('resting posture', (tester) async {
    await tester.pumpWidget(frame(SignPose.resting));
    await expectLater(
      find.byType(CustomPaint),
      matchesGoldenFile('goldens/rig_resting.png'),
    );
  });

  testWidgets('idle life: breath peak and resting smile on a still body', (tester) async {
    // Half a breath cycle in: chest lifted, eyes open, mouth settled into the
    // resting smile the player adds on top of every authored pose.
    final pose = IdleLayer.apply(SignPose.resting, IdleLayer.breathCycleMs ~/ 2);
    expect(pose.breath, closeTo(1.0, 0.001));
    await tester.pumpWidget(frame(pose));
    await expectLater(
      find.byType(CustomPaint),
      matchesGoldenFile('goldens/rig_breath.png'),
    );
  });

  testWidgets('idle life: mid-blink closes the eyes', (tester) async {
    final pose = IdleLayer.apply(
      SignPose.resting,
      IdleLayer.blinkCycleMs + IdleLayer.blinkOpenMs,
    );
    expect(pose.face.blink, closeTo(1.0, 0.001));
    await tester.pumpWidget(frame(pose));
    await expectLater(
      find.byType(CustomPaint),
      matchesGoldenFile('goldens/rig_blink.png'),
    );
  });

  testWidgets('hello: raised flat hand beside the temple', (tester) async {
    final pose = oneHand(
      name: 'hello',
      right: const ArmPose(
        shoulder: 118,
        elbow: 100,
        wrist: -14,
        lift: 0.3,
        hand: HandShape.flat,
      ),
      face: const FacePose(brow: 0.4, mouth: 0.35),
    );
    await tester.pumpWidget(frame(pose));
    await expectLater(
      find.byType(CustomPaint),
      matchesGoldenFile('goldens/rig_hello.png'),
    );
  });

  testWidgets('fingerspell A: fist with thumb up beside', (tester) async {
    final pose = oneHand(
      name: 'fsl-a',
      right: ArmPose(
        shoulder: 14,
        elbow: 196,
        wrist: -14,
        lift: 0.5,
        hand: FingerspellShapes.letters['a']!,
      ),
    );
    await tester.pumpWidget(frame(pose));
    await expectLater(
      find.byType(CustomPaint),
      matchesGoldenFile('goldens/rig_letter_a.png'),
    );
  });

  testWidgets('fingerspell V: two spread fingers', (tester) async {
    final pose = oneHand(
      name: 'fsl-v',
      right: ArmPose(
        shoulder: 10,
        elbow: 202,
        wrist: -8,
        lift: 0.55,
        hand: FingerspellShapes.letters['v']!,
      ),
    );
    await tester.pumpWidget(frame(pose));
    await expectLater(
      find.byType(CustomPaint),
      matchesGoldenFile('goldens/rig_letter_v.png'),
    );
  });

  testWidgets('fingers mid-curl fold over their own palm', (tester) async {
    // Halfway between an open hand and a fist. This is the frame every sign
    // passes through, so it is pinned: fingers must not splay out sideways.
    final pose = oneHand(
      name: 'mid-curl',
      right: const ArmPose(
        shoulder: 96,
        elbow: 150,
        wrist: -6,
        lift: 0.4,
        hand: HandShape(
          index: 0.5,
          middle: 0.5,
          ring: 0.5,
          pinky: 0.5,
          thumb: 0.45,
        ),
      ),
    );
    await tester.pumpWidget(frame(pose));
    await expectLater(
      find.byType(CustomPaint),
      matchesGoldenFile('goldens/rig_mid_curl.png'),
    );
  });

  testWidgets('back of hand: shade and outline, not palm lines', (tester) async {
    // `palm` is the only field that turns the hand over, and almost no
    // authored sign uses it, so this pins that branch: the back of the hand
    // gets a flatter, darker fill and no palm creases.
    final pose = oneHand(
      name: 'back-of-hand',
      right: const ArmPose(
        shoulder: 96,
        elbow: 150,
        wrist: -6,
        palm: 172,
        lift: 0.4,
        hand: HandShape.flat,
      ),
    );
    await tester.pumpWidget(frame(pose));
    await expectLater(
      find.byType(CustomPaint),
      matchesGoldenFile('goldens/rig_back_of_hand.png'),
    );
  });

  testWidgets('both arms up, pointing', (tester) async {
    final pose = SignPose(
      name: 'two-hand-point',
      left: const ArmPose(
        shoulder: 100,
        elbow: 132,
        wrist: 0,
        lift: 0.3,
        hand: HandShape.point,
      ),
      right: const ArmPose(
        shoulder: 100,
        elbow: 132,
        wrist: 0,
        lift: 0.3,
        hand: HandShape.point,
      ),
      face: const FacePose(headTurn: 0.6, brow: 0.5),
    );
    await tester.pumpWidget(frame(pose));
    await expectLater(
      find.byType(CustomPaint),
      matchesGoldenFile('goldens/rig_two_hand.png'),
    );
  });
}
