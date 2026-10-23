import 'sign_pose.dart';

/// One waypoint of a sign: how long to travel into it, then how long to hold.
class PoseKey {
  /// `travelMs: 0` is only a no-op on the first key of a sign, where it records
  /// that the hand starts in position. Anywhere else it asks for a snap, and
  /// none of the authored signs use one: [SignAnimation] re-starts every repeat
  /// with [_restarted] and reverses with [_backwards] so a travel of zero can
  /// never be carried into a pass where the hand is already elsewhere.
  const PoseKey({required this.pose, this.travelMs = 220, this.holdMs = 0});

  final SignPose pose;
  final int travelMs;
  final int holdMs;

  Map<String, Object?> toJson() => {
    'pose': pose.name,
    'travel': travelMs,
    'hold': holdMs,
  };
}

/// One timed travel span between two waypoints.
class PoseSegment {
  const PoseSegment(this.startMs, this.endMs, this.from, this.to);

  final int startMs;
  final int endMs;
  final SignPose from;
  final SignPose to;
}

/// A sign played as a keyframe timeline.
///
/// The movement is the linguistic content — repetition, alternating hands and
/// a hold at the extreme of a wave all carry meaning — so they are authored as
/// data on the animation, not invented by the renderer.
class SignAnimation {
  const SignAnimation._({
    required this.id,
    required this.gloss,
    required this.frames,
    required this.segments,
    required this.totalMs,
    required this.faceOnly,
  });

  factory SignAnimation({
    required String id,
    required String gloss,
    required List<PoseKey> keys,
    int repeat = 1,
    bool pingpong = false,

    /// Face-only animations carry non-manual grammar — the brows, mouth and
    /// head do the talking and the hands have nothing to play. The timeline
    /// reads this to keep the arms on the journey between the signs around
    /// the marker instead of dropping them to the marker's authored rest.
    bool faceOnly = false,
  }) {
    assert(keys.isNotEmpty, 'sign $id has no keyframes');
    final passes = <List<PoseKey>>[];
    final safeRepeat = repeat.clamp(1, 8);
    for (var i = 0; i < safeRepeat; i++) {
      passes.add(i == 0 ? keys : _restarted(keys));
      if (pingpong && i < safeRepeat - 1) passes.add(_backwards(keys));
    }

    // Flatten to one timed run: each frame travels from the previous pose.
    final frames = <PoseKey>[];
    for (final pass in passes) {
      for (var i = 0; i < pass.length; i++) {
        final key = pass[i];
        if (frames.isEmpty) {
          frames.add(PoseKey(pose: key.pose, travelMs: 0, holdMs: key.holdMs));
        } else {
          frames.add(key);
        }
      }
    }

    final spans = <PoseSegment>[];
    var cursor = frames.first.holdMs;
    for (var i = 1; i < frames.length; i++) {
      final travel = frames[i].travelMs;
      spans.add(
        PoseSegment(
          cursor,
          cursor + travel,
          frames[i - 1].pose,
          frames[i].pose,
        ),
      );
      cursor += travel + frames[i].holdMs;
    }

    return SignAnimation._(
      id: id,
      gloss: gloss,
      frames: frames,
      segments: spans,
      totalMs: cursor,
      faceOnly: faceOnly,
    );
  }

  /// The same run played again.
  ///
  /// A pass after the first has to *arrive* somewhere: the previous one ended on
  /// the last key, and the opening key's `travelMs: 0` — which means "the hand is
  /// already here", once, at the start of the sign — says nothing about the trip
  /// back. Left as authored it became a zero-length segment, so every repeating
  /// sign snapped from its extreme to its opening pose in a single frame: the tap
  /// of EAT reappeared at the mouth instead of lifting to it, and all fifteen
  /// pingpong signs did the same thing on the way back. That was the single most
  /// visible thing the rig did wrong.
  ///
  /// The trip back gets the time the trip out took, which is the only duration a
  /// sign knows.
  static List<PoseKey> _restarted(List<PoseKey> keys) => [
    PoseKey(
      pose: keys.first.pose,
      travelMs: keys.length > 1 ? keys[1].travelMs : 0,
      holdMs: keys.first.holdMs,
    ),
    ...keys.skip(1),
  ];

  /// The same run played in reverse.
  ///
  /// Reversing the key list alone handed the same bug to every pingpong sign,
  /// because the opening key's zero landed mid-run, where it reads as a teleport
  /// rather than a start. Here the travels rotate with the poses: the time to
  /// reach a pose on the way back is the time it took to leave it on the way out.
  /// The seam key needs no travel — the forward pass has just ended there — and
  /// holds nothing, because that extreme has already been held.
  static List<PoseKey> _backwards(List<PoseKey> keys) => [
    for (var j = keys.length - 1; j >= 0; j--)
      PoseKey(
        pose: keys[j].pose,
        travelMs: j == keys.length - 1 ? 0 : keys[j + 1].travelMs,
        holdMs: j == keys.length - 1 ? 0 : keys[j].holdMs,
      ),
  ];

  final String id;
  final String gloss;

  /// The flattened waypoints of the whole run, repeats and reversals included.
  final List<PoseKey> frames;

  /// Timed travel spans, built once from [frames].
  final List<PoseSegment> segments;
  final int totalMs;

  /// True for non-manual markers: face grammar with no manual content.
  final bool faceOnly;

  Duration get duration => Duration(milliseconds: totalMs);

  SignPose poseAt(Duration elapsed) {
    final ms = elapsed.inMilliseconds;
    if (segments.isEmpty || ms <= 0) return frames.first.pose;
    if (ms >= totalMs) return segments.last.to;
    for (final segment in segments) {
      if (ms < segment.endMs) {
        if (ms <= segment.startMs) return segment.from;
        final span = segment.endMs - segment.startMs;
        final local = span == 0 ? 1.0 : (ms - segment.startMs) / span;
        return _chain(segment.from, segment.to, local);
      }
    }
    return segments.last.to;
  }

  /// The pose at fraction [t] of travelling from [from] to [to], with the
  /// whole body on staggered clocks.
  ///
  /// This is the interpolation [SignTimeline] uses at word boundaries too, so
  /// a hand travelling between two signs moves and lands like a hand, not like
  /// a picture being dragged: the arm commits first and the new handshape
  /// arrives last, exactly as it does mid-sign.
  static SignPose interpolate(SignPose from, SignPose to, double t) =>
      _chain(from, to, t);

  /// The pose half-way through travelling from [from] to [to].
  ///
  /// Every part of the body gets its own window inside the segment rather than
  /// all of it. A real arm moves outward from the body — the shoulder starts,
  /// the wrist follows, the fingers arrive last — and no two fingers agree on a
  /// frame. Lerping all twenty-odd fields with one `t` threw that away and drew
  /// the hand as a picture being dragged: four fingers closing in lockstep, the
  /// arm and the fingers arriving together, everything leaving and landing at
  /// the same speed whatever it was.
  ///
  /// Each window is a (start, end) fraction of the travel, and every one ends at
  /// or before 1, so the segment still finishes exactly on `to` and
  /// `poseAt(totalMs)` is unchanged. The timeline stitching between two signs
  /// depends on both ends being exact.
  static SignPose _chain(SignPose from, SignPose to, double t) => SignPose(
    name: t < 0.5 ? from.name : to.name,
    left: _armAt(from.left, to.left, t),
    right: _armAt(from.right, to.right, t),
    face: FacePose.lerp(from.face, to.face, settle(t)),
    breath: _part(from.breath, to.breath, t, _whole),
  );

  static ArmPose _armAt(ArmPose a, ArmPose b, double t) => ArmPose(
    shoulder: _part(a.shoulder, b.shoulder, t, _upperArm),
    elbow: _part(a.elbow, b.elbow, t, _upperArm),
    wrist: _part(a.wrist, b.wrist, t, _foreArm),
    palm: _part(a.palm, b.palm, t, _foreArm),
    lift: _part(a.lift, b.lift, t, _foreArm),
    hand: _handAt(a.hand, b.hand, t),
    visible: t < 0.5 ? a.visible : b.visible,
  );

  static HandShape _handAt(HandShape a, HandShape b, double t) => HandShape(
    index: _part(a.index, b.index, t, _fingers[0]),
    middle: _part(a.middle, b.middle, t, _fingers[1]),
    ring: _part(a.ring, b.ring, t, _fingers[2]),
    pinky: _part(a.pinky, b.pinky, t, _fingers[3]),
    thumb: _part(a.thumb, b.thumb, t, _thumb),
    thumbSpread: _part(a.thumbSpread, b.thumbSpread, t, _fan),
    thumbUp: _part(a.thumbUp, b.thumbUp, t, _fan),
    spread: _part(a.spread, b.spread, t, _fan),
  );

  static double _part(
    double a,
    double b,
    double t,
    (double start, double end) window,
  ) =>
      a +
      (b - a) *
          settle(((t - window.$1) / (window.$2 - window.$1)).clamp(0.0, 1.0));

  /// The upper arm leads and is already parked while the hand still travels —
  /// the lag at the end of that window is the follow-through that makes a limb
  /// look like it has weight instead of being repositioned.
  static const _upperArm = (0.0, 0.78);
  static const _foreArm = (0.10, 1.0);

  /// Middle leads, index beside it, ring and pinky last — the order a hand
  /// flexes in. The spread is a fifth of a 220ms travel, which is the shortest
  /// interval the eye separates at the size the avatar draws.
  static const _fingers = <(double, double)>[
    (0.02, 0.70),
    (0.0, 0.64),
    (0.10, 0.82),
    (0.18, 0.96),
  ];

  /// The thumb is the slowest digit there is.
  static const _thumb = (0.14, 1.0);
  static const _fan = (0.06, 0.90);
  static const _whole = (0.0, 1.0);

  /// Leaves a pose quickly and lands softly.
  ///
  /// The old curve was smoothstep, which starts and ends at zero velocity, so a
  /// hand left its hold as lazily as it arrived and nothing in the avatar ever
  /// looked like it had committed to a position. Blending in a cubic ease-out
  /// gives a departure with some speed in it while keeping the arrival a settle;
  /// both endpoints are still exactly 0 and 1.
  static double settle(double t) =>
      0.45 * (t * t * (3 - 2 * t)) + 0.55 * (1 - (1 - t) * (1 - t) * (1 - t));
}
