/// Parity against the trained model, checked with the numbers torch actually
/// produced rather than a hand-written expectation.
///
/// `training/video/export_deployable.py` writes these fixtures: the flat weight
/// blob, the manifest describing it, and eight real clip windows with the
/// embedding torch computed for each. If this test passes, the Dart encoder *is*
/// the trained encoder. If the training script ever reorders a parameter, the
/// float-count check fails here instead of at recognition time.
///
/// Regenerate them with:
///
///     training/video/.venv/bin/python training/video/export_deployable.py \
///         --run training/video/runs/video_match_full
///     cp training/video/runs/video_match_full/deploy/video_embed.f32.bin \
///        training/video/runs/video_match_full/deploy/video_golden.txt \
///        test/fixtures/video_match/
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sign_bridge/services/vision/landmark_encoder.dart';

const _fixtures = 'test/fixtures/video_match';

/// The exported weights are float32, this encoder accumulates in double and the
/// result is unit-normalised, so anything above rounding noise is a real
/// disagreement about the arithmetic.
const _tolerance = 1e-4;

class _GoldenWindow {
  _GoldenWindow(this.features, this.mask, this.expected);

  final Float32List features;
  final Float32List mask;
  final Float32List expected;
}

List<String> _lines(String path) =>
    File(path).readAsLinesSync().where((line) => line.trim().isNotEmpty).toList();

Float32List _row(String line) => Float32List.fromList(line.split(' ').map(double.parse).toList());

({int window, int featuresPerFrame, int embedDim, int count, List<_GoldenWindow> windows})
    _readGolden(String path) {
  final lines = _lines(path);
  var index = 0;
  final header = <String, String>{};
  while (index < lines.length && lines[index] != 'features') {
    final parts = lines[index].split(' ');
    header[parts.first] = parts.last;
    index++;
  }
  final count = int.parse(header['windows']!);
  final window = int.parse(header['window']!);
  final featuresPerFrame = int.parse(header['features_per_frame']!);
  final embedDim = int.parse(header['embed_dim']!);
  index++;
  final features = [
    for (var row = 0; row < count * window; row++) _row(lines[index++]),
  ];
  if (lines[index++] != 'mask') throw const FormatException('the golden file has no mask section');
  final masks = [for (var row = 0; row < count; row++) _row(lines[index++])];
  if (lines[index++] != 'expected') throw const FormatException('the golden file has no expected section');
  final expected = [for (var row = 0; row < count; row++) _row(lines[index++])];
  final windows = <_GoldenWindow>[
    for (var row = 0; row < count; row++)
      _GoldenWindow(
        Float32List.fromList([
          for (var frame = 0; frame < window; frame++) ...features[row * window + frame],
        ]),
        masks[row],
        expected[row],
      ),
  ];
  return (
    window: window,
    featuresPerFrame: featuresPerFrame,
    embedDim: embedDim,
    count: count,
    windows: windows,
  );
}

LandmarkEncoder _encoder() {
  final manifest = File('$_fixtures/video_match_manifest.json').readAsStringSync();
  final bytes = File('$_fixtures/video_embed.f32.bin').readAsBytesSync();
  return LandmarkEncoder.parse(
    manifest,
    ByteData.sublistView(Uint8List.fromList(bytes)),
  );
}

void main() {
  final golden = _readGolden('$_fixtures/video_golden.txt');
  final encoder = _encoder();

  test('the fixtures describe the window the encoder reads', () {
    expect(encoder.window, golden.window);
    expect(encoder.featuresPerFrame, golden.featuresPerFrame);
    expect(encoder.embedDim, golden.embedDim);
    expect(golden.windows.first.features.length, golden.window * golden.featuresPerFrame);
  });

  test('the Dart encoder reproduces the trained embedding', () {
    var observed = 0.0;
    for (var row = 0; row < golden.windows.length; row++) {
      final window = golden.windows[row];
      final got = encoder.embed(window.features, window.mask);
      expect(got.length, window.expected.length);
      var worst = 0.0;
      var worstAt = 0;
      for (var column = 0; column < got.length; column++) {
        final diff = (got[column] - window.expected[column]).abs();
        if (diff > worst) {
          worst = diff;
          worstAt = column;
        }
      }
      observed = worst > observed ? worst : observed;
      expect(worst, lessThan(_tolerance), reason: 'window $row, dimension $worstAt');
    }
    // Printed because "it passed" is less useful than knowing by how much: this
    // is the gap the erf approximation and float32 weights cost against torch.
    // ignore: avoid_print
    print('worst embedding difference from torch: $observed');
  });

  test('the embedding is unit length, which is what makes cosine search work', () {
    for (final window in golden.windows) {
      final got = encoder.embed(window.features, window.mask);
      final norm = got.fold<double>(0.0, (sum, value) => sum + value * value);
      expect(norm, closeTo(1.0, _tolerance));
    }
  });

  test('a different window gives a different embedding', () {
    // Guards against an implementation that ignores its input and still matches
    // one golden vector.
    final first = encoder.embed(golden.windows[0].features, golden.windows[0].mask);
    final second = encoder.embed(golden.windows[1].features, golden.windows[1].mask);
    final distance = first
        .toList()
        .asMap()
        .entries
        .fold<double>(0.0, (sum, entry) => sum + (entry.value - second[entry.key]) * (entry.value - second[entry.key]));
    expect(distance, greaterThan(0.01));
  });

  test('a blob that does not match the manifest is refused', () {
    final manifest = jsonDecode(File('$_fixtures/video_match_manifest.json').readAsStringSync())
        as Map<String, dynamic>;
    final short = Uint8List((manifest["float_count"] as int) * 4 - 4);
    expect(
      () => LandmarkEncoder.parse(jsonEncode(manifest), ByteData.sublistView(short)),
      throwsFormatException,
    );
  });

  test('an all-padding window does not produce a NaN', () {
    final features = Float32List(golden.window * golden.featuresPerFrame);
    final mask = Float32List(golden.window);
    final got = encoder.embed(features, mask);
    expect(got.every((value) => value.isFinite), isTrue);
  });
}
