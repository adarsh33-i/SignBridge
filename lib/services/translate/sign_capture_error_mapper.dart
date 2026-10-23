import '../home/home_ui_copy.dart';
import '../vision/gesture_classifier.dart';
import 'sign_capture_service.dart';

/// Maps sign-recording failures to short user-facing snackbar text.
///
/// Everything the recognizer can fail at is a typed exception it throws, so
/// there is no response text to parse here. The sign path used to upload the
/// clip to a hosted worker and read that worker's HTTP status and Gemini error
/// strings; that surface is gone.
abstract final class SignCaptureErrorMapper {
  static String userMessage(Object error, HomeUiCopy copy) {
    return _messageFor(_parseError(error), copy);
  }

  /// Long enough to read a full sentence with a next step in it.
  static Duration snackbarDuration(Object error) {
    return switch (_parseError(error)) {
      _ErrorCategory.noHand ||
      _ErrorCategory.handStill ||
      _ErrorCategory.couldNotTell => const Duration(seconds: 6),
      _ErrorCategory.genericFailure => const Duration(seconds: 4),
    };
  }

  static _ErrorCategory _parseError(Object error) {
    if (error is SignNotRecognizedException) {
      return switch (error.outcome) {
        GestureOutcome.nothingSeen => _ErrorCategory.noHand,
        GestureOutcome.heldStill => _ErrorCategory.handStill,
        GestureOutcome.recognized ||
        GestureOutcome.tooShort ||
        GestureOutcome.unclear => _ErrorCategory.couldNotTell,
      };
    }

    return _ErrorCategory.genericFailure;
  }

  static String _messageFor(_ErrorCategory category, HomeUiCopy copy) {
    return switch (category) {
      _ErrorCategory.noHand => copy.signNoHandLabel,
      _ErrorCategory.handStill => copy.signHandWasStillLabel,
      _ErrorCategory.couldNotTell => copy.signCouldNotTellLabel,
      _ErrorCategory.genericFailure => copy.signCaptureFailedLabel,
    };
  }
}

enum _ErrorCategory {
  noHand,
  handStill,
  couldNotTell,
  genericFailure,
}
