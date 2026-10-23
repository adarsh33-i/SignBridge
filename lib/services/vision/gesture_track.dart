import 'dart:math' as math;

import 'hand_frame.dart';

/// What the hand did between the first and the last frame of a clip.
///
/// Coordinates are already normalised to 0..1 by [HandFrame], so a travel of
/// 0.3 means three tenths of the frame width, whatever camera took the clip.
final class GestureTrack {
  const GestureTrack({required this.frames});

  final List<HandFrame> frames;

  static const empty = GestureTrack(frames: []);

  List<HandFrame> get _moving => frames.where((frame) => frame.found).toList();

  int get frameCount => frames.length;

  int get visibleFrameCount => _moving.length;

  /// Share of frames in which a hand was in shot at all.
  double get visibility {
    if (frames.isEmpty) {
      return 0;
    }
    return visibleFrameCount / frames.length;
  }

  Duration get duration {
    if (frames.length < 2) {
      return Duration.zero;
    }
    return frames.last.at.difference(frames.first.at);
  }

  double get meanCenterY => _mean(_moving.map((f) => f.centerY).toList());

  /// Finger strips the hand showed, averaged over the clip. One is a fist; two
  /// or more for most of it means the hand was open.
  double get meanFingerRuns =>
      _mean(_moving.map((f) => f.fingerRuns.toDouble()).toList());

  double get meanCoverage => _mean(_moving.map((f) => f.coverage).toList());

  double get yTravel => _travel(_moving.map((f) => f.centerY).toList());

  double get xTravel => _travel(_moving.map((f) => f.centerX).toList());

  /// Total distance the hand centre walked, in frame widths.
  double get pathLength {
    final moving = _moving;
    var total = 0.0;
    for (var i = 1; i < moving.length; i++) {
      final dx = moving[i].centerX - moving[i - 1].centerX;
      final dy = moving[i].centerY - moving[i - 1].centerY;
      total += math.sqrt(dx * dx + dy * dy);
    }
    return total;
  }

  /// Times the hand changed direction sideways. A wave is two.
  int get xSwings => _reversals(_moving.map((f) => f.centerX).toList());

  /// Times the hand changed direction up and down. A nod is two.
  int get ySwings => _reversals(_moving.map((f) => f.centerY).toList());

  /// Still means the hand never got anywhere, not that it never moved: a
  /// trembling hand walks a long path across a small box, and that box is what
  /// decides whether a sign was held or made.
  bool get isStill => visibleFrameCount < 3 || (xTravel < 0.1 && yTravel < 0.1);

  bool get hasHand => visibleFrameCount >= 3 && visibility >= 0.4;

  static double _mean(List<double> values) {
    if (values.isEmpty) {
      return 0;
    }
    var total = 0.0;
    for (final value in values) {
      total += value;
    }
    return total / values.length;
  }

  static double _travel(List<double> values) {
    if (values.length < 2) {
      return 0;
    }
    var low = values.first;
    var high = values.first;
    for (final value in values) {
      if (value < low) low = value;
      if (value > high) high = value;
    }
    return high - low;
  }

  /// Counts direction changes big enough to be a gesture rather than jitter.
  static int _reversals(List<double> values, {double amplitude = 0.07}) {
    if (values.length < 3) {
      return 0;
    }
    var direction = 0;
    var low = values.first;
    var high = values.first;
    var extreme = values.first;
    var reversals = 0;

    for (final value in values.skip(1)) {
      if (direction == 0) {
        if (value < low) low = value;
        if (value > high) high = value;
        if (high - low >= amplitude) {
          direction = value == high ? 1 : -1;
          extreme = value;
        }
        continue;
      }
      if (direction == 1) {
        if (value > extreme) {
          extreme = value;
        } else if (extreme - value >= amplitude) {
          reversals++;
          direction = -1;
          extreme = value;
        }
      } else {
        if (value < extreme) {
          extreme = value;
        } else if (value - extreme >= amplitude) {
          reversals++;
          direction = 1;
          extreme = value;
        }
      }
    }
    return reversals;
  }
}
