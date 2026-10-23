import '../../core/services/microservice.dart';
import '../vision/gesture_classifier.dart';
import '../vision/sign_gesture_session.dart';

import 'sign_capture_result.dart';

export 'sign_capture_result.dart';

/// Thrown when the clip was watched but no sign could be named in it.
///
/// [outcome] says which of the honest failures this was — no frames at all, no
/// hand, a hand that stayed still, or motion the rules could not separate — so
/// the user is told what to change instead of being handed a guess.
final class SignNotRecognizedException implements Exception {
  const SignNotRecognizedException(this.outcome, {this.detail = ''});

  final GestureOutcome outcome;
  final String detail;

  @override
  String toString() => 'sign not recognized ($outcome): $detail';
}

/// Reads the frames watched during a sign clip and returns what was signed.
///
/// One method on purpose: there is no sample payload to hand out, because an
/// answer this service returns without reading the clip is a lie the user
/// cannot check.
abstract class SignCaptureService implements Microservice {
  /// Turns the frames watched while a clip was being made into speech text.
  ///
  /// [liveSession] holds those frames and is all recognition ever reads; no
  /// part of this app decodes video. Throws [SignNotRecognizedException] when
  /// no sign could be named, with the outcome that says why.
  Future<SignCaptureResult> analyzeRecording({
    required String languageCode,
    Duration recordingDuration = Duration.zero,
    SignGestureSession? liveSession,
    String? conversationContext,
  });
}
