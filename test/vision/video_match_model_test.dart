/// The bundled model has to be the one that was measured.
///
/// `training/video/README.md` records the accuracy of the export in
/// `assets/models/video_match/`; this test fails when the directory holds a
/// different export, because the phone would then be answering with a margin no
/// measurement describes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sign_bridge/services/vision/video_match_model.dart';

void main() {
  // `rootBundle` only resolves the declared assets once a test binding exists.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the shipped assets load as a matcher with the measured shape', () async {
    final model = await VideoMatchModel.load();
    expect(model, isNotNull, reason: 'assets/models/video_match is not in this build');
    expect(model!.encoder.featuresPerFrame, 94);
    expect(model.encoder.window, 16);
    expect(model.bank.dimension, 128);
    expect(model.bank.clips.length, 11005);
    // The gate `verify_video_match.py` measured the answer rate against.
    expect(model.bank.acceptMargin, 0.02);
  });

  test('a build without the model says so instead of half-loading it', () async {
    expect(await VideoMatchModel.load(prefix: 'assets/models/not_exported'), isNull);
  });

  test('a session starts with no words', () async {
    final model = await VideoMatchModel.load();
    expect(model?.segmenter().text, isEmpty);
  });
}
