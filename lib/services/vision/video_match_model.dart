import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'gloss_bank.dart';
import 'gloss_segmenter.dart';
import 'landmark_encoder.dart';

/// The trained matcher, read out of the app bundle.
///
/// Four files written by `training/video/export_deployable.py` and copied into
/// `assets/models/video_match/`: the encoder weights, the int8 retrieval bank,
/// its clip index, and the manifest that describes both. This app runs no
/// inference runtime - no ONNX, no TFLite, no subscription API - so [LandmarkEncoder]
/// and [GlossBank] read those bytes and do the arithmetic in Dart.
///
/// Loading is separate from the segmenter on purpose. A build without these
/// assets - a CI build, a platform the model was not exported for - has to say so
/// once, at startup, and carry on with the rule-based recognizer it already has.
/// [load] returning null is that statement.
class VideoMatchModel {
  VideoMatchModel._({required this.encoder, required this.bank});

  static const assetPrefix = 'assets/models/video_match';

  final LandmarkEncoder encoder;
  final GlossBank bank;

  /// Reads the bundled model, or null when this build does not carry it.
  ///
  /// A half-copied asset directory is the failure worth guarding against, because
  /// an encoder and a bank from different exports would still run and simply
  /// answer nonsense. Both constructors check their byte counts against the
  /// manifest, so a mismatch is a null and not a confident wrong word.
  static Future<VideoMatchModel?> load({String prefix = assetPrefix}) async {
    try {
      final manifest = jsonDecode(
        await rootBundle.loadString('$prefix/video_match_manifest.json'),
      ) as Map<String, dynamic>;
      final encoder = LandmarkEncoder.fromJsonAndBytes(
        manifest,
        await rootBundle.load('$prefix/video_embed.f32.bin'),
      );
      final bank = GlossBank.fromBytes(
        vectors: await rootBundle.load('$prefix/video_bank.i8.bin'),
        clipIndex: await rootBundle.load('$prefix/video_bank_clip_index.bin'),
        manifest: manifest,
      );
      return VideoMatchModel._(encoder: encoder, bank: bank);
    } catch (_) {
      return null;
    }
  }

  /// A fresh segmenter for one signing session.
  ///
  /// A segmenter holds the words of the sentence being signed, so a new
  /// recording starts a new one instead of continuing the last user's text.
  GlossSegmenter segmenter({int hold = 2}) =>
      GlossSegmenter(encoder: encoder, bank: bank, hold: hold);
}
