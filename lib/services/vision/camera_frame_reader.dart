import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';

import 'hand_frame.dart';

/// One camera frame, shrunk to a small RGBX grid.
///
/// Recognition works on shape, not detail, and 80 cells across costs a few
/// thousand operations per frame instead of a few hundred thousand.
final class FrameGrid {
  const FrameGrid({
    required this.width,
    required this.height,
    required this.rgbx,
  });

  final int width;
  final int height;
  final Uint8List rgbx;

  SkinMask toSkinMask() =>
      SkinMask.fromRgb(rgbx: rgbx, width: width, height: height);
}

/// Turns a [CameraImage] into a [FrameGrid], whichever pixel format the
/// platform delivered.
abstract final class CameraFrameReader {
  static const defaultGridWidth = 80;

  /// Null when this frame cannot be read — an unknown format, or planes too
  /// short for their own row stride. A frame that cannot be read is dropped,
  /// not guessed at.
  ///
  /// One step is used for both axes, so cells stay square and a hand at the top
  /// of the frame means the same thing at any camera resolution.
  static FrameGrid? toGrid(
    CameraImage image, {
    int maxWidth = defaultGridWidth,
  }) {
    final sourceWidth = image.width;
    final sourceHeight = image.height;
    if (sourceWidth <= 0 || sourceHeight <= 0) {
      return null;
    }

    final longest = sourceWidth > sourceHeight ? sourceWidth : sourceHeight;
    final step = math.max(1, (longest / maxWidth).ceil());
    final gridWidth = (sourceWidth / step).floor();
    final gridHeight = (sourceHeight / step).floor();
    if (gridWidth <= 1 || gridHeight <= 1) {
      return null;
    }

    final rgbx = Uint8List(gridWidth * gridHeight * 4);
    final yuv = _YuvPlanes.tryParse(image);
    var cell = 0;

    for (var y = 0; y < gridHeight; y++) {
      for (var x = 0; x < gridWidth; x++, cell++) {
        final rgb = yuv == null
            ? _bgraAt(image, x * step, y * step)
            : yuv.at(x * step, y * step);
        if (rgb == null) {
          return null;
        }
        rgbx[cell * 4] = rgb[0];
        rgbx[cell * 4 + 1] = rgb[1];
        rgbx[cell * 4 + 2] = rgb[2];
        rgbx[cell * 4 + 3] = 255;
      }
    }

    return FrameGrid(width: gridWidth, height: gridHeight, rgbx: rgbx);
  }

  static List<int>? _bgraAt(CameraImage image, int x, int y) {
    if (image.planes.isEmpty) {
      return null;
    }
    final plane = image.planes.first;
    final bytes = plane.bytes;
    final stride = plane.bytesPerRow;
    final bpp = plane.bytesPerPixel ?? 0;
    if (bpp < 4) {
      return null;
    }
    final offset = y * stride + x * bpp;
    if (offset + 3 >= bytes.length) {
      return null;
    }
    // Camera reports BGRA; the mask only needs the three channels.
    return [bytes[offset + 2], bytes[offset + 1], bytes[offset]];
  }
}

class _YuvPlanes {
  _YuvPlanes._(
    this._y,
    this._u,
    this._v,
    this._width,
    this._height,
    this._yStride,
    this._uStride,
    this._vStride,
    this._uPixelStride,
    this._vPixelStride,
    this._singlePlane,
  );

  final Uint8List _y;
  final Uint8List _u;
  final Uint8List _v;
  final int _width;
  final int _height;
  final int _yStride;
  final int _uStride;
  final int _vStride;
  final int _uPixelStride;
  final int _vPixelStride;

  /// NV21 packs everything into one plane: full luma, then interleaved V,U.
  final bool _singlePlane;

  static _YuvPlanes? tryParse(CameraImage image) {
    final planes = image.planes;
    if (planes.isEmpty) {
      return null;
    }
    if (planes.length == 1) {
      // A single 4-byte plane is BGRA, not NV21; the caller reads those.
      if ((planes.first.bytesPerPixel ?? 0) >= 4) {
        return null;
      }
      final bytes = planes.first.bytes;
      final pixels = image.width * image.height;
      if (bytes.length < pixels + pixels ~/ 2) {
        return null;
      }
      return _YuvPlanes._(
        bytes,
        bytes,
        bytes,
        image.width,
        image.height,
        image.width,
        image.width,
        image.width,
        2,
        2,
        true,
      );
    }
    if (planes.length < 3) {
      return null;
    }
    return _YuvPlanes._(
      planes[0].bytes,
      planes[1].bytes,
      planes[2].bytes,
      image.width,
      image.height,
      planes[0].bytesPerRow,
      planes[1].bytesPerRow,
      planes[2].bytesPerRow,
      _pixelStride(planes[1]),
      _pixelStride(planes[2]),
      false,
    );
  }

  /// Interleaved chroma uses a stride of 2, planar chroma of 1. Camera reports
  /// this per plane, and reading the wrong stride samples the wrong channel.
  static int _pixelStride(Plane plane) {
    final stride = plane.bytesPerPixel ?? 1;
    return stride < 1 ? 1 : stride;
  }

  List<int>? at(int x, int y) {
    if (x >= _width || y >= _height) {
      return null;
    }
    final lumaOffset = y * _yStride + x;
    if (lumaOffset >= _y.length) {
      return null;
    }
    final luma = _y[lumaOffset];
    final chromaX = x ~/ 2;
    final chromaY = y ~/ 2;

    int? blue, red;
    if (_singlePlane) {
      final chroma = _height * _width + chromaY * _width + chromaX * 2;
      if (chroma + 1 >= _u.length) {
        return null;
      }
      // NV21 order is V then U.
      red = _u[chroma] - 128;
      blue = _u[chroma + 1] - 128;
    } else {
      final uOffset = chromaY * _uStride + chromaX * _uPixelStride;
      final vOffset = chromaY * _vStride + chromaX * _vPixelStride;
      if (uOffset >= _u.length || vOffset >= _v.length) {
        return null;
      }
      blue = _u[uOffset] - 128;
      red = _v[vOffset] - 128;
    }

    return [
      _clamp(luma + 1.402 * red),
      _clamp(luma - 0.344136 * blue - 0.714136 * red),
      _clamp(luma + 1.772 * blue),
    ];
  }

  static int _clamp(double value) => value.round().clamp(0, 255);
}
