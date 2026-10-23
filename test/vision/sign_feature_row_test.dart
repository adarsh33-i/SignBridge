/// The device feature row, pinned against the row the extractor wrote.
///
/// `training/video/export_row_parity.py` generates `row_parity.txt` by running
/// `extract_tracks._body_frame` and `_hand_block` - the code that made the
/// training corpus - on raw landmark points, and checks per case that the
/// shoulder-framed route through `video_corpus.wrist_frame` agrees with the
/// direct no-pose route. What is left to prove is that Dart implements the same
/// rule, because an app that builds a slightly different row scores an embedding
/// no accuracy number was ever measured on.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sign_bridge/services/vision/sign_feature_row.dart';

const _fixture = 'test/fixtures/video_match/row_parity.txt';

/// Float32 arithmetic is what the extractor writes, so that is the error budget
/// a reimplementation is allowed - plus the six decimals the fixture prints.
const _tolerance = 1e-5;

class _Case {
  _Case(this.label, this.left, this.right, this.row);

  final String label;
  final Float32List? left;
  final Float32List? right;
  final Float32List row;
}

List<_Case> _cases() {
  final lines = File(_fixture)
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty && !line.startsWith('#'))
      .toList();
  final out = <_Case>[];
  for (var index = 0; index + 3 < lines.length; index += 4) {
    if (!lines[index].startsWith('case ')) {
      throw StateError(
        'the fixture is case, left hand, right hand, row; got ${lines[index]}',
      );
    }
    final header = lines[index].split(' ');
    Float32List? parse(String line) {
      final parts = line.split(' ');
      if (parts.length == 2 && parts[1] == '-') return null;
      if (parts.first != 'hand' && parts.first != 'row') {
        throw StateError('expected a hand or row line, got $line');
      }
      return Float32List.fromList(parts.skip(1).map(double.parse).toList());
    }

    out.add(
      _Case(
        '${header[1]} ${header[3]} ${header[4]}',
        parse(lines[index + 1]),
        parse(lines[index + 2]),
        parse(lines[index + 3])!,
      ),
    );
  }
  return out;
}

/// A hand of [points] laid out at [x], [y], rotated by [roll] and scaled.
Float32List _hand(
  double x,
  double y, {
  double palm = 0.09,
  double span = 0.2,
  double roll = 0.5,
}) {
  final points = Float32List(SignFeatureRow.coordinates);
  void put(int index, double dx, double dy) {
    final cos = math.cos(roll), sin = math.sin(roll);
    points[index * 2] = x + dx * cos - dy * sin;
    points[index * 2 + 1] = y + dx * sin + dy * cos;
  }

  put(SignFeatureRow.wrist, 0, 0);
  put(SignFeatureRow.middleMcp, palm, 0);
  for (var finger = 0; finger < 21; finger++) {
    if (points[finger * 2] == 0 &&
        points[finger * 2 + 1] == 0 &&
        finger != SignFeatureRow.wrist) {
      put(finger, palm * 0.5, 0);
    }
  }
  put(SignFeatureRow.indexMcp, palm, 0.05);
  put(SignFeatureRow.pinkyMcp, palm, -0.05);
  for (var step = 0; step < SignFeatureRow.fingertips.length; step++) {
    put(SignFeatureRow.fingertips[step], palm + span, (step - 1.5) * 0.04);
  }
  return points;
}

void main() {
  final cases = _cases();

  test('the fixture covers every state the rule branches on', () {
    expect(cases.length, greaterThan(100));
    final counts = cases
        .map((entry) => entry.row[SignFeatureRow.handCount])
        .toSet();
    expect(counts, containsAll(<double>[0.0, 1.0, 2.0]));
  });

  test('the Dart row matches the row the extractor wrote, on every case', () {
    var worst = 0.0;
    var worstAt = '';
    var offBy = 0;
    for (final entry in cases) {
      final built = SignFeatureRow.build(left: entry.left, right: entry.right);
      expect(
        built.length,
        SignFeatureRow.featuresPerFrame,
        reason: entry.label,
      );
      for (var column = 0; column < built.length; column++) {
        final difference = (built[column] - entry.row[column]).abs();
        if (difference > worst) {
          worst = difference;
          worstAt = '${entry.label} column $column';
        }
        if (difference > _tolerance) offBy++;
      }
    }
    expect(offBy, 0, reason: 'worst difference $worst at $worstAt');
  });

  test(
    'a frame the phone cannot anchor is the all-zero row training expects',
    () {
      final absent = cases.firstWhere(
        (entry) => entry.row[SignFeatureRow.handCount] == 0.0,
      );
      final built = SignFeatureRow.build(
        left: absent.left,
        right: absent.right,
      );
      expect(built.any((value) => value != 0.0), isFalse);
    },
  );

  test('a dropped hand stops setting the ruler for the hand that stays', () {
    final good = _hand(0.3, 0.4);
    // Knuckle collapsed onto the wrist, span unchanged: not a small hand, a bad
    // detection, so it must not become half of the row's unit of length.
    final collapsed = _hand(0.8, 0.6, palm: 0.004);
    final alone = SignFeatureRow.build(left: good);
    final paired = SignFeatureRow.build(left: good, right: collapsed);
    expect(paired[SignFeatureRow.handCount], 1.0);
    for (var column = 0; column < SignFeatureRow.coordinates; column++) {
      expect(paired[column], closeTo(alone[column], 1e-12));
    }
    expect(
      paired[SignFeatureRow.handBlock + SignFeatureRow.presentOffset],
      0.0,
    );
    expect(
      paired
          .sublist(
            SignFeatureRow.handBlock,
            SignFeatureRow.handBlock + SignFeatureRow.coordinates,
          )
          .every((value) => value == 0.0),
      isTrue,
    );
  });

  test('the row does not move when the signer does', () {
    final near = _hand(0.25, 0.30);
    final far = Float32List(SignFeatureRow.coordinates);
    // Backed away from the camera and turned to the other side of the frame: the
    // hand is half as long and sits somewhere else, so the frame has to absorb it.
    for (var point = 0; point < SignFeatureRow.coordinates; point += 2) {
      far[point] = 0.5 + (near[point] - 0.25) * 0.5;
      far[point + 1] = 0.75 + (near[point + 1] - 0.30) * 0.5;
    }
    final a = SignFeatureRow.build(left: near);
    final b = SignFeatureRow.build(left: far);
    for (var column = 0; column < SignFeatureRow.coordinates; column++) {
      expect(b[column], closeTo(a[column], 1e-6));
    }
    expect(
      b[SignFeatureRow.spreadOffset],
      closeTo(a[SignFeatureRow.spreadOffset], 1e-6),
    );
  });

  test('a window arrives after 16 frames and then every 8', () {
    final feed = SignWindowFeed();
    final row = SignFeatureRow.build(left: _hand(0.3, 0.4));
    var emitted = 0;
    for (var frame = 1; frame <= 40; frame++) {
      final window = feed.push(row);
      if (window == null) continue;
      emitted++;
      expect(window.length, 16 * SignFeatureRow.featuresPerFrame);
      expect(feed.mask.length, 16);
      expect(window.sublist(0, 94), row);
    }
    expect(emitted, 4); // frames 16, 24, 32, 40
  });

  test('the feed refuses a row that is not the training width', () {
    expect(() => SignWindowFeed().push(Float32List(93)), throwsArgumentError);
  });

  test('reset means the next sentence does not inherit the last window', () {
    final feed = SignWindowFeed();
    for (var frame = 0; frame < 15; frame++) {
      feed.push(SignFeatureRow.build(left: _hand(0.3, 0.4)));
    }
    feed.reset();
    expect(feed.push(SignFeatureRow.build(left: _hand(0.3, 0.4))), isNull);
  });
}
