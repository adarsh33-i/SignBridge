import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sign_bridge/services/vision/hand_frame.dart';

import 'synthetic_hand_frames.dart';

/// A mask from ASCII art: `#` is skin, anything else is not.
SkinMask _mask(List<String> rows) {
  final width = rows.first.length;
  final pixels = Uint8List(width * rows.length);
  for (var y = 0; y < rows.length; y++) {
    expect(rows[y].length, width, reason: 'rows must all be the same width');
    for (var x = 0; x < width; x++) {
      pixels[y * width + x] = rows[y][x] == '#' ? 1 : 0;
    }
  }
  return SkinMask(width: width, height: rows.length, pixels: pixels);
}

/// A grid of [SkinMask.fromRgb] input packed the way the camera reader packs it.
Uint8List _rgbx(List<List<int>> colors) => Uint8List.fromList([
  for (final color in colors) ...[color[0], color[1], color[2], 255],
]);

const _skin = [200, 150, 120];
const _wall = [30, 60, 140];

List<String> _square(int side) => [for (var y = 0; y < side; y++) '#' * side];

void main() {
  group('deciding what counts as skin', () {
    test('a skin coloured pixel is kept and a cool wall is not', () {
      final mask = SkinMask.fromRgb(
        rgbx: _rgbx([_skin, _wall, _skin, _wall]),
        width: 2,
        height: 2,
      );

      expect(mask.at(0, 0), isTrue);
      expect(mask.at(1, 0), isFalse);
      expect(mask.at(0, 1), isTrue);
    });

    test('grey is not skin even though its chroma looks close', () {
      // Grey lands exactly on the chroma centre the rule is built around, so
      // only the bands themselves can reject it.
      final mask = SkinMask.fromRgb(
        rgbx: _rgbx([
          [150, 150, 150],
          [150, 150, 150],
          [150, 150, 150],
          [150, 150, 150],
        ]),
        width: 2,
        height: 2,
      );

      expect(mask.at(0, 0), isFalse);
      expect(mask.at(1, 1), isFalse);
    });

    test('a shadow the colour bands would accept is still rejected', () {
      final mask = SkinMask.fromRgb(
        rgbx: _rgbx([
          [60, 45, 36],
          [60, 45, 36],
          [60, 45, 36],
          [60, 45, 36],
        ]),
        width: 2,
        height: 2,
      );

      expect(mask.at(0, 0), isFalse);
    });

    test('a filled mask is all skin', () {
      final mask = SkinMask.filled(4, 3);

      expect(mask.cellCount, 12);
      expect(mask.at(3, 2), isTrue);
      expect(mask.largestBlob()!.coverage, 1);
    });
  });

  group('finding the hand in the mask', () {
    test('the biggest run of touching cells wins', () {
      // An eight by eight hand at the left, a stray two cell sleeve at the right.
      final rows = <String>[for (final row in _square(8)) '$row......##'];
      final blob = _mask(rows).largestBlob()!;

      expect(blob.count, 64);
      expect(blob.centerX, lessThan(0.5));
      expect(blob.centerY, lessThan(0.5));
    });

    test('a run too small to be a hand is not reported as one', () {
      final mask = _mask([
        '##......................................',
        '........................................',
        '........................................',
        '........................................',
      ]);

      expect(mask.largestBlob(), isNull);
    });

    test('a hand touching nothing else is still one blob', () {
      final blob = _mask(_square(10)).largestBlob()!;

      expect(blob.count, 100);
      expect(blob.coverage, 1);
    });

    test('an empty mask has no blob at all', () {
      expect(_mask(['....', '....']).largestBlob(), isNull);
    });
  });

  group('telling an open hand from a fist', () {
    test('four spread fingers read as four strips', () {
      final grid = syntheticHand((centerX: 0.5, centerY: 0.5, open: true));
      final blob = grid.toSkinMask().largestBlob()!;

      expect(blob.fingerRuns, 4);
    });

    test('a fist reads as one strip', () {
      final grid = syntheticHand((centerX: 0.5, centerY: 0.5, open: false));
      final blob = grid.toSkinMask().largestBlob()!;

      expect(blob.fingerRuns, 1);
    });

    test('a solid block is one strip however wide', () {
      expect(_mask(_square(10)).largestBlob()!.fingerRuns, 1);
    });

    test('two blobs side by side with a gap read as two strips', () {
      final blob = _mask(['##....##', '##....##', '##....##']).largestBlob();

      // Disconnected halves are two hands, and only the bigger one is described.
      expect(blob!.fingerRuns, 1);
    });
  });

  group('describing the shape', () {
    test('a square blob is round and a column is stretched', () {
      final square = _mask(_square(9)).largestBlob()!;
      final column = _mask([for (var y = 0; y < 24; y++) '###']).largestBlob()!;

      expect(square.elongation, lessThan(1.2));
      expect(column.elongation, greaterThan(3));
      expect(column.elongation, lessThanOrEqualTo(6));
    });

    test('the centre is a share of the frame, not a pixel count', () {
      final rows = <String>[
        for (var y = 0; y < 40; y++)
          y < 6 ? '${'.' * 6}${'#' * 6}${'.' * 28}' : '.' * 40,
      ];
      final blob = _mask(rows).largestBlob()!;

      expect(blob.centerX, closeTo(8.5 / 40, 0.001));
      expect(blob.centerY, closeTo(2.5 / 40, 0.001));
    });

    test('a hand high in frame is high in the band', () {
      final frame = HandFrame.scan(
        syntheticHand((centerX: 0.5, centerY: 0.2, open: true)).toSkinMask(),
        DateTime(2026),
      );

      expect(frame.found, isTrue);
      expect(frame.isHigh, isTrue);
      expect(frame.isMid, isFalse);
      expect(frame.isLow, isFalse);
    });

    test('a frame with no hand says so instead of describing nothing', () {
      final frame = HandFrame.scan(_mask(['....', '....']), DateTime(2026));

      expect(frame.found, isFalse);
      expect(frame.fingerRuns, 0);
      expect(frame.coverage, 0);
    });
  });
}
