import 'dart:typed_data';

/// One reference window in the retrieval bank, stored as int8.
///
/// The bank is the whole point of this recognizer: one clip per gloss cannot
/// supervise a classifier, so a query is answered by nearest neighbour over
/// 11k signer clips instead. Each clip contributes several windows spread across
/// the clip, and a clip answers with its best window.
class GlossBank {
  GlossBank._({
    required this.vectors,
    required this.clipOfWindow,
    required this.clips,
    required this.scale,
    required this.dimension,
    required this.acceptMargin,
  });

  /// Reads `video_bank.i8.bin`, `video_bank_clip_index.bin` and the manifest
  /// written by `training/video/export_deployable.py`.
  factory GlossBank.fromBytes({
    required ByteData vectors,
    required ByteData clipIndex,
    required Map<String, dynamic> manifest,
  }) {
    final bank = manifest['bank'] as Map<String, dynamic>;
    final dimension = manifest['embed_dim'] as int;
    final windows = bank['windows'] as int;
    if (vectors.lengthInBytes != windows * dimension) {
      throw FormatException(
        'the bank holds ${vectors.lengthInBytes} bytes, expected $windows x $dimension',
      );
    }
    if (clipIndex.lengthInBytes != windows * 2) {
      throw FormatException(
        'the clip index is ${clipIndex.lengthInBytes} bytes, expected ${windows * 2}',
      );
    }
    final clips = (manifest['clips'] as List<dynamic>).cast<String>();
    final stored = Int8List(vectors.lengthInBytes);
    for (var index = 0; index < stored.length; index++) {
      stored[index] = vectors.getInt8(index);
    }
    final owner = Uint16List(windows);
    for (var index = 0; index < windows; index++) {
      owner[index] = clipIndex.getUint16(index * 2, Endian.little);
      if (owner[index] >= clips.length) {
        throw FormatException(
          'window $index points at clip ${owner[index]} of ${clips.length}',
        );
      }
    }
    return GlossBank._(
      vectors: stored,
      clipOfWindow: owner,
      clips: clips,
      scale: (bank['int8_scale'] as num).toDouble(),
      dimension: dimension,
      acceptMargin: (bank['accept_margin'] as num).toDouble(),
    );
  }

  final Int8List vectors;
  final Uint16List clipOfWindow;
  final List<String> clips;
  final double scale;
  final int dimension;

  /// How far the best clip must beat the runner-up before the app will show it.
  ///
  /// Absolute cosine is useless here - every pair of these embeddings sits near
  /// 0.97 - so the decision is made on the gap. `verify_video_match.py` measures
  /// that gap against a held-out half of each clip and prints the answer rate at
  /// each threshold; this value has to be the one that was measured, not one
  /// picked here.
  final double acceptMargin;

  /// Best matching clip, or null when nothing clears the margin.
  ///
  /// The caller must treat null as "no answer" and fall through to the rule-based
  /// recognizer. Guessing the nearest clip anyway would put words in a deaf
  /// user's mouth.
  GlossMatch? lookup(Float32List embedding) {
    if (embedding.length != dimension) {
      throw ArgumentError(
        'the embedding is ${embedding.length}-d, the bank is $dimension-d',
      );
    }
    final bestPerClip = List<double>.filled(
      clips.length,
      double.negativeInfinity,
    );
    final scores = Float32List(vectors.lengthInBytes ~/ dimension);
    for (var window = 0; window < scores.length; window++) {
      final start = window * dimension;
      var acc = 0.0;
      for (var column = 0; column < dimension; column++) {
        acc += embedding[column] * vectors[start + column];
      }
      scores[window] = acc * scale;
      final clip = clipOfWindow[window];
      if (scores[window] > bestPerClip[clip])
        bestPerClip[clip] = scores[window];
    }
    var best = -1, runner = -1;
    for (var clip = 0; clip < bestPerClip.length; clip++) {
      if (best < 0 || bestPerClip[clip] > bestPerClip[best]) {
        runner = best;
        best = clip;
      } else if (runner < 0 || bestPerClip[clip] > bestPerClip[runner]) {
        runner = clip;
      }
    }
    if (best < 0) return null;
    final margin = runner < 0
        ? double.infinity
        : bestPerClip[best] - bestPerClip[runner];
    return GlossMatch(
      clip: clips[best],
      score: bestPerClip[best],
      runnerUpClip: runner < 0 ? null : clips[runner],
      margin: margin,
      accepted: margin >= acceptMargin,
    );
  }
}

class GlossMatch {
  const GlossMatch({
    required this.clip,
    required this.score,
    required this.runnerUpClip,
    required this.margin,
    required this.accepted,
  });

  /// Clip key in the training corpus, `asl/hello.mp4`.
  final String clip;
  final double score;
  final String? runnerUpClip;
  final double margin;
  final bool accepted;

  /// `asl/hello.mp4` -> `hello`, the gloss id the lexicon and the avatar use.
  String get gloss => glossOfClip(clip);

  @override
  String toString() =>
      '$clip score ${score.toStringAsFixed(3)} margin ${margin.toStringAsFixed(3)} '
      '${accepted ? "accepted" : "declined"}';
}

/// The training clip key's gloss id: `asl/hello.mp4` -> `hello`.
///
/// One place, because the avatar and the lexicon are keyed by the id, and a bank
/// answer and a held clip have to resolve to the same word.
String glossOfClip(String clip) {
  final name = clip.split('/').last;
  final dot = name.lastIndexOf('.');
  return dot < 0 ? name : name.substring(0, dot);
}
