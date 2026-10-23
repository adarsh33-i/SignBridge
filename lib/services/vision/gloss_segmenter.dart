import 'dart:typed_data';

import 'gloss_bank.dart';
import 'landmark_encoder.dart';
import 'sign_feature_row.dart';

/// Turns a stream of camera windows into the list of glosses that were signed.
///
/// A phone window is not a word. `video_corpus.WINDOW` is 16 frames and
/// `WINDOW_STRIDE` is 8, so one sign that is held for a second and a half answers
/// on two windows in a row, and a three-second sign answers on four. Without this
/// step the app would repeat the word for as long as the hand stayed up.
///
/// The rule is therefore about *runs*: a gloss is spoken once, when the same clip
/// has been the accepted answer for [hold] windows in a row, and then not again
/// until a different clip takes over. Nothing here invents an answer: a window
/// the bank declines, or one with no hands in it, ends the current run instead of
/// being guessed at, which is the whole reason the margin gate is worth running.
class GlossSegmenter {
  GlossSegmenter({required this.encoder, required this.bank, this.hold = 2});

  final LandmarkEncoder encoder;
  final GlossBank bank;

  /// How many consecutive windows must name the same clip before it is emitted.
  ///
  /// Two windows at stride 8 is 0.8 s of signing, which is shorter than any real
  /// sign and long enough that a single lucky window cannot put a word on screen.
  final int hold;

  final List<String> _glosses = [];
  String? _current;
  int _run = 0;
  bool _said = false;

  /// What has been signed so far, in order, as clip keys (`asl/hello.mp4`).
  List<String> get glosses => List.unmodifiable(_glosses);

  /// The gloss ids the lexicon and the avatar use, derived from [glosses].
  List<String> get words => _glosses.map(glossOfClip).toList();

  String get text => words.join(' ');

  /// Feed one window; returns the gloss id it just named, or null when it named none.
  ///
  /// A non-null return means a new word was added to [text], which is when the UI
  /// should start the avatar re-signing.
  String? addWindow(Float32List features, Float32List mask) {
    if (!_hasHands(features)) {
      // The signer dropped their hands or the tracker lost them. This is a
      // boundary, not a query: encoding it would ask the bank to name an empty
      // frame, and the nearest clip to nothing is a coin toss.
      _break();
      return null;
    }
    final match = bank.lookup(encoder.embed(features, mask));
    if (match == null || !match.accepted) {
      _break();
      return null;
    }
    if (match.clip != _current) {
      _current = match.clip;
      _run = 1;
      _said = false;
      return null;
    }
    _run++;
    // One word per run. The run keeps counting after the emit so a sign held for
    // three seconds is still one word, and a second run of the same sign after a
    // boundary is a user who signed it twice and means it twice.
    // A single-clip bank always accepts (there is no runner-up to lose to), which
    // is a bank-build problem this class cannot see; [GlossBank.lookup] is the
    // place that knows how many clips it searched.
    if (_said || _run < hold) return null;
    _said = true;
    _glosses.add(match.clip);
    return glossOfClip(match.clip);
  }

  /// Forget the sentence in progress - the user stopped recording or started over.
  void reset() {
    _glosses.clear();
    _break();
  }

  void _break() {
    _current = null;
    _run = 0;
    _said = false;
  }

  bool _hasHands(Float32List features) {
    const stride = SignFeatureRow.featuresPerFrame;
    for (var row = 0; row < encoder.window; row++) {
      if (features[row * stride + SignFeatureRow.handCount] > 0.0) {
        return true;
      }
    }
    return false;
  }
}
