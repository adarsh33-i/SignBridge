import '../vision/gesture_classifier.dart';
import '../vision/sign_gesture_session.dart';
import 'sign_capture_service.dart';

/// The sign recognizer this build ships with: hand-written shape and motion
/// rules, run on the frames watched while you record.
///
/// It answers from what the camera saw. When the rules cannot separate what
/// they measured from something else, this throws instead of naming a sign —
/// a wrong gloss is spoken aloud to the user's partner and signed back by the
/// avatar as fact, which is worse than no answer.
///
/// This class used to answer every clip with a canned "My name is Alex. I am
/// deaf." no matter what was recorded, and before that it asked a hosted Gemini
/// worker. The vocabulary here is small and honest: HELLO, YES, NO, STOP,
/// PLEASE. Anything subtler needs the landmark model trained on recorded clips.
final class LocalSignCaptureService implements SignCaptureService {
  @override
  String get serviceName => 'sign-capture-service';

  /// Below this the rules are guessing, so the clip is not answered.
  static const minConfidence = 0.5;

  @override
  Future<SignCaptureResult> analyzeRecording({
    required String languageCode,
    Duration recordingDuration = Duration.zero,
    SignGestureSession? liveSession,
    String? conversationContext,
  }) async {
    // Watching nothing reads as an empty camera, not as a missing model.
    final session = liveSession;
    final verdict =
        session?.verdict() ??
        const GestureVerdict(
          outcome: GestureOutcome.nothingSeen,
          detail: 'no camera frames reached the recognizer',
        );
    final gloss = verdict.gloss;
    if (gloss == null || verdict.confidence < minConfidence) {
      throw SignNotRecognizedException(verdict.outcome, detail: verdict.detail);
    }

    return SignCaptureResult(
      text: _spokenForm(gloss),
      duration: recordingDuration,
      glossSequence: [gloss],
      modelUsed: 'live-gesture-rules-v1',
    );
  }

  /// "HELLO" reads as a sign, "Hello" reads as a sentence. The gloss is kept in
  /// [SignCaptureResult.glossSequence] for the avatar; this is the caption.
  static String _spokenForm(String gloss) {
    return gloss
        .split(' ')
        .where((word) => word.isNotEmpty)
        .map(
          (word) =>
              word.substring(0, 1).toUpperCase() +
              word.substring(1).toLowerCase(),
        )
        .join(' ');
  }
}
