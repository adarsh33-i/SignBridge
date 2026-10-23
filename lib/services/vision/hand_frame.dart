import 'dart:math' as math;
import 'dart:typed_data';

/// A hand found in one frame, described by shape rather than by pixels.
///
/// Everything here comes from a binary skin mask on a small grid, so the
/// numbers stay comparable across camera resolutions and devices.
final class HandFrame {
  const HandFrame({
    required this.at,
    required this.found,
    this.centerX = 0,
    this.centerY = 0,
    this.coverage = 0,
    this.elongation = 1,
    this.fingerRuns = 0,
  });

  /// Reads one frame's skin mask into a hand, or records that there is no hand
  /// worth describing.
  factory HandFrame.scan(SkinMask mask, DateTime at) {
    final blob = mask.largestBlob();
    if (blob == null) {
      return HandFrame(at: at, found: false);
    }
    return HandFrame(
      at: at,
      found: true,
      centerX: blob.centerX,
      centerY: blob.centerY,
      coverage: blob.coverage,
      elongation: blob.elongation,
      fingerRuns: blob.fingerRuns,
    );
  }

  final DateTime at;

  /// False when no skin blob was big enough to be a hand.
  final bool found;

  /// 0 = left edge, 1 = right edge.
  final double centerX;

  /// 0 = top of the frame, 1 = bottom. A raised hand sits near 0.
  final double centerY;

  /// Share of the grid the hand covers, 0..1.
  final double coverage;

  /// Principal axis over minor axis: 1 for a round blob, larger when the hand
  /// is stretched out.
  final double elongation;

  /// The most skin strips a single row crossed anywhere in the top of the hand.
  /// A closed fist is one strip; a spread hand is three or four.
  final int fingerRuns;

  bool get isHigh => centerY < 0.36;

  bool get isMid => centerY >= 0.36 && centerY < 0.64;

  bool get isLow => centerY >= 0.64;
}

/// Shape of one skin blob. Coordinates are normalised to 0..1.
final class HandBlob {
  const HandBlob({
    required this.count,
    required this.coverage,
    required this.centerX,
    required this.centerY,
    required this.elongation,
    required this.fingerRuns,
  });

  final int count;
  final double coverage;
  final double centerX;
  final double centerY;
  final double elongation;
  final int fingerRuns;
}

/// Binary skin mask over a downsampled grid.
final class SkinMask {
  const SkinMask({
    required this.width,
    required this.height,
    required this.pixels,
  });

  final int width;
  final int height;

  /// One byte per cell: 1 skin, 0 not.
  final Uint8List pixels;

  int get cellCount => width * height;

  bool at(int x, int y) => pixels[y * width + x] != 0;

  factory SkinMask.fromRgb({
    required Uint8List rgbx,
    required int width,
    required int height,
  }) {
    final pixels = Uint8List(width * height);
    for (var i = 0; i < width * height; i++) {
      if (_isSkin(rgbx[i * 4], rgbx[i * 4 + 1], rgbx[i * 4 + 2])) {
        pixels[i] = 1;
      }
    }
    return SkinMask(width: width, height: height, pixels: pixels);
  }

  /// The chroma rule: skin sits in a narrow band of blue difference and a wider
  /// band of red difference, and luma drops the shadows that match those bands.
  static bool _isSkin(int r, int g, int b) {
    final luma = 0.299 * r + 0.587 * g + 0.114 * b;
    if (luma < 80) {
      return false;
    }
    final cb = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b;
    final cr = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b;
    return cb >= 77 && cb <= 127 && cr >= 133 && cr <= 173;
  }

  /// A mask with every cell set, for tests and for a frame that is all skin.
  static SkinMask filled(int width, int height) => SkinMask(
    width: width,
    height: height,
    pixels: Uint8List(width * height)..fillRange(0, width * height, 1),
  );

  /// The biggest run of touching skin cells, or null when no run is big enough
  /// to be a hand. Smaller runs are background: a second face, a sleeve, noise.
  HandBlob? largestBlob({double minCoverage = 0.02}) {
    final visited = Uint8List(cellCount);
    final stack = <int>[];
    final cells = <int>[];
    _BlobAccumulator? best;
    List<int>? bestCells;

    for (var seed = 0; seed < cellCount; seed++) {
      if (pixels[seed] == 0 || visited[seed] == 1) {
        continue;
      }
      visited[seed] = 1;
      stack.add(seed);
      cells.clear();
      final blob = _BlobAccumulator();
      while (stack.isNotEmpty) {
        final index = stack.removeLast();
        final x = index % width;
        final y = index ~/ width;
        blob.add(x, y);
        cells.add(index);
        _pushNeighbours(index, x, y, visited, stack);
      }
      if (best == null || blob.count > best.count) {
        best = blob;
        bestCells = List.of(cells);
      }
    }

    final blob = best;
    if (blob == null || blob.count / cellCount < minCoverage) {
      return null;
    }
    return blob.toBlob(this, bestCells!);
  }

  void _pushNeighbours(
    int index,
    int x,
    int y,
    Uint8List visited,
    List<int> stack,
  ) {
    void push(int neighbour) {
      if (pixels[neighbour] != 0 && visited[neighbour] == 0) {
        visited[neighbour] = 1;
        stack.add(neighbour);
      }
    }

    if (x > 0) push(index - 1);
    if (x < width - 1) push(index + 1);
    if (y > 0) push(index - width);
    if (y < height - 1) push(index + width);
  }
}

class _BlobAccumulator {
  int count = 0;
  double sumX = 0;
  double sumY = 0;
  double sumXX = 0;
  double sumYY = 0;
  double sumXY = 0;
  int minX = 1 << 30;
  int maxX = -1;
  int minY = 1 << 30;
  int maxY = -1;

  void add(int x, int y) {
    count++;
    sumX += x;
    sumY += y;
    sumXX += x * x.toDouble();
    sumYY += y * y.toDouble();
    sumXY += x * y.toDouble();
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }

  HandBlob toBlob(SkinMask mask, List<int> cells) {
    final gridWidth = mask.width;
    final gridHeight = mask.height;
    final cx = sumX / count;
    final cy = sumY / count;
    final varX = sumXX / count - cx * cx;
    final varY = sumYY / count - cy * cy;
    final covXY = sumXY / count - cx * cy;

    // Eigenvalues of the 2x2 covariance are the squared axes.
    final trace = varX + varY;
    final det = varX * varY - covXY * covXY;
    final inner = trace * trace / 4 - det;
    final root = inner <= 0 ? 0.0 : math.sqrt(inner);
    final major = trace / 2 + root;
    final minor = trace / 2 - root;
    final elongation = minor <= 0.0001
        ? 6.0
        : math.sqrt(major / minor).clamp(1.0, 6.0);

    return HandBlob(
      count: count,
      coverage: count / mask.cellCount,
      centerX: cx / gridWidth,
      centerY: cy / gridHeight,
      elongation: elongation,
      fingerRuns: _fingerRuns(mask, cells),
    );
  }

  /// The most separate strips any one row near the top of the blob crosses.
  ///
  /// Fingers are the part of a hand a fist cannot copy: rows above the palm have
  /// gaps in them, and a fist is one solid strip on every row. Reading the best
  /// row instead of a guessed one keeps the count steady when the hand tilts,
  /// which is what a fixed scan line cannot do.
  int _fingerRuns(SkinMask mask, List<int> cells) {
    final inBlob = Uint8List(mask.cellCount);
    for (final cell in cells) {
      inBlob[cell] = 1;
    }
    final rows = ((maxY - minY + 1) * 0.6).ceil();
    var best = 0;
    for (var row = 0; row < rows; row++) {
      final line = (minY + row) * mask.width;
      var runs = 0;
      var insideRun = false;
      for (var x = minX; x <= maxX; x++) {
        if (inBlob[line + x] == 1) {
          if (!insideRun) {
            runs++;
          }
          insideRun = true;
        } else {
          insideRun = false;
        }
      }
      if (runs > best) {
        best = runs;
      }
    }
    return best;
  }
}
