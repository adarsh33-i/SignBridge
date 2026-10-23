import 'package:flutter_test/flutter_test.dart';
import 'package:sign_bridge/services/vision/gesture_classifier.dart';
import 'package:sign_bridge/services/vision/gesture_track.dart';

import 'synthetic_hand_frames.dart';

GestureTrack _track(
  List<SyntheticHand> Function(int count) build, {
  double radius = 0.12,
  int count = 24,
}) => syntheticSession(build(count), radius: radius).track;

List<SyntheticHand> _path(
  double Function(int i) centerX,
  double Function(int i) centerY,
  bool open,
  int count,
) => [
  for (var i = 0; i < count; i++)
    (centerX: centerX(i), centerY: centerY(i), open: open),
];

/// Triangle wave over a period, in -1..1. Two periods give two reversals.
double _wave(int i, int period) {
  final phase = i % period;
  if (phase < period ~/ 2) {
    return phase / (period / 4) - 1;
  }
  return 1 - (phase - period ~/ 2) / (period / 4);
}

void main() {
  group('naming a gesture from its shape', () {
    test('an open hand waved at head height is HELLO', () {
      final track = _track(
        (n) => _path((i) => 0.5 + 0.18 * _wave(i, 8), (i) => 0.2, true, n),
      );
      final verdict = GestureClassifier.classify(track);

      expect(verdict.gloss, 'HELLO');
      expect(verdict.outcome, GestureOutcome.recognized);
      expect(verdict.confidence, greaterThanOrEqualTo(0.65));
    });

    test('a hand bobbed up and down at chest height is YES', () {
      final track = _track(
        (n) => _path((i) => 0.5, (i) => 0.5 + 0.14 * _wave(i, 8), false, n),
      );

      expect(GestureClassifier.classify(track).gloss, 'YES');
    });

    test('a hand shaken side to side at chest height is NO', () {
      final track = _track(
        (n) => _path((i) => 0.5 + 0.18 * _wave(i, 8), (i) => 0.5, false, n),
      );

      expect(GestureClassifier.classify(track).gloss, 'NO');
    });

    test('an open palm held still at chest height is STOP', () {
      final track = _track(
        (n) => _path((i) => 0.5, (i) => 0.5, true, n),
        radius: 0.16,
        count: 20,
      );

      expect(GestureClassifier.classify(track).gloss, 'STOP');
    });

    test('an open hand circling at chest height is PLEASE', () {
      final track = _track(
        (n) => _path(
          (i) => 0.5 + 0.15 * _wave(i, 10),
          (i) => 0.5 + 0.15 * _wave(i + 5, 10),
          true,
          n,
        ),
        radius: 0.14,
      );

      expect(GestureClassifier.classify(track).gloss, 'PLEASE');
    });
  });

  group('refusing to name a gesture', () {
    test('no hand in frame is reported as nothing seen', () {
      final track = _track(
        (n) => _path((i) => 5, (i) => 5, false, n),
        count: 20,
      );
      final verdict = GestureClassifier.classify(track);

      expect(verdict.gloss, isNull);
      expect(verdict.outcome, GestureOutcome.nothingSeen);
    });

    test('a closed fist held still is not read as a STOP palm', () {
      // The openness feature is what separates these two. If it drifts, this
      // is the case that flips first, and a still fist would be announced as
      // "Stop".
      final track = _track(
        (n) => _path((i) => 0.5, (i) => 0.5, false, n),
        radius: 0.16,
        count: 20,
      );
      final verdict = GestureClassifier.classify(track);

      expect(track.meanFingerRuns, lessThan(2.5));
      expect(verdict.gloss, isNull);
      expect(verdict.outcome, GestureOutcome.heldStill);
    });

    test('an open hand shows finger gaps a fist cannot make', () {
      final openTrack = _track(
        (n) => _path((i) => 0.5, (i) => 0.5, true, n),
        count: 12,
      );
      final fistTrack = _track(
        (n) => _path((i) => 0.5, (i) => 0.5, false, n),
        count: 12,
      );

      expect(openTrack.meanFingerRuns, greaterThanOrEqualTo(3));
      expect(fistTrack.meanFingerRuns, lessThan(2));
    });

    test('a shape no rule matches names no gloss', () {
      // One long sideways drag: it travels, but never swings back.
      final track = _track(
        (n) => _path((i) => 0.2 + 0.6 * i / n, (i) => 0.5, false, n),
        count: 20,
      );
      final verdict = GestureClassifier.classify(track);

      expect(verdict.outcome, isNot(GestureOutcome.recognized));
      expect(verdict.gloss, isNull);
      expect(track.xSwings, lessThan(2));
    });

    test('every verdict says what it measured', () {
      final track = _track(
        (n) => _path((i) => 0.5 + 0.18 * _wave(i, 8), (i) => 0.2, true, n),
      );
      final verdict = GestureClassifier.classify(track);

      expect(verdict.detail, contains('xSwings='));
      expect(verdict.detail, contains('runs='));
    });
  });

  group('the track measures motion, not pixels', () {
    test('two sideways sweeps count as two reversals', () {
      final track = _track(
        (n) => _path((i) => 0.5 + 0.18 * _wave(i, 8), (i) => 0.5, false, n),
        count: 24,
      );

      expect(track.xSwings, greaterThanOrEqualTo(2));
      expect(track.ySwings, 0);
    });

    test('jitter smaller than the swing floor is not a swing', () {
      final track = _track(
        (n) =>
            _path((i) => 0.5 + (i.isEven ? 0.02 : -0.02), (i) => 0.5, false, n),
        count: 24,
      );

      expect(track.xSwings, 0);
      expect(track.isStill, isTrue);
    });

    test('a hand present in every frame is fully visible', () {
      final track = _track(
        (n) => _path((i) => 0.5, (i) => 0.5, false, n),
        count: 10,
      );

      expect(track.visibility, 1);
      expect(track.hasHand, isTrue);
      expect(track.duration, const Duration(milliseconds: 900));
    });

    test('an empty track has no hand and no duration', () {
      expect(GestureTrack.empty.hasHand, isFalse);
      expect(GestureTrack.empty.pathLength, 0);
      expect(GestureTrack.empty.duration, Duration.zero);
    });
  });
}
