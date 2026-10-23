/// Outcome of watching a sign clip: what the camera saw turned into words.
class SignCaptureResult {
  const SignCaptureResult({
    required this.text,
    required this.duration,
    this.glossSequence = const [],
    this.modelUsed,
  });

  final String text;
  final Duration duration;

  /// One gloss token per identified sign, in chronological order.
  final List<String> glossSequence;
  final String? modelUsed;

  String formattedDuration() {
    final totalSeconds = duration.inSeconds;
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  bool get hasText => text.trim().isNotEmpty;

  bool get hasGloss => glossSequence.isNotEmpty;
}
