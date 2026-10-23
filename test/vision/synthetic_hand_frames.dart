import 'dart:typed_data';

import 'package:sign_bridge/services/vision/camera_frame_reader.dart';
import 'package:sign_bridge/services/vision/sign_gesture_session.dart';

/// One frame of a synthetic hand.
typedef SyntheticHand = ({double centerX, double centerY, bool open});

/// A skin-coloured pixel that satisfies the chroma rule in `SkinMask`.
const List<int> _skin = [200, 150, 120];

/// A cool background pixel that fails it.
const List<int> _wall = [30, 60, 140];

/// Draws one hand on a grid, centred at a normalised point.
///
/// A closed fist is a filled disc. An open hand is a palm block with four
/// separated fingers above it, joined to the palm so the whole shape is one
/// blob: rows above the palm have gaps in them, which is the only thing the
/// openness feature can look at.
FrameGrid syntheticHand(
  SyntheticHand hand, {
  int width = 80,
  int height = 60,
  double radius = 0.12,
}) {
  final rgbx = Uint8List(width * height * 4);
  for (var i = 0; i < width * height; i++) {
    rgbx[i * 4] = _wall[0];
    rgbx[i * 4 + 1] = _wall[1];
    rgbx[i * 4 + 2] = _wall[2];
    rgbx[i * 4 + 3] = 255;
  }

  void paint(int x, int y) {
    if (x < 0 || y < 0 || x >= width || y >= height) {
      return;
    }
    final i = (y * width + x) * 4;
    rgbx[i] = _skin[0];
    rgbx[i + 1] = _skin[1];
    rgbx[i + 2] = _skin[2];
  }

  void paintRow(int y, int left, int right) {
    for (var x = left; x <= right; x++) {
      paint(x, y);
    }
  }

  final cx = hand.centerX * width;
  final cy = hand.centerY * height;
  final r = radius * width;

  if (!hand.open) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final dx = x + 0.5 - cx;
        final dy = y + 0.5 - cy;
        if (dx * dx + dy * dy <= r * r) {
          paint(x, y);
        }
      }
    }
    return FrameGrid(width: width, height: height, rgbx: rgbx);
  }

  // Two cells wide with two cells of daylight between them: a fist can never
  // make four strips out of one row.
  const fingerSpacing = 4.0;
  const fingerHalfWidth = 1.0;
  for (var finger = 0; finger < 4; finger++) {
    final fx = cx + (finger - 1.5) * fingerSpacing;
    final left = (fx - fingerHalfWidth).round();
    for (var y = (cy - r * 1.3).round(); y <= (cy + r * 0.15).round(); y++) {
      paintRow(y, left, left + 1);
    }
  }
  final palmHalf = (1.5 * fingerSpacing + 2).round();
  for (var y = cy.round(); y <= (cy + r * 0.6).round(); y++) {
    paintRow(y, (cx - palmHalf).round(), (cx + palmHalf).round());
  }
  return FrameGrid(width: width, height: height, rgbx: rgbx);
}

/// Feeds a path of synthetic hands into a session, 10 frames a second.
SignGestureSession syntheticSession(
  List<SyntheticHand> path, {
  double radius = 0.12,
  int startMilliseconds = 0,
}) {
  final session = SignGestureSession();
  var at = DateTime.fromMillisecondsSinceEpoch(1700000000000);
  for (var i = 0; i < startMilliseconds; i++) {
    at = at.add(const Duration(milliseconds: 100));
  }
  for (final hand in path) {
    session.addGrid(syntheticHand(hand, radius: radius), at: at);
    at = at.add(const Duration(milliseconds: 100));
  }
  return session;
}
