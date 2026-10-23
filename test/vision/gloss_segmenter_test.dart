/// Splitting a stream of windows into the words that were signed.
///
/// The bank answers per 16-frame window and a sign lasts longer than that, so the
/// app would repeat a word for as long as the hand stayed up without this step.
/// These tests run the real exported encoder and a bank built from the embeddings
/// it produces, so what is pinned is the segmentation - one word per run, a new
/// run after a boundary, nothing guessed - rather than a fake that agrees with
/// itself.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sign_bridge/services/vision/gloss_bank.dart';
import 'package:sign_bridge/services/vision/gloss_segmenter.dart';
import 'package:sign_bridge/services/vision/landmark_encoder.dart';
import 'package:sign_bridge/services/vision/sign_feature_row.dart';

const _fixtures = 'test/fixtures/video_match';

/// A hand with its fingers out to [reach] from the knuckle.
///
/// Curling the fingers is what changes the row the encoder sees; moving the hand
/// is not, because the frame is built from the wrist and divided by the palm.
Float32List _handAt(
  double x,
  double y, {
  required double reach,
  double roll = 0.4,
}) {
  const palm = 0.09;
  final points = Float32List(SignFeatureRow.coordinates);
  void put(int index, double dx, double dy) {
    final cos = math.cos(roll), sin = math.sin(roll);
    points[index * 2] = x + dx * cos - dy * sin;
    points[index * 2 + 1] = y + dx * sin + dy * cos;
  }

  put(SignFeatureRow.wrist, 0, 0);
  put(SignFeatureRow.middleMcp, palm, 0);
  for (var finger = 0; finger < 21; finger++) {
    if (finger != SignFeatureRow.wrist) put(finger, palm * 0.5, 0);
  }
  put(SignFeatureRow.indexMcp, palm, 0.05);
  put(SignFeatureRow.pinkyMcp, palm, -0.05);
  for (var step = 0; step < SignFeatureRow.fingertips.length; step++) {
    put(SignFeatureRow.fingertips[step], palm + reach, (step - 1.5) * 0.04);
  }
  return points;
}

Float32List _window(Float32List row) {
  final out = Float32List(16 * SignFeatureRow.featuresPerFrame);
  for (var frame = 0; frame < 16; frame++) {
    out.setRange(
      frame * SignFeatureRow.featuresPerFrame,
      (frame + 1) * SignFeatureRow.featuresPerFrame,
      row,
    );
  }
  return out;
}

Float32List _row(Float32List hand) => SignFeatureRow.build(left: hand);

Float32List get _emptyRow => SignFeatureRow.build();

/// The bank the phone searches, holding the two shapes this test encodes.
GlossBank _bankOf(
  List<String> clips,
  List<Float32List> vectors,
  int dimension,
) {
  var peak = 0.0;
  for (final vector in vectors) {
    for (final value in vector) {
      peak = math.max(peak, value.abs());
    }
  }
  final scale = peak / 127.0;
  final stored = Int8List(vectors.length * dimension);
  for (var window = 0; window < vectors.length; window++) {
    for (var column = 0; column < dimension; column++) {
      stored[window * dimension + column] = (vectors[window][column] / scale)
          .round()
          .clamp(-127, 127);
    }
  }
  final owner = Uint16List.fromList([
    for (var window = 0; window < vectors.length; window++) window,
  ]);
  final manifest = {
    'embed_dim': dimension,
    'bank': {
      'windows': vectors.length,
      'int8_scale': scale,
      'accept_margin': 0.02,
    },
    'clips': clips,
  };
  return GlossBank.fromBytes(
    vectors: ByteData.sublistView(stored),
    clipIndex: ByteData.sublistView(owner),
    manifest: manifest,
  );
}

void main() {
  final encoder = LandmarkEncoder.parse(
    File('$_fixtures/video_match_manifest.json').readAsStringSync(),
    ByteData.sublistView(
      Uint8List.fromList(
        File('$_fixtures/video_embed.f32.bin').readAsBytesSync(),
      ),
    ),
  );
  final mask = Float32List(encoder.window);
  for (var row = 0; row < mask.length; row++) {
    mask[row] = 1.0;
  }

  final open = _window(_row(_handAt(0.3, 0.4, reach: 0.2)));
  final fist = _window(_row(_handAt(0.3, 0.4, reach: 0.02)));
  final dropped = _window(_emptyRow);
  final embedding = {
    'asl/hello.mp4': encoder.embed(open, mask),
    'isl/thank_you.mp4': encoder.embed(fist, mask),
  };
  const clips = ['asl/hello.mp4', 'isl/thank_you.mp4'];

  GlossSegmenter segmenter() => GlossSegmenter(
    encoder: encoder,
    bank: _bankOf(clips, [
      embedding[clips[0]]!,
      embedding[clips[1]]!,
    ], encoder.embedDim),
  );

  test('the two shapes the bank holds are far apart in the embedding', () {
    // Without this the test below could pass on a bank that answers anything.
    var dot = 0.0;
    for (var column = 0; column < encoder.embedDim; column++) {
      dot += embedding[clips[0]]![column] * embedding[clips[1]]![column];
    }
    expect(1.0 - dot, greaterThan(0.02));
  });

  test('a sign is not a word until it has been held for two windows', () {
    final recognizer = segmenter();
    expect(recognizer.addWindow(open, mask), isNull);
    expect(recognizer.text, isEmpty);
    expect(recognizer.addWindow(open, mask), 'hello');
    expect(recognizer.text, 'hello');
  });

  test('holding a sign longer does not repeat the word', () {
    final recognizer = segmenter();
    for (var window = 0; window < 6; window++) {
      recognizer.addWindow(open, mask);
    }
    expect(recognizer.glosses, ['asl/hello.mp4']);
    expect(recognizer.text, 'hello');
  });

  test('a sentence is the words in the order they were signed', () {
    final recognizer = segmenter();
    recognizer.addWindow(open, mask);
    recognizer.addWindow(open, mask);
    recognizer.addWindow(fist, mask);
    expect(recognizer.text, 'hello');
    recognizer.addWindow(fist, mask);
    expect(recognizer.text, 'hello thank_you');
    recognizer.addWindow(fist, mask);
    expect(recognizer.text, 'hello thank_you');
  });

  test('hands leaving the frame ends the word and starts a new run', () {
    final recognizer = segmenter();
    recognizer.addWindow(open, mask);
    recognizer.addWindow(open, mask);
    expect(recognizer.text, 'hello');
    recognizer.addWindow(dropped, mask);
    recognizer.addWindow(open, mask);
    expect(recognizer.text, 'hello'); // the second hello is still being held
    recognizer.addWindow(open, mask);
    expect(recognizer.text, 'hello hello');
  });

  test('an empty window is never asked what it means', () {
    final recognizer = segmenter();
    recognizer.addWindow(open, mask);
    recognizer.addWindow(dropped, mask);
    expect(recognizer.glosses, isEmpty);
  });

  test('reset starts the sentence over', () {
    final recognizer = segmenter();
    recognizer.addWindow(open, mask);
    recognizer.addWindow(open, mask);
    recognizer.reset();
    expect(recognizer.text, isEmpty);
    expect(recognizer.addWindow(open, mask), isNull);
  });

  test('one run is one word even when the bank cannot decline', () {
    // A one-clip bank has no runner-up, so every window is accepted at any margin.
    // The segmenter must still say the held sign once, not once per window.
    final recognizer = GlossSegmenter(
      encoder: encoder,
      bank: _bankOf(
        ['asl/hello.mp4'],
        [embedding[clips[0]]!],
        encoder.embedDim,
      ),
    );
    expect(recognizer.addWindow(open, mask), isNull);
    expect(recognizer.addWindow(open, mask), 'hello');
    expect(recognizer.addWindow(open, mask), isNull);
    expect(recognizer.glosses, ['asl/hello.mp4']);
  });
}
