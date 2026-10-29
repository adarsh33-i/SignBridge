import 'sign_animation.dart';
import 'sign_library.dart';
import 'sign_pose.dart';
import '../../translate/sign_token.dart';

/// A caption's worth of signs laid end to end on one clock.
///
/// The player widget and the frame harnesses both need this, and a loop that is
/// only correct inside a widget cannot be tested at all, so the timeline lives
/// here rather than behind the widget's private types.
class SignTimeline {
  const SignTimeline._(
    this.cues,
    this.totalMs, {
    this.questionFace,
    this.questionUntilMs = 0,
  });

  factory SignTimeline.of(List<SignToken> sequence) {
    final animations = SignLibrary.forSequence(sequence);
    if (animations.isEmpty) return const SignTimeline._(<SignCue>[], 0);
    final cues = <SignCue>[];
    var cursor = _msFrom(
      SignPose.resting,
      animations.first.poseAt(Duration.zero),
    );
    for (var i = 0; i < animations.length; i++) {
      final animation = animations[i];
      cues.add(SignCue(cursor, animation));
      cursor += animation.totalMs;
      final end = animation.poseAt(Duration(milliseconds: animation.totalMs));
      final next = i + 1 < animations.length
          ? animations[i + 1].poseAt(Duration.zero)
          : SignPose.resting;
      cursor += _msFrom(end, next);
    }

    // A question face is a scope, not a beat. Find the one marker that owns it
    // and where that scope ends. Two scoping markers in one caption (a yes/no
    // and a wh-question, say) would fight over the brows, so neither spreads
    // and each plays its own beat.
    FacePose? questionFace;
    var questionUntilMs = 0;
    final scoping = cues.where((c) => c.animation.spreadsFace).toList();
    if (scoping.length == 1) {
      final cue = scoping.single;
      final marker = cue.animation;
      questionFace = marker.poseAt(Duration(milliseconds: marker.totalMs)).face;
      final ramp = marker.frames.length > 1
          ? marker.frames.first.holdMs + marker.frames[1].travelMs
          : marker.totalMs;
      final trailing = cue.endMs >= cues.last.endMs;
      if (trailing) {
        // The marker takes the face over at its own ramp, and the exit after it
        // relaxes both the hands and the expression.
        questionUntilMs = cue.startMs + ramp;
      } else {
        // A leading or mid-sentence marker holds the face to the last sign.
        final signs = cues.where((c) => !c.animation.faceOnly);
        questionUntilMs = signs.isEmpty ? cue.endMs : signs.last.endMs;
      }
    }

    return SignTimeline._(
      cues,
      cursor,
      questionFace: questionFace,
      questionUntilMs: questionUntilMs,
    );
  }

  /// How long the body gets to move between two poses.
  ///
  /// [SignLibrary.restGap] is a *word break*, and a word break is not a
  /// movement: the arms still have to travel from the end of one sign to the
  /// start of the next inside that silence. Lowering a hand from the temple to
  /// the side is a couple of hundred degrees of shoulder and elbow, and 120ms on
  /// a curve that leaves at its fastest turned that into a teleport — the loop
  /// measured 39° of elbow in a single frame. So the silence scales with the
  /// distance instead, and the entry and exit ramps use the same rule, which is
  /// what keeps the wrap continuous at any caption length.
  static int _msFrom(SignPose from, SignPose to) =>
      (_posture(from, to) * _msPerDegree)
          .clamp(SignLibrary.restGap.inMilliseconds.toDouble(), _maxGapMs)
          .round();

  /// The largest joint change either arm has to make. The finger curls are left
  /// out: they travel hundredths of a unit and never dominate a transition, and
  /// a face-only marker therefore keeps the plain word break.
  ///
  /// The wrist is *not* left out. In the chest space the wrist is how a sign
  /// points — YOU turns it to 78 and the fingerspelled hand holds -70 — so two
  /// neighbouring signs can disagree by nearly 150 degrees while their shoulders
  /// barely move. Without the wrist in the distance, every such word break got
  /// the minimum 120ms and the hand spun 34 degrees in a frame.
  static double _posture(SignPose a, SignPose b) {
    // A joint angle is a direction, so the distance between two of them is the
    // short arc, not the subtraction: the same support fold is authored as +192
    // at one sign and -168 at the next, and their signed difference would read
    // as a full turn of travel that never happens.
    double turn(double from, double to) {
      final d = (from - to).abs() % 360.0;
      return d > 180.0 ? 360.0 - d : d;
    }

    double far(ArmPose x, ArmPose y) => [
      turn(x.shoulder, y.shoulder),
      turn(x.elbow, y.elbow),
      turn(x.wrist, y.wrist),
    ].reduce((p, q) => p > q ? p : q);
    return [
      far(a.right, b.right),
      far(a.left, b.left),
    ].reduce((p, q) => p > q ? p : q);
  }

  /// A hand carries about 70° of shoulder in a quarter of a second, which is the
  /// speed the authored travels were already written against.
  static const _msPerDegree = 1.4;

  /// Past this the pause stops reading as a word break and starts reading as
  /// hesitation, so the largest posture changes are allowed to move a little fast.
  static const _maxGapMs = 420.0;

  final List<SignCue> cues;
  final int totalMs;

  /// The face a scoping non-manual marker holds over the signs, if the caption
  /// carries exactly one such marker.
  final FacePose? questionFace;

  /// When the marker takes the face back over (or the last sign ends).
  final int questionUntilMs;

  bool get isEmpty => cues.isEmpty;

  /// Which sign the timeline is on at [ms], or -1 once it has settled.
  ///
  /// A gap between two cues counts as the cue it leaves from, and the entry ramp
  /// counts as the first cue, so the gloss this reports never flickers to nothing
  /// in the middle of a caption — the chip is showing the word the hands are
  /// carrying, not only the word they are holding a pose for.
  int cueIndexAt(int ms) {
    if (cues.isEmpty || ms >= totalMs) return -1;
    for (var i = cues.length - 1; i >= 0; i--) {
      if (ms >= cues[i].startMs) return i;
    }
    return 0;
  }

  /// The gloss of the sign active at [ms], or null once the caption has finished.
  ///
  /// Marker notation ('[wh-q]') is a stage direction, not a word, so a marker
  /// beat reports the gloss of the sign the hands are actually travelling
  /// between — the chip names a sign, never the grammar's backstage label.
  String? glossAt(int ms) {
    var index = cueIndexAt(ms);
    if (index < 0) return null;
    if (!cues[index].animation.faceOnly) return cues[index].animation.gloss;
    for (var j = index - 1; j >= 0; j--) {
      if (!cues[j].animation.faceOnly) return cues[j].animation.gloss;
    }
    for (var j = index + 1; j < cues.length; j++) {
      if (!cues[j].animation.faceOnly) return cues[j].animation.gloss;
    }
    return null;
  }

  SignPose poseAt(int ms) {
    final pose = _poseAt(ms);
    return _withQuestionFace(pose, ms);
  }

  /// Layers the scoping non-manual marker over the pose, fading in over the
  /// first quarter second.
  ///
  /// Only the brow and the head tilt are borrowed: the turn of the head is
  /// left to the idle layer so the eyes keep tracking the hand instead of the
  /// whole face freezing for the length of a question. A sign that authors its
  /// own brow (THUNDER's furrow, say) keeps it.
  SignPose _withQuestionFace(SignPose pose, int ms) {
    final face = questionFace;
    if (face == null || ms >= questionUntilMs) return pose;
    final authored = pose.face;
    if (authored.brow != 0 || authored.headTilt != 0) {
      final index = cueIndexAt(ms);
      final markerNow = index >= 0 && cues[index].animation.faceOnly;
      if (!markerNow) return pose;
    }
    final t = (ms / _questionFadeMs).clamp(0.0, 1.0);
    final k = t * t * (3 - 2 * t);
    return pose.copyWith(
      face: authored.copyWith(
        brow: authored.brow + (face.brow - authored.brow) * k,
        headTilt: authored.headTilt + (face.headTilt - authored.headTilt) * k,
      ),
    );
  }

  static const _questionFadeMs = 240;

  SignPose _poseAt(int ms) {
    if (cues.isEmpty) return SignPose.resting;
    // The settle curve is a cubic, so a position outside the timeline does not
    // clamp — it extrapolates, and the arm flies off. Callers hold the playhead
    // inside the run, but asking for the end of a caption should still mean
    // "hands down" rather than depending on them to know that.
    ms = ms.clamp(0, totalMs);
    final first = cues.first;
    if (ms < first.startMs) {
      final t = first.startMs <= 0 ? 1.0 : ms / first.startMs;
      return SignAnimation.interpolate(
        SignPose.resting,
        first.animation.poseAt(Duration.zero),
        t,
      );
    }
    final last = cues.last;
    if (ms >= last.endMs) {
      // A trailing face marker (the wh-question's furrow lands on the last
      // beat) keeps owning the arms through the exit: they settle to rest for
      // exactly as long as the face holds the grammar.
      if (last.animation.faceOnly) return _markerRunPose(cues.length - 1, ms);
      final span = totalMs - last.endMs;
      final t = span <= 0 ? 1.0 : (ms - last.endMs) / span;
      return SignAnimation.interpolate(
        last.animation.poseAt(Duration(milliseconds: last.animation.totalMs)),
        SignPose.resting,
        t,
      );
    }
    for (var i = 0; i < cues.length; i++) {
      final cue = cues[i];
      if (ms < cue.startMs) {
        final previous = cues[i - 1];
        if (cue.animation.faceOnly || previous.animation.faceOnly) {
          // The gap around a face marker is part of the marker run: the arms
          // are mid-travel between the signs that bracket it.
          return _markerRunPose(cue.animation.faceOnly ? i : i - 1, ms);
        }
        final gapStart = previous.endMs;
        final span = cue.startMs - gapStart;
        final t = span <= 0 ? 1.0 : (ms - gapStart) / span;
        return SignAnimation.interpolate(
          previous.animation.poseAt(
            Duration(milliseconds: previous.animation.totalMs),
          ),
          cue.animation.poseAt(Duration.zero),
          t,
        );
      }
      if (ms < cue.endMs) {
        if (cue.animation.faceOnly) return _markerRunPose(i, ms);
        return cue.animation.poseAt(Duration(milliseconds: ms - cue.startMs));
      }
    }
    return last.animation.poseAt(
      Duration(milliseconds: last.animation.totalMs),
    );
  }

  /// The pose inside a run of consecutive face-only marker cues.
  ///
  /// A non-manual marker is grammar the face carries *while* the hands do
  /// something else — a wh-question furrows on the last sign, it does not get
  /// a separate beat with the hands parked at the sides. The arms therefore
  /// ignore the marker's own (resting) keys and make the one continuous
  /// journey from the end of the sign before the run to the start of the sign
  /// after it, however many markers the face plays along the way. Leading
  /// [y/n-q] and trailing [wh-q] markers reach into the same rule, which keeps
  /// the entry and exit ramps continuous with the run.
  SignPose _markerRunPose(int faceCueIndex, int ms) {
    var first = faceCueIndex;
    while (first > 0 && cues[first - 1].animation.faceOnly) {
      first--;
    }
    var last = faceCueIndex;
    while (last + 1 < cues.length && cues[last + 1].animation.faceOnly) {
      last++;
    }
    final runStartMs = first > 0 ? cues[first - 1].endMs : cues.first.startMs;
    final runEndMs = last + 1 < cues.length ? cues[last + 1].startMs : totalMs;
    final from = first > 0
        ? cues[first - 1].animation.poseAt(
            Duration(milliseconds: cues[first - 1].animation.totalMs),
          )
        : SignPose.resting;
    final to = last + 1 < cues.length
        ? cues[last + 1].animation.poseAt(Duration.zero)
        : SignPose.resting;
    final span = runEndMs - runStartMs;
    final t = span <= 0 ? 1.0 : (ms - runStartMs) / span;
    final arms = SignAnimation.interpolate(from, to, t.clamp(0.0, 1.0));
    // The face is whatever marker is on at this instant; a gap inside the run
    // holds the face of the marker it leaves from.
    final j = cueIndexAt(ms);
    final sourceIndex = j < 0 ? faceCueIndex : j;
    final source = cues[sourceIndex].animation;
    final marked = source.poseAt(
      Duration(
        milliseconds: (ms - cues[sourceIndex].startMs).clamp(0, source.totalMs),
      ),
    );
    // A trailing marker releases its face with the exit ramp, so the avatar
    // does not settle into a resting pose while still wearing the question's
    // furrow. A marker in the middle of a caption hands its face to the next
    // cue instead and never reaches this branch.
    var face = marked.face;
    if (last == cues.length - 1 && ms >= cues[last].endMs) {
      final span = totalMs - cues[last].endMs;
      final t = span <= 0 ? 1.0 : (ms - cues[last].endMs) / span;
      face = FacePose.lerp(face, FacePose.neutral, SignAnimation.settle(t));
    }
    return SignPose(
      name: marked.name,
      left: arms.left,
      right: arms.right,
      face: face,
      breath: arms.breath,
    );
  }
}

/// One sign on the timeline: where it starts, and what it signs.
class SignCue {
  const SignCue(this.startMs, this.animation);

  final int startMs;
  final SignAnimation animation;

  int get endMs => startMs + animation.totalMs;
}
