import 'dart:math' as math;

import 'sign_pose.dart';

/// The "alive" layer: breathing, blinking and gaze, laid over whatever the
/// timeline produced for this frame.
///
/// It lives outside `SignLibrary` so no authored sign has to remember to blink,
/// and so the same idle clock works while the avatar is between signs and while
/// it is mid-word. Everything here is a pure function of elapsed milliseconds,
/// which keeps rendered frames reproducible.
abstract final class IdleLayer {
  /// Chest rise cycle. Slow enough to read as calm, fast enough to notice.
  static const breathCycleMs = 3600;

  /// One blink every ~4.3 s, shut in 50 ms and open again over 100 ms.
  static const blinkCycleMs = 4300;
  static const blinkOpenMs = 50;
  static const blinkCloseMs = 100;
  static const blinkMs = blinkOpenMs + blinkCloseMs;

  /// Very slow head drift so a resting avatar is never frozen.
  static const driftCycleMs = 9000;

  static SignPose apply(SignPose base, int ms) {
    final breath =
        0.5 -
        0.5 * math.cos(2 * math.pi * (ms % breathCycleMs) / breathCycleMs);
    final gaze = gazeAt(base, ms);
    final authored = base.face;
    // A blink mid-marker would smear the very signal the face is sending —
    // [wh-q] furrows, [y/n-q] raises. The idle blink only runs while the
    // authored face is neutral.
    final marked =
        authored.brow != 0 || authored.eyes != 0 || authored.mouth >= 0.1;
    final blink = marked ? authored.blink : math.max(authored.blink, blinkAt(ms));
    return base.copyWith(
      breath: breath,
      face: authored.copyWith(
        blink: blink,
        // An authored marker wins: it carries grammatical meaning.
        headTurn: authored.headTurn == 0 ? gaze : authored.headTurn,
        headTilt: authored.headTilt == 0 ? gaze * 4 : authored.headTilt,
        smile: authored.smile == 0 && authored.mouth < 0.1
            ? 0.32
            : authored.smile,
      ),
    );
  }

  /// Eyelid closure for this instant, 0 (open) to 1 (shut).
  static double blinkAt(int ms) {
    final t = ms % blinkCycleMs;
    if (t >= blinkMs) return 0;
    return t < blinkOpenMs ? t / blinkOpenMs : (blinkMs - t) / blinkCloseMs;
  }

  /// Where the head looks: toward the hand that is doing the signing, plus a
  /// slow drift.
  static double gazeAt(SignPose pose, int ms) {
    final toward = ((pose.right.shoulder - pose.left.shoulder) / 150).clamp(
      -0.55,
      0.55,
    );
    final drift =
        0.08 * math.sin(2 * math.pi * (ms % driftCycleMs) / driftCycleMs);
    return toward + drift;
  }
}
