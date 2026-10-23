import 'dart:math' as math;
import 'dart:typed_data';

/// One camera frame of hand landmarks, turned into the 94 numbers the encoder eats.
///
/// The training corpus and the phone have to write the same row from the same
/// hand, because the accept margin was measured on rows built this way. That
/// makes this file a reimplementation of `extract_tracks._body_frame` and
/// `_hand_block` without the body frame, and `test/vision/sign_feature_row_test.dart`
/// pins it against a fixture the extractor itself generated.
///
/// The frame is built from the hands alone, so it is scale-free: the origin is
/// the mean wrist and the unit of length is 2.6 times the mean wrist-to-middle
/// knuckle of exactly the hands written into the row. A hand whose knuckle
/// collapsed onto its wrist is dropped rather than divided by, and a dropped hand
/// stops anchoring the frame - if it still set the ruler, the hand that stayed
/// would land somewhere the phone's own row never goes.
class SignFeatureRow {
  SignFeatureRow._();

  /// Floats per frame: two hands of (21 points, spread, roll sin, roll cos,
  /// present), then pose-present and the detected hand count.
  static const featuresPerFrame = 94;
  static const handBlock = 46;
  static const coordinates = 42;
  static const wrist = 0;
  static const middleMcp = 9;
  static const indexMcp = 5;
  static const pinkyMcp = 17;
  static const spreadOffset = 42;
  static const rollSinOffset = 43;
  static const rollCosOffset = 44;
  static const presentOffset = 45;
  static const posePresent = 92;
  static const handCount = 93;

  /// The fingertip landmarks the spread is measured from.
  static const fingertips = [8, 12, 16, 20];

  /// A wrist-to-knuckle this far under the hand's own fingertip span is a
  /// collapsed detection, not a small hand; `video_corpus.MIN_PALM_FRACTION`.
  static const minPalmFraction = 0.05;

  /// [left] and [right] are 42 floats of normalised image coordinates - x, y for
  /// the 21 MediaPipe landmarks in order - or null when no hand was reported for
  /// that slot. Handedness comes from the landmarker, which labels the hand in
  /// the mirrored preview, so the caller decides the slot the same way
  /// `_slots` does: a label starting with "left" takes the first block.
  static Float32List build({Float32List? left, Float32List? right}) {
    final row = Float32List(featuresPerFrame);
    final hands = [left, right];
    final palms = [
      for (final hand in hands)
        hand == null ? 0.0 : _distance(hand, wrist, middleMcp),
    ];
    // Both distances are inside one hand, so this test says the same thing at any
    // camera distance and any frame width.
    final usable = [
      for (var index = 0; index < 2; index++)
        hands[index] != null &&
            palms[index] > 0.0 &&
            palms[index] >= minPalmFraction * _span(hands[index]!),
    ];
    var count = 0;
    for (final ok in usable) {
      if (ok) count++;
    }
    if (count == 0) return row;

    var originX = 0.0, originY = 0.0, length = 0.0;
    for (var index = 0; index < 2; index++) {
      if (!usable[index]) continue;
      originX += hands[index]![wrist * 2];
      originY += hands[index]![wrist * 2 + 1];
      length += palms[index];
    }
    originX /= count;
    originY /= count;
    final scale = 2.6 * length / count;

    for (var index = 0; index < 2; index++) {
      final start = index * handBlock;
      row[start + presentOffset] = usable[index] ? 1.0 : 0.0;
      if (!usable[index]) continue;
      _writeHand(
        row,
        start,
        hands[index]!,
        originX,
        originY,
        scale,
        palms[index],
      );
    }
    // There is no body frame on the phone, so this column is the constant the
    // wrist-framed corpus carries for it.
    row[posePresent] = 0.0;
    row[handCount] = count.toDouble();
    return row;
  }

  static void _writeHand(
    Float32List row,
    int start,
    Float32List hand,
    double originX,
    double originY,
    double scale,
    double palm,
  ) {
    for (var point = 0; point < coordinates; point += 2) {
      row[start + point] = (hand[point] - originX) / scale;
      row[start + point + 1] = (hand[point + 1] - originY) / scale;
    }
    // A ratio of two distances in the same hand, so it is measured here on the
    // raw points; normalising first and dividing after would only add rounding.
    row[start + spreadOffset] = _span(hand) / palm;
    final acrossX = (hand[indexMcp * 2] - hand[pinkyMcp * 2]);
    final acrossY = (hand[indexMcp * 2 + 1] - hand[pinkyMcp * 2 + 1]);
    final angle = math.atan2(acrossY, acrossX);
    row[start + rollSinOffset] = math.sin(angle);
    row[start + rollCosOffset] = math.cos(angle);
  }

  static double _distance(Float32List hand, int a, int b) =>
      math.sqrt(_squared(hand, a, b));

  static double _squared(Float32List hand, int a, int b) {
    final dx = hand[a * 2] - hand[b * 2];
    final dy = hand[a * 2 + 1] - hand[b * 2 + 1];
    return dx * dx + dy * dy;
  }

  /// Mean fingertip distance from the wrist, the numerator of the spread.
  static double _span(Float32List hand) {
    var total = 0.0;
    for (final tip in fingertips) {
      total += math.sqrt(_squared(hand, tip, wrist));
    }
    return total / fingertips.length;
  }
}

/// The 16-frame windows the encoder was trained on, filled as the camera reports.
///
/// A window is emitted once [window] frames are buffered and then every
/// [stride] frames, which is how `video_corpus.windows` cuts the corpus. Frames
/// the camera skipped while the app was busy are not interpolated: a missing row
/// is the same all-zero row the extractor writes when it loses tracking, and the
/// model was trained to look past those.
class SignWindowFeed {
  SignWindowFeed({this.window = 16, this.stride = 8});

  final int window;
  final int stride;

  final _rows = <Float32List>[];
  int _pushed = 0;

  /// Push one frame row and return the window that just completed, if any.
  ///
  /// The result is `window * 94` floats laid end to end, oldest first - the
  /// layout [LandmarkEncoder.embed] reads. Windows start on the frame offsets
  /// `video_corpus.windows` cuts the corpus at, so the app's first window is the
  /// first window a clip contributed during training.
  Float32List? push(Float32List row) {
    if (row.length != SignFeatureRow.featuresPerFrame) {
      throw ArgumentError(
        'a frame row is ${SignFeatureRow.featuresPerFrame} floats, got ${row.length}',
      );
    }
    _rows.add(row);
    _pushed++;
    if (_rows.length > window + stride) _rows.removeAt(0);
    if (_pushed < window || (_pushed - window) % stride != 0) return null;
    final out = Float32List(window * SignFeatureRow.featuresPerFrame);
    for (var index = 0; index < window; index++) {
      out.setRange(
        index * SignFeatureRow.featuresPerFrame,
        (index + 1) * SignFeatureRow.featuresPerFrame,
        _rows[_rows.length - window + index],
      );
    }
    return out;
  }

  /// Every buffered row is a frame the camera reported, so none is padding.
  Float32List get mask =>
      Float32List.fromList(List<double>.filled(window, 1.0));

  /// Forget the clip in progress, for example when the hands leave the frame.
  void reset() {
    _rows.clear();
    _pushed = 0;
  }
}
