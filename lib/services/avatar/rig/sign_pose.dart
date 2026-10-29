import 'dart:math' as math;

/// Hand configuration: five finger curls plus thumb placement.
///
/// Curls are fractional, not booleans, so a handshape can be interpolated
/// mid-flex — a sign that opens from a fist to a flat hand needs the fingers
/// to travel, not snap.
class HandShape {
  const HandShape({
    required this.index,
    required this.middle,
    required this.ring,
    required this.pinky,
    this.thumb = 0,
    this.thumbSpread = 0,
    this.thumbUp = 0,
    this.spread = 0,
  });

  /// 0 = fully extended, 1 = fully curled into the palm.
  final double index;
  final double middle;
  final double ring;
  final double pinky;

  /// 0 = tucked across the palm (fist), 1 = out beside the index finger.
  final double thumb;

  /// Abduction of the thumb, 0 = adducted.
  final double thumbSpread;

  /// 1 = the swing is pulled back to vertical (ASL letter A / the 5-hand).
  final double thumbUp;

  /// Finger abduction: 0 = fingers together, 1 = fanned (V vs U, W, K).
  final double spread;

  static const flat = HandShape(
    index: 0,
    middle: 0,
    ring: 0,
    pinky: 0,
    thumb: 1,
    thumbSpread: 0.35,
  );
  static const fist = HandShape(
    index: 1,
    middle: 1,
    ring: 1,
    pinky: 1,
    thumb: 0.18,
  );
  static const point = HandShape(
    index: 0,
    middle: 1,
    ring: 1,
    pinky: 1,
    thumb: 0.15,
  );
  static const bent = HandShape(
    index: 0.7,
    middle: 0.7,
    ring: 0.7,
    pinky: 0.7,
    thumb: 0.5,
  );

  /// Index tip and thumb pad meeting, the other three folded into the palm —
  /// the hand EAT, BUY and MONEY are made with.
  ///
  /// The index curl is a measured number, not a taste. `thumb` runs 0 = tucked
  /// to 1 = out beside the index, and the tip it reaches is high in the hand, so
  /// the index has to come down to it: at 0.45 the two centres sit 0.0397 apart
  /// and the hand draws as an open C, which is what this shape shipped as until
  /// the gap was measured. The paths touch at the sum of their half-widths
  /// (0.0169), and 0.9/0.40 measures 0.0098 — contact with room left before the
  /// index tip pushes past the thumb and the pair crosses. See
  /// `test/avatar/hand_seam_test.dart`, which pins it.
  static const pinch = HandShape(
    index: 0.9,
    middle: 1,
    ring: 1,
    pinky: 1,
    thumb: 0.40,
  );

  /// All four fingers rounded together with the index tip on the thumb: the
  /// closed circle, ASL letter O and the hand SUN opens from.
  ///
  /// Same calibration as [pinch] — the four curl together, and at an even 0.6
  /// the index tip measures 0.0325 from the thumb, which draws an open C. At
  /// 0.88 they meet at 0.0120.
  static const o = HandShape(
    index: 0.88,
    middle: 0.88,
    ring: 0.88,
    pinky: 0.88,
    thumb: 0.34,
    thumbSpread: 0.1,
  );

  /// Fingers hooked, used by WANT.
  static const claw = HandShape(
    index: 0.55,
    middle: 0.55,
    ring: 0.55,
    pinky: 0.55,
    thumb: 0.45,
  );

  /// A hand hanging at the side. Fingers do not hang straight and parallel:
  /// each curls a little more than the one before it, and they stay close.
  static const relax = HandShape(
    index: 0.06,
    middle: 0.08,
    ring: 0.1,
    pinky: 0.12,
    thumb: 0.3,
    thumbSpread: 0.1,
    spread: 0.0,
  );

  /// A hand that is doing nothing, drawn closed.
  ///
  /// `relax` is the open hand a sign makes, and at rest it read as a rake: four
  /// straight digits held flat to the camera. A hand at the end of a hanging
  /// arm curls softly, so the silhouette ends in a rounded mass rather than in
  /// four points; the digits still separate enough to read as fingers.
  static const hang = HandShape(
    index: 0.5,
    middle: 0.55,
    ring: 0.6,
    pinky: 0.65,
    thumb: 0.5,
    thumbSpread: 0.05,
    spread: 0.0,
  );

  HandShape copyWith({
    double? index,
    double? middle,
    double? ring,
    double? pinky,
    double? thumb,
    double? thumbSpread,
    double? thumbUp,
    double? spread,
  }) => HandShape(
    index: index ?? this.index,
    middle: middle ?? this.middle,
    ring: ring ?? this.ring,
    pinky: pinky ?? this.pinky,
    thumb: thumb ?? this.thumb,
    thumbSpread: thumbSpread ?? this.thumbSpread,
    thumbUp: thumbUp ?? this.thumbUp,
    spread: spread ?? this.spread,
  );

  static HandShape lerp(HandShape a, HandShape b, double t) => HandShape(
    index: _lerp(a.index, b.index, t),
    middle: _lerp(a.middle, b.middle, t),
    ring: _lerp(a.ring, b.ring, t),
    pinky: _lerp(a.pinky, b.pinky, t),
    thumb: _lerp(a.thumb, b.thumb, t),
    thumbSpread: _lerp(a.thumbSpread, b.thumbSpread, t),
    thumbUp: _lerp(a.thumbUp, b.thumbUp, t),
    spread: _lerp(a.spread, b.spread, t),
  );

  Map<String, double> toJson() => {
    'index': index,
    'middle': middle,
    'ring': ring,
    'pinky': pinky,
    'thumb': thumb,
    'thumbSpread': thumbSpread,
    'thumbUp': thumbUp,
    'spread': spread,
  };

  static HandShape fromJson(Map<String, dynamic> json) => HandShape(
    index: (json['index'] as num).toDouble(),
    middle: (json['middle'] as num).toDouble(),
    ring: (json['ring'] as num).toDouble(),
    pinky: (json['pinky'] as num).toDouble(),
    thumb: (json['thumb'] as num?)?.toDouble() ?? 0,
    thumbSpread: (json['thumbSpread'] as num?)?.toDouble() ?? 0,
    thumbUp: (json['thumbUp'] as num?)?.toDouble() ?? 0,
    spread: (json['spread'] as num?)?.toDouble() ?? 0,
  );
}

/// One arm of the rig, in image-plane angles.
///
/// `shoulder` is measured from straight down: 0 = arm at the side, 90 = out
/// horizontal, 120 = raised past horizontal. `elbow` and `wrist` are relative
/// flexion, so a hand-to-forehead pose reads as shoulder 118 / elbow 126 —
/// the same way the joint actually folds when the elbow leads outward.
/// Positive is always "flex", and the renderer mirrors for the other side.
class ArmPose {
  const ArmPose({
    this.shoulder = 8,
    this.elbow = 16,
    this.wrist = -4,
    this.palm = 0,
    this.lift = 0,
    this.hand = HandShape.hang,
    this.visible = true,
  });

  final double shoulder;
  final double elbow;
  final double wrist;

  /// Palm face rotation: 0 = palm toward the viewer, 180 = back of hand.
  final double palm;

  /// Elbow drawn outward, so the forearm reads as reaching into signing space.
  final double lift;

  final HandShape hand;
  final bool visible;

  static const resting = ArmPose();

  ArmPose copyWith({bool? visible}) => ArmPose(
    shoulder: shoulder,
    elbow: elbow,
    wrist: wrist,
    palm: palm,
    lift: lift,
    hand: hand,
    visible: visible ?? this.visible,
  );

  static ArmPose lerp(ArmPose a, ArmPose b, double t) => ArmPose(
    shoulder: _lerp(a.shoulder, b.shoulder, t),
    elbow: _lerp(a.elbow, b.elbow, t),
    wrist: _lerp(a.wrist, b.wrist, t),
    palm: _lerp(a.palm, b.palm, t),
    lift: _lerp(a.lift, b.lift, t),
    hand: HandShape.lerp(a.hand, b.hand, t),
    visible: t < 0.5 ? a.visible : b.visible,
  );

  Map<String, Object?> toJson() => {
    'shoulder': shoulder,
    'elbow': elbow,
    'wrist': wrist,
    'palm': palm,
    'lift': lift,
    'hand': hand.toJson(),
    if (!visible) 'visible': false,
  };

  static ArmPose fromJson(Map<String, dynamic> json) => ArmPose(
    shoulder: (json['shoulder'] as num?)?.toDouble() ?? resting.shoulder,
    elbow: (json['elbow'] as num?)?.toDouble() ?? resting.elbow,
    wrist: (json['wrist'] as num?)?.toDouble() ?? resting.wrist,
    palm: (json['palm'] as num?)?.toDouble() ?? resting.palm,
    lift: (json['lift'] as num?)?.toDouble() ?? resting.lift,
    hand: json['hand'] == null
        ? resting.hand
        : HandShape.fromJson(Map<String, dynamic>.from(json['hand'] as Map)),
    visible: (json['visible'] as bool?) ?? true,
  );
}

/// Face and head — carries the non-manual markers the gloss engine emits
/// (raised brows for `[y/n-q]`, furrowed brows for `[wh-q]`, negation head
/// shake).
class FacePose {
  const FacePose({
    this.headTilt = 0,
    this.headTurn = 0,
    this.gaze = 0,
    this.brow = 0,
    this.eyes = 0,
    this.mouth = 0,
    this.shift = 0,
    this.blink = 0,
    this.smile = 0,
  });

  final double headTilt;

  /// -1 looking to the viewer's left, +1 to the right.
  final double headTurn;

  /// Pupils looking to the viewer's left (-1) or right (+1), independent of
  /// the head. Driven by the idle layer so the eyes follow the signing hand
  /// rather than staring out of a turning head.
  final double gaze;

  /// Signed brow position: 0 = neutral, 1 = raised (yes/no-question marking),
  /// -1 = furrowed (wh-question marking).
  final double brow;

  /// 0 = normal, 1 = wide.
  final double eyes;

  /// 0 closed, 0.5 flat, 1 open (mouthed-gloss cue).
  final double mouth;

  /// Whole-body lean along the horizontal axis, used by head-shift signs.
  final double shift;

  /// Eyelid closure, 0 = open, 1 = shut. Driven by the idle layer, not by
  /// authored signs, so a sign never has to remember to blink.
  final double blink;

  /// Mouth curvature; the open/closed amount stays on [mouth].
  final double smile;

  static const neutral = FacePose();

  FacePose copyWith({
    double? headTilt,
    double? headTurn,
    double? gaze,
    double? brow,
    double? eyes,
    double? mouth,
    double? shift,
    double? blink,
    double? smile,
  }) => FacePose(
    headTilt: headTilt ?? this.headTilt,
    headTurn: headTurn ?? this.headTurn,
    gaze: gaze ?? this.gaze,
    brow: brow ?? this.brow,
    eyes: eyes ?? this.eyes,
    mouth: mouth ?? this.mouth,
    shift: shift ?? this.shift,
    blink: blink ?? this.blink,
    smile: smile ?? this.smile,
  );

  static FacePose lerp(FacePose a, FacePose b, double t) => FacePose(
    headTilt: _lerp(a.headTilt, b.headTilt, t),
    headTurn: _lerp(a.headTurn, b.headTurn, t),
    gaze: _lerp(a.gaze, b.gaze, t),
    brow: _lerp(a.brow, b.brow, t),
    eyes: _lerp(a.eyes, b.eyes, t),
    mouth: _lerp(a.mouth, b.mouth, t),
    shift: _lerp(a.shift, b.shift, t),
    blink: _lerp(a.blink, b.blink, t),
    smile: _lerp(a.smile, b.smile, t),
  );

  Map<String, double> toJson() => {
    'headTilt': headTilt,
    'headTurn': headTurn,
    'gaze': gaze,
    'brow': brow,
    'eyes': eyes,
    'mouth': mouth,
    'shift': shift,
    'blink': blink,
    'smile': smile,
  };

  static FacePose fromJson(Map<String, dynamic> json) => FacePose(
    headTilt: (json['headTilt'] as num?)?.toDouble() ?? 0,
    headTurn: (json['headTurn'] as num?)?.toDouble() ?? 0,
    gaze: (json['gaze'] as num?)?.toDouble() ?? 0,
    brow: (json['brow'] as num?)?.toDouble() ?? 0,
    eyes: (json['eyes'] as num?)?.toDouble() ?? 0,
    mouth: (json['mouth'] as num?)?.toDouble() ?? 0,
    shift: (json['shift'] as num?)?.toDouble() ?? 0,
    blink: (json['blink'] as num?)?.toDouble() ?? 0,
    smile: (json['smile'] as num?)?.toDouble() ?? 0,
  );
}

/// A complete rig state at one instant.
class SignPose {
  const SignPose({
    required this.name,
    required this.left,
    required this.right,
    required this.face,
    this.breath = 0,
  });

  final String name;
  final ArmPose left;
  final ArmPose right;
  final FacePose face;

  /// Idle chest rise, 0..1. Added by the player rather than authored so the
  /// avatar is never perfectly still between signs.
  final double breath;

  static const resting = SignPose(
    name: 'rest',
    left: ArmPose.resting,
    right: ArmPose.resting,
    face: FacePose.neutral,
  );

  SignPose copyWith({
    ArmPose? left,
    ArmPose? right,
    FacePose? face,
    double? breath,
  }) => SignPose(
    name: name,
    left: left ?? this.left,
    right: right ?? this.right,
    face: face ?? this.face,
    breath: breath ?? this.breath,
  );

  static SignPose lerp(SignPose a, SignPose b, double t) => SignPose(
    name: t < 0.5 ? a.name : b.name,
    left: ArmPose.lerp(a.left, b.left, t),
    right: ArmPose.lerp(a.right, b.right, t),
    face: FacePose.lerp(a.face, b.face, t),
    breath: _lerp(a.breath, b.breath, t),
  );

  Map<String, Object?> toJson() => {
    'name': name,
    'left': left.toJson(),
    'right': right.toJson(),
    'face': face.toJson(),
    'breath': breath,
  };

  static SignPose fromJson(Map<String, dynamic> json) => SignPose(
    name: (json['name'] as String?) ?? 'pose',
    left: ArmPose.fromJson(Map<String, dynamic>.from(json['left'] as Map)),
    right: ArmPose.fromJson(Map<String, dynamic>.from(json['right'] as Map)),
    face: json['face'] == null
        ? FacePose.neutral
        : FacePose.fromJson(Map<String, dynamic>.from(json['face'] as Map)),
    breath: (json['breath'] as num?)?.toDouble() ?? 0,
  );
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

double clampUnit(double value) => value < 0 ? 0 : (value > 1 ? 1 : value);

double degrees(double value) => value * math.pi / 180.0;
