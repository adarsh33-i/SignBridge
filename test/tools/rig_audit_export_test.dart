import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:sign_bridge/services/avatar/rig/avatar_painter.dart';
import 'package:sign_bridge/services/avatar/rig/fingerspell_shapes.dart';
import 'package:sign_bridge/services/avatar/rig/sign_animation.dart';
import 'package:sign_bridge/services/avatar/rig/sign_library.dart';
import 'package:sign_bridge/services/avatar/rig/sign_pose.dart';

/// Exports the authored rig to JSON so the landing audit can compare it with
/// the ASL landmark corpus.
///
/// Every number comes from the painter itself — `armOf`, `digitBones`,
/// `handUnitPath`, `headUnitPath` — rather than re-derived here, so the audit
/// cannot drift from what the avatar actually draws.
///
/// Run explicitly:
///   RIG_AUDIT_OUT=build/audit flutter test test/tools/rig_audit_export_test.dart
///
/// Normal runs skip it, because it writes a file rather than asserting anything.
void main() {
  final outDir = Platform.environment['RIG_AUDIT_OUT'];
  if (outDir == null || outDir.isEmpty) {
    test('rig audit export needs an output directory', () {
      expect(Platform.environment['RIG_AUDIT_OUT'], anyOf(isNull, isEmpty));
    });
    return;
  }

  test('export authored rig', () {
    final anchor = AvatarPainter.armOf(SignPose.resting, 1);
    final other = AvatarPainter.armOf(SignPose.resting, -1);
    final head = AvatarPainter.headUnitPath(SignPose.resting).getBounds();

    final json = <String, Object?>{
      'version': 1,
      'space': 'unit canvas, min axis = 1, origin top-left, y down',
      'rig': {
        'shoulderMid': [
          (anchor.shoulder.dx + other.shoulder.dx) / 2,
          (anchor.shoulder.dy + other.shoulder.dy) / 2,
        ],
        'shoulderWidth': anchor.shoulder.dx - other.shoulder.dx,
        'headCenter': [head.center.dx, head.center.dy],
        'headRadius': head.width / 2,
        'digitNames': ['index', 'middle', 'ring', 'pinky', 'thumb'],
        'jointNames': ['base', 'knuckle', 'tip'],
      },
      'signs': {
        for (final entry in SignLibrary.debugCore.entries)
          entry.key: _signJson(entry.value),
      },
      'letters': {
        for (final entry in FingerspellShapes.letters.entries)
          entry.key: {
            'hand': entry.value.toJson(),
            'sides': {
              'right': _letterJson(entry.value, 1),
              'left': _letterJson(entry.value, -1),
            },
          },
      },
    };

    final file = File('$outDir/avatar_rig.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(const JsonEncoder.withIndent(' ').convert(json));
    expect(file.existsSync(), isTrue);
    // ignore: avoid_print
    print('wrote ${file.path} (${file.lengthSync()} bytes)');
  });
}

Map<String, Object?> _signJson(SignAnimation animation) => {
  'id': animation.id,
  'gloss': animation.gloss,
  'totalMs': animation.totalMs,
  'faceOnly': animation.faceOnly,
  'frames': [
    for (var i = 0; i < animation.frames.length; i++)
      _frameJson(i, animation.frames[i]),
  ],
};

Map<String, Object?> _frameJson(int index, PoseKey key) => {
  'index': index,
  'travelMs': key.travelMs,
  'holdMs': key.holdMs,
  'left': _armJson(key.pose, -1),
  'right': _armJson(key.pose, 1),
  'face': key.pose.face.toJson(),
};

Map<String, Object?> _armJson(SignPose pose, double side) {
  final arm = side < 0 ? pose.left : pose.right;
  final joints = AvatarPainter.armOf(pose, side);
  final local = AvatarPainter.digitBones(arm.hand, side);
  final rotation = -degrees(joints.palmAngle);
  final c = math.cos(rotation);
  final s = math.sin(rotation);
  Offset toUnit(Offset p) => Offset(
    joints.wrist.dx + p.dx * c - p.dy * s,
    joints.wrist.dy + p.dx * s + p.dy * c,
  );
  final hand = AvatarPainter.handUnitPath(
    arm,
    joints.wrist,
    joints.palmAngle,
    side,
  ).getBounds();

  return {
    'visible': arm.visible,
    'shoulder': [joints.shoulder.dx, joints.shoulder.dy],
    'elbow': [joints.elbow.dx, joints.elbow.dy],
    'wrist': [joints.wrist.dx, joints.wrist.dy],
    'palmTop': [joints.palmTop.dx, joints.palmTop.dy],
    'palmAngle': joints.palmAngle,
    'palmFacing': 1 - arm.palm.abs().clamp(0, 180) / 180,
    'hand': arm.hand.toJson(),
    // Joint centre-lines in unit space, transformed exactly as `_paintHand`
    // transforms them: wrist translate then palm-angle rotate.
    'digits': [
      for (final chain in local)
        [
          for (final p in chain)
            [toUnit(p).dx, toUnit(p).dy],
        ],
    ],
    'handBounds': [
      hand.left,
      hand.top,
      hand.right,
      hand.bottom,
    ],
  };
}

Map<String, Object?> _letterJson(HandShape hand, double side) => {
  // Letters are compared by shape, not placement, so hand-local space (wrist
  // at the origin) is enough.
  'digits': [
    for (final chain in AvatarPainter.digitBones(hand, side))
      [
        for (final p in chain) [p.dx, p.dy],
      ],
  ],
};
