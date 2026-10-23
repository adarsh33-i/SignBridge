import 'package:sign_bridge/services/translate/sign_capture_service.dart';
import 'package:sign_bridge/services/vision/sign_gesture_session.dart';

/// Stands in for the recognizer so widget tests can drive the caption, gloss and
/// avatar path without a camera. Its answer is invented on purpose, which is why
/// only tests use it — see [LocalSignCaptureService] for what the app ships.
final class MockSignCaptureService implements SignCaptureService {
  String? lastLanguageCode;
  SignGestureSession? lastLiveSession;
  Duration analyzeDelay = Duration.zero;

  @override
  String get serviceName => 'mock-sign-capture';

  /// What the mock answers, so a test can name the sentence it expects.
  String get cannedText => 'My name is Alex. I am deaf.';

  @override
  Future<SignCaptureResult> analyzeRecording({
    required String languageCode,
    Duration recordingDuration = Duration.zero,
    SignGestureSession? liveSession,
    String? conversationContext,
  }) async {
    lastLanguageCode = languageCode;
    lastLiveSession = liveSession;
    if (analyzeDelay > Duration.zero) {
      await Future<void>.delayed(analyzeDelay);
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return SignCaptureResult(
      text: cannedText,
      duration: const Duration(seconds: 60),
      glossSequence: const ['MY', 'NAME', 'ALEX', 'ME', 'DEAF'],
    );
  }
}
