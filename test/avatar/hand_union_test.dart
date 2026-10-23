import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:sign_bridge/services/avatar/rig/avatar_painter.dart';

/// The hand is painted as one boolean union of the palm and five digits, so the
/// rig only reads as a hand if `Path.combine` actually merges the parts.
///
/// It silently declines to. When the digit tip cap was built with
/// `arcTo(..., useCenter: true)` the contour crossed itself, the union came back
/// as five separate shapes, each finger kept its own navy outline, and on the
/// ~284-pixel card those outlines were the reported "gaps between the fingers".
/// Nothing threw and the 2400-pixel goldens looked fine, so the invariant is
/// pinned here instead.
void main() {
  /// A finger: 50 units wide, 300 long, running up from the origin.
  ui.Path digit({double x = 0}) => AvatarPainter.taperedPath([
        Offset(x, 0),
        Offset(x, -150),
        Offset(x, -280),
      ], [25, 25, 24]);

  /// Points that must be inside a finger's own silhouette: the shaft, the two
  /// shoulders of the round cap, and the cap's crown. A self-intersecting
  /// contour loses the crown first.
  final inside = [
    const Offset(0, -20),
    const Offset(18, -150),
    const Offset(-18, -150),
    const Offset(14, -288),
    const Offset(-14, -288),
    const Offset(0, -296),
    const Offset(0, -302),
    const Offset(8, -300),
  ];

  test('a digit contour is simple enough to fill right through its tip', () {
    for (final p in inside) {
      expect(
        digit().contains(p),
        isTrue,
        reason: 'tip point $p fell out of the finger fill',
      );
    }
  });

  test('unioning two overlapping digits keeps every point of both', () {
    final a = digit();
    final b = digit(x: 32);
    final merged = ui.Path.combine(ui.PathOperation.union, a, b);

    for (final p in inside) {
      expect(
        merged.contains(p),
        isTrue,
        reason: 'the union dropped a point of the first digit at $p',
      );
      expect(
        merged.contains(p + const Offset(32, 0)),
        isTrue,
        reason: 'the union dropped a point of the second digit at $p',
      );
    }
  });

  test('unioning a digit with itself does not change it', () {
    final a = digit();
    final merged = ui.Path.combine(ui.PathOperation.union, a, a);
    for (final p in inside) {
      expect(
        merged.contains(p),
        a.contains(p),
        reason: 'a self-union rewrote the contour at $p',
      );
    }
  });
}
