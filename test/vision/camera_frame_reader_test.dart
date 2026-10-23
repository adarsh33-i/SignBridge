import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sign_bridge/services/vision/camera_frame_reader.dart';

/// Skin at 200,150,120 turned into BT.601 luma and chroma, the way an Android
/// camera reports it.
const _y = 161;
const _u = 105;
const _v = 155;

CameraImage _image({
  required int width,
  required int height,
  required List<CameraImagePlane> planes,
}) {
  return CameraImage.fromPlatformInterface(
    CameraImageData(
      format: const CameraImageFormat(ImageFormatGroup.yuv420, raw: 35),
      planes: planes,
      height: height,
      width: width,
    ),
  );
}

Uint8List _bytes(int length, int Function(int index) value) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) value(i)]);

/// Planar YUV420: full luma, then a chroma plane each at half size.
CameraImage _planarYuv(int width, int height, {int rowPadding = 0}) {
  final yStride = width + rowPadding;
  final chromaWidth = width ~/ 2;
  final chromaHeight = height ~/ 2;
  final luma = _bytes(yStride * height, (i) => i % yStride < width ? _y : 0);
  final chroma = _bytes(
    (chromaWidth + rowPadding) * chromaHeight,
    (i) => i % (chromaWidth + rowPadding) < chromaWidth ? _u : 0,
  );
  final vChroma = _bytes(
    (chromaWidth + rowPadding) * chromaHeight,
    (i) => i % (chromaWidth + rowPadding) < chromaWidth ? _v : 0,
  );
  return _image(
    width: width,
    height: height,
    planes: [
      CameraImagePlane(bytes: luma, bytesPerRow: yStride, bytesPerPixel: 1),
      CameraImagePlane(
        bytes: chroma,
        bytesPerRow: chromaWidth + rowPadding,
        bytesPerPixel: 1,
      ),
      CameraImagePlane(
        bytes: vChroma,
        bytesPerRow: chromaWidth + rowPadding,
        bytesPerPixel: 1,
      ),
    ],
  );
}

/// NV21: one plane holding every luma byte, then V and U interleaved.
CameraImage _nv21(int width, int height) {
  final pixels = width * height;
  final bytes = Uint8List(pixels + pixels ~/ 2);
  for (var i = 0; i < pixels; i++) {
    bytes[i] = _y;
  }
  for (var i = pixels; i < bytes.length; i++) {
    bytes[i] = (i - pixels).isEven ? _v : _u;
  }
  return _image(
    width: width,
    height: height,
    planes: [CameraImagePlane(bytes: bytes, bytesPerRow: width)],
  );
}

CameraImage _bgra(int width, int height) {
  final bytes = _bytes(width * height * 4, (i) {
    switch (i % 4) {
      case 0:
        return 120; // B
      case 1:
        return 150; // G
      case 2:
        return 200; // R
      default:
        return 255;
    }
  });
  return _image(
    width: width,
    height: height,
    planes: [
      CameraImagePlane(bytes: bytes, bytesPerRow: width * 4, bytesPerPixel: 4),
    ],
  );
}

List<int> _firstPixel(FrameGrid grid) => [
  grid.rgbx[0],
  grid.rgbx[1],
  grid.rgbx[2],
];

void main() {
  group('reading the formats a phone camera delivers', () {
    test('a planar YUV frame becomes an RGB grid', () {
      final grid = CameraFrameReader.toGrid(_planarYuv(40, 30))!;

      expect(grid.width, 40);
      expect(grid.height, 30);
      expect(_firstPixel(grid), [
        closeTo(200, 4),
        closeTo(150, 4),
        closeTo(120, 4),
      ]);
      expect(grid.toSkinMask().at(0, 0), isTrue);
    });

    test('row padding is skipped, not read as colour', () {
      final grid = CameraFrameReader.toGrid(_planarYuv(40, 30, rowPadding: 6))!;

      expect(grid.width, 40);
      expect(_firstPixel(grid), [
        closeTo(200, 4),
        closeTo(150, 4),
        closeTo(120, 4),
      ]);
      expect(grid.toSkinMask().at(39, 29), isTrue);
    });

    test('an NV21 frame is unpacked the same way', () {
      final grid = CameraFrameReader.toGrid(_nv21(40, 30))!;

      expect(_firstPixel(grid), [
        closeTo(200, 4),
        closeTo(150, 4),
        closeTo(120, 4),
      ]);
    });

    test('a BGRA frame gets its channels back in the right order', () {
      final grid = CameraFrameReader.toGrid(_bgra(20, 16))!;

      expect(_firstPixel(grid), [200, 150, 120]);
    });

    test('a BGRA frame is not mistaken for NV21', () {
      // Both arrive as a single plane. Reading the four byte one as luma plus
      // interleaved chroma would turn every pixel into a colour nobody signed.
      final grid = CameraFrameReader.toGrid(_bgra(20, 16))!;

      expect(grid.toSkinMask().at(19, 15), isTrue);
    });
  });

  group('shrinking a frame without changing its shape', () {
    test('a full size frame becomes an eighty cell wide grid', () {
      final grid = CameraFrameReader.toGrid(_planarYuv(640, 480))!;

      expect(grid.width, 80);
      expect(grid.height, 60);
    });

    test('the grid keeps the frame aspect so height still means height', () {
      final wide = CameraFrameReader.toGrid(_planarYuv(320, 240))!;
      final tall = CameraFrameReader.toGrid(_planarYuv(240, 320))!;

      expect(wide.width / wide.height, closeTo(320 / 240, 0.05));
      expect(tall.height / tall.width, closeTo(320 / 240, 0.05));
    });

    test('a small frame is used at full size', () {
      final grid = CameraFrameReader.toGrid(_planarYuv(20, 16))!;

      expect(grid.width, 20);
      expect(grid.height, 16);
    });
  });

  group('dropping a frame that cannot be read', () {
    test('a format with an unknown number of planes is refused', () {
      final twoPlanes = _image(
        width: 20,
        height: 16,
        planes: [
          CameraImagePlane(bytes: Uint8List(20 * 16), bytesPerRow: 20),
          CameraImagePlane(bytes: Uint8List(20 * 16), bytesPerRow: 20),
        ],
      );

      expect(CameraFrameReader.toGrid(twoPlanes), isNull);
    });

    test('a plane shorter than its own rows is refused', () {
      final truncated = _image(
        width: 40,
        height: 30,
        planes: [CameraImagePlane(bytes: Uint8List(10), bytesPerRow: 40)],
      );

      expect(CameraFrameReader.toGrid(truncated), isNull);
    });

    test('an image with no size is refused', () {
      expect(
        CameraFrameReader.toGrid(
          _image(
            width: 0,
            height: 0,
            planes: [CameraImagePlane(bytes: Uint8List(1), bytesPerRow: 1)],
          ),
        ),
        isNull,
      );
    });

    test('a frame with no planes is refused', () {
      expect(
        CameraFrameReader.toGrid(
          _image(width: 20, height: 16, planes: const []),
        ),
        isNull,
      );
    });
  });
}
