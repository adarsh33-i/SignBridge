import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:sign_bridge/services/avatar/rig/avatar_painter.dart';
import 'package:sign_bridge/services/avatar/rig/sign_library.dart';
import 'package:sign_bridge/services/avatar/rig/sign_pose.dart';
import 'package:sign_bridge/services/translate/sign_language_system.dart';
import 'package:sign_bridge/services/translate/sign_token.dart';

/// The shirt is a filled path, so whichever arm is painted under it loses that
/// part of the limb — a hand at the face came out detached from its own arm.
/// Both arms now go over the shirt, and the sleeve retracts off an arm that has
/// left the shoulder. These pin both, on rendered pixels rather than on the
/// geometry that produces them.
void main() {
  const size = 360;
  const shirt = <int>[215, 170, 182];
  const sleeveFront = <int>[207, 157, 171];
  const sleeveBack = <int>[201, 150, 165];

  Future<Uint8List> render(SignPose pose) async {
    final recorder = ui.PictureRecorder();
    AvatarPainter(pose: pose)
        .paint(ui.Canvas(recorder), const ui.Size(360.0, 360.0));
    final image = recorder.endRecording().toImageSync(size, size);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  /// Unit space to pixels, mirroring the canvas transform in
  /// [AvatarPainter.paint]: zoom 1.05 about (0.5, 1.16), top inset 0.032,
  /// face shift applied after the zoom.
  Offset toPixel(SignPose pose, Offset unit) => Offset(
        (0.5 + (unit.dx - 0.5) * 1.05 + pose.face.shift * 0.04) * size,
        (0.032 + 1.16 + (unit.dy - 1.16) * 1.05) * size,
      );

  bool isNear(List<int> rgb, List<int> want) =>
      (rgb[0] - want[0]).abs() <= 6 &&
      (rgb[1] - want[1]).abs() <= 6 &&
      (rgb[2] - want[2]).abs() <= 6;

  List<Offset> walk(Offset a, Offset b, int steps) =>
      [for (var s = 0; s <= steps; s++) a + (b - a) * (s / steps)];

  final ids = [
    'hello', 'thank_you', 'please', 'yes', 'no', 'good', 'bad', 'sorry', 'help',
    'mother', 'father', 'eat', 'water', 'home', 'name', 'where', 'go', 'come',
    'see', 'know', 'love', 'work', 'sleep', 'want', 'need', 'buy', 'money',
    'doctor', 'school', 'friend',
  ];

  test('no sign loses a limb to the shirt', () async {
    var checked = 0;
    for (final id in ids) {
      final anim = SignLibrary.forToken(
          SignToken(id: id, gloss: id, system: SignLanguageSystem.asl))!;
      for (var step = 0; step <= 10; step++) {
        final pose = anim
            .poseAt(Duration(milliseconds: (anim.totalMs * step / 10).round()));
        final bytes = await render(pose);
        for (final side in [-1.0, 1.0]) {
          if (!(side < 0 ? pose.left : pose.right).visible) continue;
          final arm = AvatarPainter.armOf(pose, side);
          for (final p in [
            ...walk(arm.elbow, arm.wrist, 16),
            ...walk(arm.wrist, arm.palmTop, 10),
          ]) {
            final q = toPixel(pose, p);
            if (q.dx < 1 || q.dy < 1 || q.dx > size - 2 || q.dy > size - 2) {
              continue;
            }
            final o = (q.dy.round() * size + q.dx.round()) * 4;
            final rgb = [bytes[o], bytes[o + 1], bytes[o + 2]];
            expect(isNear(rgb, shirt), isFalse,
                reason: '$id frame $step, side $side: the shirt is painted '
                    'over the limb at (${p.dx.toStringAsFixed(3)}, '
                    '${p.dy.toStringAsFixed(3)})');
            checked++;
          }
        }
      }
    }
    expect(checked, greaterThan(10000));
  });

  test('an arm hanging at the shoulder still wears its sleeve', () async {
    final pose = SignPose.resting;
    final bytes = await render(pose);
    for (final side in [-1.0, 1.0]) {
      final arm = AvatarPainter.armOf(pose, side);
      var onSleeve = 0;
      for (final p in walk(arm.shoulder, arm.elbow, 16)) {
        final q = toPixel(pose, p);
        final o = (q.dy.round() * size + q.dx.round()) * 4;
        final rgb = [bytes[o], bytes[o + 1], bytes[o + 2]];
        if (isNear(rgb, sleeveFront) || isNear(rgb, sleeveBack)) onSleeve++;
      }
      expect(onSleeve, greaterThan(4),
          reason: 'side $side lost its sleeve at rest');
    }
  });

  test('an arm folded up to the face wears nothing but skin', () async {
    final anim = SignLibrary.forToken(
        const SignToken(id: 'money', gloss: 'MONEY', system: SignLanguageSystem.asl))!;
    final pose = anim.poseAt(Duration(milliseconds: (anim.totalMs * 0.4).round()));
    final bytes = await render(pose);
    for (final side in [-1.0, 1.0]) {
      final arm = AvatarPainter.armOf(pose, side);
      var onSleeve = 0;
      for (final p in walk(arm.shoulder, arm.elbow, 16)) {
        final q = toPixel(pose, p);
        final o = (q.dy.round() * size + q.dx.round()) * 4;
        final rgb = [bytes[o], bytes[o + 1], bytes[o + 2]];
        if (isNear(rgb, sleeveFront) || isNear(rgb, sleeveBack)) onSleeve++;
      }
      expect(onSleeve, 0, reason: 'side $side still shows a sleeve pad');
    }
  });

  test('the sleeve retracts, it does not switch off', () async {
    var previous = -1;
    var worst = 0;
    for (var degrees = 8; degrees <= 140; degrees += 2) {
      final pose = SignPose.resting.copyWith(
        right: ArmPose(shoulder: degrees.toDouble(), elbow: 14),
      );
      final bytes = await render(pose);
      var count = 0;
      for (var i = 0; i < size * size; i++) {
        final o = i * 4;
        if (isNear([bytes[o], bytes[o + 1], bytes[o + 2]], sleeveFront) ||
            isNear([bytes[o], bytes[o + 1], bytes[o + 2]], sleeveBack)) {
          count++;
        }
      }
      if (previous >= 0) {
        final jump = (previous - count).abs();
        worst = jump > worst ? jump : worst;
      }
      previous = count;
    }
    expect(worst, lessThan(900),
        reason: 'a jump of $worst sleeve pixels between two frames is a pop');
  });
}
