import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sign_bridge/features/home/presentation/widgets/vector_sign_avatar.dart';
import 'package:sign_bridge/services/avatar/rig/avatar_painter.dart';
import 'package:sign_bridge/services/avatar/rig/idle_layer.dart';
import 'package:sign_bridge/services/avatar/rig/sign_pose.dart';
import 'package:sign_bridge/services/avatar/rig/sign_timeline.dart';
import 'package:sign_bridge/services/translate/sign_language_system.dart';
import 'package:sign_bridge/services/translate/sign_token.dart';

/// Wiring checks for the player: the widget is the only place the timeline and
/// the idle layer meet, so that is where the composed pose gets verified.
void main() {
  const hello = SignToken(id: 'hello', gloss: 'HELLO', system: SignLanguageSystem.asl);
  const yes = SignToken(id: 'yes', gloss: 'YES', system: SignLanguageSystem.asl);

  Widget player(List<SignToken> sequence) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 320,
          height: 320,
          child: VectorSignAvatar(sequence: sequence),
        ),
      ),
    ),
  );

  AvatarPainter painter(WidgetTester tester) => tester
      .widget<CustomPaint>(find.descendant(
        of: find.byType(VectorSignAvatar),
        matching: find.byType(CustomPaint),
      ))
      .painter! as AvatarPainter;

  testWidgets('a placeholder token leaves the rig at rest', (tester) async {
    await tester.pumpWidget(player(const [SignToken.thinking]));
    final pose = painter(tester).pose;
    expect(pose.right.shoulder, ArmPose.resting.shoulder);
    expect(pose.name, 'rest');
  });

  testWidgets('the pose advances with the timeline', (tester) async {
    await tester.pumpWidget(player(const [hello]));
    await tester.pump(const Duration(milliseconds: 20));
    final early = painter(tester).pose;
    await tester.pump(const Duration(milliseconds: 400));
    final later = painter(tester).pose;

    expect(later.right.shoulder, isNot(early.right.shoulder));
    // The idle smile rides on top of every authored pose.
    expect(early.face.smile, greaterThan(0));
  });

  testWidgets('idle life runs on the ticker clock, not the loop position',
      (tester) async {
    await tester.pumpWidget(player(const [yes]));
    await tester.pump(const Duration(milliseconds: 30));

    var blinkFrames = 0;
    var maxBlink = 0.0;
    var blinks = 0;
    var wasShut = false;
    var lowestBreath = 1.0;
    var highestBreath = 0.0;
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      final pose = painter(tester).pose;
      final shut = pose.face.blink > 0.5;
      if (shut && !wasShut) blinks++;
      wasShut = shut;
      if (shut) blinkFrames++;
      if (pose.face.blink > maxBlink) maxBlink = pose.face.blink;
      if (pose.breath < lowestBreath) lowestBreath = pose.breath;
      if (pose.breath > highestBreath) highestBreath = pose.breath;
    }

    // A short sign loop restarts every second or so; the blink must not.
    expect(maxBlink, greaterThan(0.5), reason: 'one blink per ${IdleLayer.blinkCycleMs}ms');
    expect(blinks, inInclusiveRange(1, 3), reason: 'about ten seconds of idle');
    expect(blinkFrames, lessThan(30), reason: 'a blink is rare, not a squint');
    expect(highestBreath - lowestBreath, greaterThan(0.5));
  });

  group('a caption plays once and the chip follows it', () {
    const rain = SignToken(id: 'rain', gloss: 'RAIN', system: SignLanguageSystem.asl);

    Widget signed(
      List<SignToken> sequence,
      List<String?> reported,
    ) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            height: 320,
            child: VectorSignAvatar(
              sequence: sequence,
              onGlossChanged: reported.add,
            ),
          ),
        ),
      ),
    );

    /// Advances the fake clock in frame-sized steps.
    ///
    /// One `pump` of a large duration fires the ticker once, so the whole run
    /// collapses into a single jump and nothing in between is ever observed.
    Future<void> play(WidgetTester tester, int ms, {int step = 50}) async {
      for (var i = 0; i < ms; i += step) {
        await tester.pump(Duration(milliseconds: step));
      }
    }

    testWidgets('the run ends at rest and stays there', (tester) async {
      final total = SignTimeline.of(const [hello, yes]).totalMs;
      await tester.pumpWidget(signed(const [hello, yes], <String?>[]));

      await play(tester, total + 100);
      final settled = painter(tester).pose;
      expect(settled.right.shoulder, ArmPose.resting.shoulder);
      expect(settled.name, 'rest');

      // Five more seconds must not lift a hand again.
      await play(tester, 5000, step: 250);
      final later = painter(tester).pose;
      expect(later.right.shoulder, ArmPose.resting.shoulder);
      expect(later.right.elbow, ArmPose.resting.elbow);
      expect(later.left.shoulder, ArmPose.resting.shoulder);
    });

    testWidgets('the body still breathes and blinks after the run ends',
        (tester) async {
      final total = SignTimeline.of(const [hello]).totalMs;
      await tester.pumpWidget(signed(const [hello], <String?>[]));
      await play(tester, total + 100);

      var blinks = 0;
      var wasShut = false;
      var lowestBreath = 1.0;
      var highestBreath = 0.0;
      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        final pose = painter(tester).pose;
        final shut = pose.face.blink > 0.5;
        if (shut && !wasShut) blinks++;
        wasShut = shut;
        if (pose.breath < lowestBreath) lowestBreath = pose.breath;
        if (pose.breath > highestBreath) highestBreath = pose.breath;
      }
      expect(blinks, greaterThan(0), reason: 'idle life outlives the caption');
      expect(highestBreath - lowestBreath, greaterThan(0.5));
    });

    testWidgets('the chip names each gloss as the hands reach it, then clears',
        (tester) async {
      final reported = <String?>[];
      await tester.pumpWidget(signed(const [hello, yes, rain], reported));

      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(reported, containsAllInOrder(['HELLO', 'YES', 'RAIN']));
      expect(reported.last, isNull, reason: 'settled means nothing is signing');
      expect(
        reported.where((g) => g != null).toSet(),
        {'HELLO', 'YES', 'RAIN'},
        reason: 'no gloss the caption never contained',
      );
    });

    testWidgets('a gloss appended mid-run is signed next, not replayed from one',
        (tester) async {
      final reported = <String?>[];
      final firstTotal = SignTimeline.of(const [hello]).totalMs;
      await tester.pumpWidget(signed(const [hello], reported));
      // Land inside the first caption so a rewind is distinguishable from a
      // continuation: replaying HELLO would take another whole firstTotal.
      await play(tester, firstTotal - 150);
      expect(reported.last, 'HELLO');

      await tester.pumpWidget(signed(const [hello, yes], reported));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(
        reported,
        containsAllInOrder(['HELLO', 'YES']),
        reason: 'the new word follows without re-signing the old',
      );
      expect(
        reported.where((g) => g == 'HELLO').length,
        1,
        reason: 'a caption that only grew must not restart',
      );
    });

    testWidgets('a different caption restarts from its first gloss',
        (tester) async {
      final reported = <String?>[];
      final total = SignTimeline.of(const [hello]).totalMs;
      await tester.pumpWidget(signed(const [hello], reported));
      await play(tester, total + 100);
      expect(reported.last, isNull);

      await tester.pumpWidget(signed(const [rain], reported));
      await tester.pump(const Duration(milliseconds: 50));

      expect(reported.last, 'RAIN');
      await play(tester, 250);
      expect(
        painter(tester).pose.right.shoulder,
        isNot(ArmPose.resting.shoulder),
        reason: 'a new caption must start moving, not stay at rest',
      );
    });
  });
}
