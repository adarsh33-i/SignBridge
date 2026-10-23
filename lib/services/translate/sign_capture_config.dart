/// Shared clip-length limits for the Talk → Sign flow.
abstract final class SignCaptureConfig {
  /// Shortest clip worth recognizing: a sign is not finished in less.
  static const minRecordingDuration = Duration(seconds: 2);

  /// Upper bound for clip length validation after the user taps Stop.
  static const maxRecordingDuration = Duration(seconds: 30);
}
