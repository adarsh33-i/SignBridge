import 'gesture_track.dart';

/// Why a clip did not produce a gloss, when it did not.
enum GestureOutcome { recognized, nothingSeen, tooShort, heldStill, unclear }

/// What the recognizer thinks was signed, and how sure it is.
final class GestureVerdict {
  const GestureVerdict({
    required this.outcome,
    this.gloss,
    this.confidence = 0,
    required this.detail,
  });

  /// A gloss the sign catalog can name, or null when nothing was recognized.
  final String? gloss;
  final GestureOutcome outcome;

  /// 0..1. Shape rules are coarse, so nothing here claims more than likely.
  final double confidence;

  /// The measurements behind the call, for the debug log and for tests. Never
  /// shown to a user as text, because it is English.
  final String detail;

  bool get isRecognized => gloss != null;
}

/// Reads a hand track and names the gesture.
///
/// These are shape and motion rules written by hand, not a learned model: a
/// wave at head height, a nodding hand, a shaking hand, a palm held still, a
/// hand circling the chest. That is a deliberately small vocabulary. Anything
/// the rules cannot separate comes back unclear rather than guessed at, becau-
/// se a wrong gloss is spoken aloud and signed back at the user as fact.
abstract final class GestureClassifier {
  /// Finger strips in the best row of a frame that means the hand is open. A
  /// fist is one on every row, so two already rules it out; three or four is a
  /// spread hand.
  static const _openHandRuns = 2.0;
  static const _heldCoverage = 0.05;

  static GestureVerdict classify(GestureTrack track) {
    if (track.visibleFrameCount < 3) {
      return GestureVerdict(
        outcome: track.visibility < 0.15
            ? GestureOutcome.nothingSeen
            : GestureOutcome.tooShort,
        detail:
            'hand visible in ${(track.visibility * 100).round()}% of '
            '${track.frameCount} frames',
      );
    }

    final height = _band(track.meanCenterY);
    final open = track.meanFingerRuns >= _openHandRuns;
    final xSwings = track.xSwings;
    final ySwings = track.ySwings;
    final measurements =
        'band=$height runs=${track.meanFingerRuns.toStringAsFixed(1)} '
        'xSwings=$xSwings ySwings=$ySwings travel=${track.pathLength.toStringAsFixed(2)} '
        'coverage=${(track.meanCoverage * 100).toStringAsFixed(1)}%';

    // A palm pushed out and held: the only sign that is meant not to move.
    if (height == _Band.mid &&
        open &&
        track.meanCoverage >= _heldCoverage &&
        track.xTravel < 0.14 &&
        track.yTravel < 0.14) {
      return GestureVerdict(
        outcome: GestureOutcome.recognized,
        gloss: 'STOP',
        confidence: 0.6,
        detail: 'held open palm, $measurements',
      );
    }

    if (track.isStill) {
      return GestureVerdict(
        outcome: GestureOutcome.heldStill,
        detail: 'hand barely moved, $measurements',
      );
    }

    // A wave at head height, open or closed: the greeting is the height plus
    // the sideways swing, not the handshape.
    if (height == _Band.high && xSwings >= 2) {
      return GestureVerdict(
        outcome: GestureOutcome.recognized,
        gloss: 'HELLO',
        confidence: open ? 0.7 : 0.55,
        detail: '${open ? 'open' : 'closed'} hand waving high, $measurements',
      );
    }

    final nodding = ySwings >= 2 && xSwings < 2;
    final shaking = xSwings >= 2 && ySwings < 2;

    if (nodding && height != _Band.high) {
      return GestureVerdict(
        outcome: GestureOutcome.recognized,
        gloss: 'YES',
        confidence: 0.6,
        detail: 'hand bobbing up and down, $measurements',
      );
    }

    if (shaking && height != _Band.high) {
      return GestureVerdict(
        outcome: GestureOutcome.recognized,
        gloss: 'NO',
        confidence: 0.6,
        detail: 'hand shaking side to side, $measurements',
      );
    }

    if (xSwings >= 2 && ySwings >= 2 && height == _Band.mid && open) {
      return GestureVerdict(
        outcome: GestureOutcome.recognized,
        gloss: 'PLEASE',
        confidence: 0.5,
        detail: 'open hand circling at chest height, $measurements',
      );
    }

    return GestureVerdict(
      outcome: GestureOutcome.unclear,
      detail: 'no rule matched, $measurements',
    );
  }

  static _Band _band(double centerY) {
    if (centerY < 0.36) return _Band.high;
    if (centerY < 0.64) return _Band.mid;
    return _Band.low;
  }
}

enum _Band { high, mid, low }
