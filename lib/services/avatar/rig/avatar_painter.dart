import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'sign_pose.dart';

/// Flat 2D signing character palette.
class AvatarPalette {
  const AvatarPalette({
    this.skin = const ui.Color(0xFFE8B98F),
    this.skinShade = const ui.Color(0xFFD29C72),
    this.hair = const ui.Color(0xFF3A2B23),
    this.shirt = const ui.Color(0xFF2F6BE0),
    this.shirtShade = const ui.Color(0xFF2456B8),
    this.sleeve = const ui.Color(0xFF1F4FAE),
    this.pants = const ui.Color(0xFF3B4A63),
    this.outline = const ui.Color(0xFF243042),
    this.face = const ui.Color(0xFF2A2320),
    this.skinDeep = const ui.Color(0xFFB87F58),
  });

  final ui.Color skin;
  final ui.Color skinShade;

  /// Deeper skin tone used for every crease, socket and shadow on the body.
  final ui.Color skinDeep;
  final ui.Color hair;
  final ui.Color shirt;
  final ui.Color shirtShade;

  /// Raglan sleeve and collar: a second shirt tone so the arm reads as
  /// attached to a shoulder rather than floating next to one.
  final ui.Color sleeve;

  /// Trousers below the shirt hem, so the torso is a cropped standing figure
  /// rather than a long blue column.
  final ui.Color pants;
  final ui.Color outline;
  final ui.Color face;
}

/// Draws one rig state.
///
/// Everything is unit-space geometry scaled by the shorter canvas axis, so the
/// avatar keeps its proportions at any card size. Joints are chained: shoulder
/// → elbow → wrist → palm → finger segments, each a rotation of its parent.
///
/// Outlines are drawn as a two-pass "ink then fill": the silhouette is stroked
/// once in the ink colour and again, narrower, in the fill colour. Doing it per
/// limb rather than per segment is what keeps a chain of strokes from growing a
/// dark ring at every joint.
class AvatarPainter extends CustomPainter {
  AvatarPainter({required this.pose, this.palette = const AvatarPalette()});

  final SignPose pose;
  final AvatarPalette palette;

  static const _unitShoulderY = 0.405;
  static const _unitShoulderX = 0.168;
  static const _unitUpper = 0.152;
  static const _unitFore = 0.142;
  static const _unitPalm = 0.078;
  static const _unitPalmWide = 0.086;
  static const _unitFinger1 = 0.044;
  static const _unitFinger2 = 0.031;
  static const _unitThumb1 = 0.030;
  static const _unitThumb2 = 0.023;
  static const _unitArm = 0.058;
  static const _unitFinger = 0.0170;

  /// How far a finger's middle joint turns before the fold switches from
  /// rotating to shrinking. See `_digitChains`.
  static const _maxFold = 1.96;

  /// Centre-to-centre spacing of the four fingers at their knuckles, before the
  /// `spread` multiplier. At spread 0 this stays under [_unitFinger] so adjacent
  /// digits intersect — the hand is unioned into one silhouette (see
  /// [_paintHand]) and two digits that miss each other come out as separate
  /// prongs with the background showing between them. `spread` is allowed to
  /// break that contact on purpose: the daylight between V, K and W is the whole
  /// point of those letters, and the palm still bridges every base, so the union
  /// stays one contour. 0.0136 keeps ~2px of overlap at 1600 while leaving each
  /// finger wide enough to read as its own digit.
  static const _unitFingerGap = 0.0136;
  static const _unitHeadR = 0.099;
  static const _unitHeadY = 0.245;

  /// Reference head radius that the face feature offsets were drawn against.
  /// Every feature distance is multiplied by this ratio so the face keeps
  /// fitting the skull when the head size changes.
  static const _unitHeadRRef = 0.108;

  /// Ink weight in unit space. Applied outside every silhouette.
  static const _ink = 0.0115;

  /// How far a shoulder lifts, and how far outward it rolls, once the arm
  /// leaves the side of the body. The girdle has to move with the arm or the
  /// limb reads as a stick pinned to a statue.
  static const _unitShrug = 0.012;
  static const _unitShrugOut = 0.011;

  // Breath raises the chest and head a hair; recomputed per frame.
  late double _shoulderY;
  late double _shoulderX;
  late double _headY;

  /// Contact-shadow fill, rebuilt per frame so its blur tracks the card size.
  late Paint _contactShadowPaint;

  /// 0 for an arm at the side, 1 for one raised past horizontal.
  static double _raiseOf(double shoulder) =>
      ((shoulder - 25) / 115).clamp(0.0, 1.0);

  /// Smooth 0→1 as [v] crosses the window, for anything that must not pop.
  static double _ramp(double lo, double hi, double v) {
    final t = ((v - lo) / (hi - lo)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  Offset _shoulderPoint(double side) {
    final lay = _layout(pose);
    final lift = side < 0 ? lay.liftLeft : lay.liftRight;
    return Offset(
      0.5 + side * (lay.shoulderX + lift * _unitShrugOut),
      lay.shoulderY - lift * _unitShrug,
    );
  }

  /// Chest geometry, recomputed per frame: breath lifts the girdle and the head.
  static ({
    double shoulderY,
    double shoulderX,
    double liftLeft,
    double liftRight,
  })
  _layout(SignPose pose) {
    final rise = pose.breath * 0.007;
    return (
      shoulderY: _unitShoulderY - rise,
      shoulderX: _unitShoulderX + pose.breath * 0.005,
      liftLeft: _raiseOf(pose.left.shoulder),
      liftRight: _raiseOf(pose.right.shoulder),
    );
  }

  /// One arm's joints in unit space: shoulder, elbow, wrist, the angle the palm
  /// is drawn at, and the top of the palm. [_paintArm] draws through this and
  /// the test suite asserts against it, so a limb cannot move without the
  /// shoulder-occlusion check noticing.
  @visibleForTesting
  static ({
    Offset shoulder,
    Offset elbow,
    Offset wrist,
    double palmAngle,
    Offset palmTop,
  })
  armOf(SignPose pose, double side) {
    final lay = _layout(pose);
    final arm = side < 0 ? pose.left : pose.right;
    final lift = side < 0 ? lay.liftLeft : lay.liftRight;
    final shoulder = Offset(
      0.5 + side * (lay.shoulderX + lift * _unitShrugOut),
      lay.shoulderY - lift * _unitShrug,
    );
    final a1 = side * arm.shoulder;
    final elbow =
        shoulder +
        _dir(a1) * _unitUpper +
        Offset(-side * arm.lift * 0.016, -arm.lift * 0.018);
    final a2 = a1 + side * arm.elbow;
    final wrist = elbow + _dir(a2) * _unitFore;
    final palmAngle = a2 + side * arm.wrist;
    return (
      shoulder: shoulder,
      elbow: elbow,
      wrist: wrist,
      palmAngle: palmAngle,
      palmTop: wrist + _dir(palmAngle) * _unitPalm,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width, size.height);
    final dx = (size.width - s) / 2;
    final rise = pose.breath * 0.007;
    final lay = _layout(pose);
    _shoulderY = lay.shoulderY;
    _shoulderX = lay.shoulderX;
    _headY = _unitHeadY - rise * 1.6;

    _contactShadowPaint = Paint()
      ..color = palette.outline.withValues(alpha: 0.20)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.0042);

    canvas.save();
    canvas.translate(dx, s * 0.02);
    canvas.scale(s);
    canvas.translate(pose.face.shift * 0.04, 0);

    _paintLegs(canvas);
    // Both arms are in front of the shirt. Painting the far one behind it used
    // to be the depth cue, but the shirt is a filled path, so it also ate any
    // part of that limb crossing the shoulder line — which is every far hand
    // raised into signing space, and it came out detached from its own arm
    // (measured on `friend` and `money`). Depth is the shade's job now. The far
    // arm still sits under the head, which is where a hand at the cheek belongs.
    final backIsRight = pose.right.shoulder <= pose.left.shoulder;
    final frontSide = backIsRight ? -1.0 : 1.0;
    final frontArm = backIsRight ? pose.left : pose.right;
    final frontJoints = armOf(pose, frontSide);
    final ui.Path? frontHand = frontArm.visible
        ? handUnitPath(
            frontArm,
            frontJoints.wrist,
            frontJoints.palmAngle,
            frontSide,
          )
        : null;
    ui.Path? backHand;
    if (frontHand != null) {
      final backArm = backIsRight ? pose.right : pose.left;
      if (backArm.visible) {
        final backJoints = armOf(pose, backIsRight ? 1.0 : -1.0);
        backHand = handUnitPath(
          backArm,
          backJoints.wrist,
          backJoints.palmAngle,
          backIsRight ? 1.0 : -1.0,
        );
      }
    }

    _paintTorso(canvas);
    _paintArm(
      canvas,
      backIsRight ? pose.right : pose.left,
      side: backIsRight ? 1 : -1,
      back: true,
    );
    // The crease where the front hand presses the far one. Drawn before the
    // head and the front arm so either can cover it where it should.
    if (frontHand != null && backHand != null) {
      _paintContactShadow(canvas, caster: frontHand, receiver: backHand);
    }
    _paintHead(canvas);
    // Hand-on-face holds (chin, mouth, brow) get the same crease.
    if (frontHand != null) {
      _paintContactShadow(canvas, caster: frontHand, receiver: headUnitPath(pose));
    }
    _paintArm(
      canvas,
      backIsRight ? pose.left : pose.right,
      side: backIsRight ? -1 : 1,
      back: false,
    );

    canvas.restore();
  }

  /// Hips and thighs below the shirt hem. They run past the bottom of the
  /// card on purpose: a torso that ends in mid-air reads as a dress.
  void _paintLegs(Canvas canvas) {
    const top = 0.720;
    const hip = 0.140;
    const hem = 1.140;
    final legs = ui.Path()
      ..moveTo(0.5 - hip, top)
      ..lineTo(0.5 + hip, top)
      ..lineTo(0.5 + hip - 0.014, hem)
      ..lineTo(0.5 + 0.018, hem)
      ..lineTo(0.5 + 0.008, 0.905)
      ..lineTo(0.5 - 0.008, 0.905)
      ..lineTo(0.5 - 0.018, hem)
      ..lineTo(0.5 - hip + 0.014, hem)
      ..close();
    _strokedFill(canvas, legs, palette.pants);

    // A crease down each thigh keeps two flat panels from looking like one.
    for (final side in [-1.0, 1.0]) {
      final crease = ui.Path()
        ..moveTo(0.5 + side * 0.072, 0.860)
        ..quadraticBezierTo(
          0.5 + side * 0.066,
          0.980,
          0.5 + side * 0.058,
          1.120,
        );
      canvas.drawPath(
        crease,
        _stroke(palette.outline.withValues(alpha: 0.16), 0.008),
      );
    }
  }

  void _paintTorso(Canvas canvas) {
    // The shoulder line follows whichever arm is lifting.
    final leftTop = _shoulderPoint(-1).dy - 0.014;
    final rightTop = _shoulderPoint(1).dy - 0.014;
    final left = 0.5 - _shoulderX;
    final right = 0.5 + _shoulderX;
    final waist = 0.122 + pose.breath * 0.004;
    final hem = 0.148;
    final hemY = 0.812;
    final body = ui.Path()
      ..moveTo(left - 0.020, leftTop)
      ..cubicTo(
        left - 0.030,
        leftTop + 0.075,
        0.5 - waist - 0.004,
        0.560,
        0.5 - waist,
        0.655,
      )
      ..cubicTo(
        0.5 - waist - 0.004,
        0.730,
        0.5 - hem + 0.006,
        hemY - 0.040,
        0.5 - hem,
        hemY,
      )
      ..quadraticBezierTo(0.5, hemY + 0.028, 0.5 + hem, hemY)
      ..cubicTo(
        0.5 + hem - 0.006,
        hemY - 0.040,
        0.5 + waist + 0.004,
        0.730,
        0.5 + waist,
        0.655,
      )
      ..cubicTo(
        0.5 + waist + 0.004,
        0.560,
        right + 0.030,
        rightTop + 0.075,
        right + 0.020,
        rightTop,
      )
      ..cubicTo(
        0.5 + 0.064,
        rightTop - 0.040,
        0.5 - 0.064,
        leftTop - 0.040,
        left - 0.020,
        leftTop,
      )
      ..close();
    _strokedFill(canvas, body, palette.shirt);

    // Fold lines where the shirt hangs off the shoulders, so the chest is not
    // one flat panel of colour.
    for (final side in [-1.0, 1.0]) {
      final fold = ui.Path()
        ..moveTo(0.5 + side * 0.052, _shoulderY + 0.030)
        ..quadraticBezierTo(
          0.5 + side * 0.070,
          0.560,
          0.5 + side * 0.056,
          0.640,
        );
      canvas.drawPath(
        fold,
        _stroke(palette.shirtShade.withValues(alpha: 0.55), 0.007),
      );
    }
  }

  void _paintHead(Canvas canvas) {
    final tilt = degrees(pose.face.headTilt);
    final neckBase = _shoulderY - 0.012;
    canvas.save();
    canvas.translate(0.5, _headY + _unitHeadR * 0.9);
    canvas.rotate(tilt);
    canvas.translate(-0.5, -(_headY + _unitHeadR * 0.9));

    // Neck: narrower than the head, and the jaw casts across its top so it
    // reads as a cylinder in light rather than a slab.
    final neckTop = _headY + _unitHeadR * 0.60;
    canvas.drawLine(
      Offset(0.5, neckTop),
      Offset(0.5, neckBase),
      _stroke(palette.skin, 0.056),
    );
    canvas.drawLine(
      Offset(0.5, neckTop + 0.002),
      Offset(0.5, neckTop + 0.026),
      _stroke(palette.skinDeep.withValues(alpha: 0.55), 0.056),
    );

    // Hair volume behind the skull, kept to the crown so the jaw stays skin.
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0.2, 0.04, 0.8, _headY - 0.020));
    canvas.drawCircle(
      Offset(0.5, _headY - 0.006),
      _unitHeadR * 1.055,
      _fill(palette.hair),
    );
    canvas.restore();

    // No ears. An ear is six device pixels wide here, and once it takes the
    // body's outline weight it stops reading as a cartilage flap and starts
    // reading as a dark ring stuck to the skull. The hair band covers the gap.

    final head = ui.Path()
      ..addOval(
        Rect.fromCircle(center: Offset(0.5, _headY), radius: _unitHeadR),
      );
    // Lighter ink than the body: the head is a third of the card's width, and
    // at full body weight the ring around it merges with the dark hair and the
    // face reads as an opening in a hood.
    _strokedFill(canvas, head, palette.skin, ink: _ink * 0.7);

    // Fringe: hair clipped to the skull, so it ends on the head edge. The
    // hairline has to cross the crown of the skull — an apex even slightly
    // below the head's top edge leaves a skin band between the hair and the
    // outline, and that band reads as a bald scalp.
    final fringe = ui.Path()
      ..moveTo(0.5 - _unitHeadR, _headY - _unitHeadR * 0.14)
      ..cubicTo(
        0.5 - _unitHeadR * 0.72,
        _headY - _unitHeadR * 0.70,
        0.5 - _unitHeadR * 0.2,
        _headY - _unitHeadR * 1.04,
        0.5 + _unitHeadR * 0.18,
        _headY - _unitHeadR * 0.96,
      )
      ..cubicTo(
        0.5 + _unitHeadR * 0.62,
        _headY - _unitHeadR * 0.82,
        0.5 + _unitHeadR * 0.86,
        _headY - _unitHeadR * 0.42,
        0.5 + _unitHeadR,
        _headY - _unitHeadR * 0.06,
      )
      ..lineTo(0.5 + _unitHeadR, _headY - _unitHeadR * 1.4)
      ..lineTo(0.5 - _unitHeadR, _headY - _unitHeadR * 1.4)
      ..close();
    canvas.save();
    canvas.clipPath(head);
    canvas.drawPath(fringe, _fill(palette.hair));
    // No edge stroke along the hairline. A dark line the width of the hair
    // mass's own boundary reads as a headband at card size, and the colour
    // change from hair to skin already defines the edge.
    canvas.restore();

    // Hair down the sides of the skull: without it the hair reads as a cap
    // sitting on top of a bald head. The band is thick at the temple and thins
    // to a tip at the jaw, and its inner edge stays near the edge of the skull
    // below eye level. Held any further in, the two bands and the fringe close
    // into a ring and the face becomes an opening in a hood.
    for (final side in [-1.0, 1.0]) {
      canvas.save();
      canvas.clipPath(head);
      canvas.drawPath(
        ui.Path()
          ..moveTo(0.5 + side * _unitHeadR * 1.06, _headY - _unitHeadR * 0.42)
          ..quadraticBezierTo(
            0.5 + side * _unitHeadR * 1.05,
            _headY + _unitHeadR * 0.26,
            0.5 + side * _unitHeadR * 0.94,
            _headY + _unitHeadR * 0.60,
          )
          ..quadraticBezierTo(
            0.5 + side * _unitHeadR * 0.78,
            _headY + _unitHeadR * 0.58,
            0.5 + side * _unitHeadR * 0.80,
            _headY + _unitHeadR * 0.22,
          )
          ..quadraticBezierTo(
            0.5 + side * _unitHeadR * 0.82,
            _headY - _unitHeadR * 0.12,
            0.5 + side * _unitHeadR * 0.88,
            _headY - _unitHeadR * 0.42,
          )
          ..close(),
        _fill(palette.hair),
      );
      canvas.restore();
    }

    _paintFace(canvas, head);
    canvas.restore();

    // The shirt opening sits in front of the neck base, so the neck reads as
    // going into a collar rather than resting on top of one.
    final bib = ui.Path()
      ..moveTo(0.5 - 0.058, neckBase - 0.026)
      ..quadraticBezierTo(0.5, neckBase + 0.016, 0.5 + 0.058, neckBase - 0.026)
      ..lineTo(0.5 + 0.058, neckBase + 0.090)
      ..lineTo(0.5 - 0.058, neckBase + 0.090)
      ..close();
    canvas.drawPath(bib, _fill(palette.shirt));
    final collar = ui.Path()
      ..moveTo(0.5 - 0.058, neckBase - 0.026)
      ..quadraticBezierTo(0.5, neckBase + 0.016, 0.5 + 0.058, neckBase - 0.026);
    canvas.drawPath(collar, _stroke(palette.sleeve, 0.013));
  }

  /// The face, sized for the ~270 pixel card it actually renders into.
  ///
  /// Anything below roughly eight device pixels stops reading as anatomy and
  /// starts reading as dirt, so this draws only what survives at that size:
  /// brows, two eyes, a nose, two lips. No shading planes, no creases.
  void _paintFace(Canvas canvas, ui.Path head) {
    // Feature offsets are authored against the reference head radius.
    final hs = _unitHeadR / _unitHeadRRef;
    final turn = pose.face.headTurn * 0.030;
    final eyeY = _headY + 0.014 * hs;
    final wide = 1.0 + pose.face.eyes.clamp(0.0, 1.0) * 0.32;
    final open = (1.0 - pose.face.blink.clamp(0.0, 1.0)).clamp(0.0, 1.0);
    final irisTone = ui.Color.lerp(palette.hair, palette.skinDeep, 0.45)!;

    canvas.save();
    canvas.clipPath(head);

    // Signed brow: positive raises, negative furrows. A furrow drops the brow
    // toward the lash line and pulls the inner end down toward the nose — the
    // inner drop is what reads as a wh-question rather than a heavy eyelid.
    final raise = pose.face.brow.clamp(0.0, 1.0);
    final furrow = (-pose.face.brow).clamp(0.0, 1.0);
    final browY = eyeY - 0.050 * hs - raise * 0.020 * hs + furrow * 0.016 * hs;
    final innerDrop = furrow * 0.012 * hs;
    final innerPinch = furrow * 0.004 * hs;

    for (final side in [-1.0, 1.0]) {
      final cx = 0.5 + side * 0.043 * hs + turn;
      // The brow has to clear the lash line by more than its own thickness.
      // At 0.034 the two merged into one dark blob per eye on the real card.
      canvas.drawPath(
        taperedPath(
          [
            Offset(
              cx - side * (0.022 * hs - innerPinch),
              browY + 0.0055 * hs + innerDrop,
            ),
            Offset(cx - side * innerPinch, browY - 0.0060 * hs + innerDrop * 0.5),
            Offset(cx + side * 0.020 * hs, browY + 0.0020 * hs),
          ],
          [0.0050 * hs, 0.0040 * hs, 0.0020 * hs],
        ),
        _fill(palette.hair),
      );

      final w = 0.0155 * hs;
      final h = 0.0165 * hs * wide * open;
      if (open < 0.22) {
        canvas.drawPath(
          ui.Path()
            ..moveTo(cx - w, eyeY + 0.0015 * hs)
            ..quadraticBezierTo(cx, eyeY + 0.012 * hs, cx + w, eyeY),
          _stroke(palette.face, 0.0060 * hs),
        );
        continue;
      }

      final eye = ui.Path()
        ..moveTo(cx - w, eyeY + 0.0015 * hs)
        ..quadraticBezierTo(cx, eyeY - h, cx + w, eyeY)
        ..quadraticBezierTo(cx, eyeY + h * 0.82, cx - w, eyeY + 0.0015 * hs)
        ..close();
      canvas.drawPath(eye, _fill(const ui.Color(0xFFFBF3EA)));
      canvas.save();
      canvas.clipPath(eye);
      // One large iris and pupil: at card size the whole eye is eight pixels,
      // and a limbal ring or lid shadow inside it only muddies those eight.
      // The iris is deliberately smaller than the eye's height so a band of
      // white survives under it — an iris that fills the almond reads as a
      // bruise rather than an eye.
      final iris = Offset(cx + turn * 0.45, eyeY + 0.0008 * hs);
      canvas.drawCircle(iris, 0.0072 * hs, _fill(irisTone));
      canvas.drawCircle(
        iris + Offset(0, 0.0004 * hs),
        0.0034 * hs,
        _fill(palette.face),
      );
      canvas.drawCircle(
        iris - Offset(0.0026 * hs, 0.0030 * hs),
        0.0018 * hs,
        _fill(const ui.Color(0xFFFFFFFF)),
      );
      canvas.restore();

      canvas.drawPath(
        ui.Path()
          ..moveTo(cx - w, eyeY + 0.0015 * hs)
          ..quadraticBezierTo(cx, eyeY - h, cx + w, eyeY),
        _stroke(palette.face, 0.0048 * hs),
      );
    }

    if (furrow > 0.3) {
      // Two short creases between the brows where the skin bunches. Gated on
      // a real furrow on purpose: as permanent lines they read as dirt.
      for (final side in [-1.0, 1.0]) {
        final x = 0.5 + side * 0.0055 * hs + turn;
        canvas.drawPath(
          ui.Path()
            ..moveTo(x, _headY - 0.003 * hs)
            ..quadraticBezierTo(
              x + side * 0.0015 * hs,
              _headY + 0.003 * hs,
              x,
              _headY + 0.009 * hs,
            ),
          _stroke(
            palette.skinDeep.withValues(alpha: 0.38 * furrow),
            0.0028 * hs,
          ),
        );
      }
    }

    // Nose: the tip and what it throws forward. A drawn bridge line reads as a
    // scratch at this size, and dark nostril dots in the middle read as a
    // smudge, so the alae sit wide apart and only half as dark.
    final nx = 0.5 + turn * 0.7;
    final tipY = _headY + 0.040 * hs;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(nx, tipY + 0.0060 * hs),
        width: 0.030 * hs,
        height: 0.014 * hs,
      ),
      _fill(palette.skinDeep.withValues(alpha: 0.30)),
    );
    for (final side in [-1.0, 1.0]) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(nx + side * 0.0108 * hs, tipY + 0.0034 * hs),
          width: 0.0056 * hs,
          height: 0.0038 * hs,
        ),
        _fill(palette.skinDeep.withValues(alpha: 0.55)),
      );
    }

    _paintMouth(canvas, turn, hs);
    canvas.restore();
  }

  void _paintMouth(Canvas canvas, double turn, double hs) {
    final mouthOpen = pose.face.mouth.clamp(0.0, 1.0);
    final smile = pose.face.smile.clamp(-1.0, 1.0);
    final soft = palette.skinDeep;
    final mouthY = _headY + 0.064 * hs;
    final half = (0.026 - mouthOpen * 0.005) * hs;
    // Positive smile drops the middle of the seam below the corners.
    final curve = (0.004 + smile * 0.015) * hs;
    final lip = ui.Color.lerp(
      palette.skinDeep,
      const ui.Color(0xFFC0705F),
      0.5,
    )!;
    final left = 0.5 - half + turn;
    final right = 0.5 + half + turn;
    final mid = 0.5 + turn;

    final upperH = 0.0080 * hs + smile.abs() * 0.001 * hs;
    canvas.drawPath(
      ui.Path()
        ..moveTo(left, mouthY)
        ..quadraticBezierTo(
          left + half * 0.42,
          mouthY - upperH * 0.95,
          mid - half * 0.14,
          mouthY - upperH,
        )
        ..quadraticBezierTo(
          mid - half * 0.05,
          mouthY - upperH * 0.55,
          mid,
          mouthY - upperH * 0.62,
        )
        ..quadraticBezierTo(
          mid + half * 0.05,
          mouthY - upperH * 0.55,
          mid + half * 0.14,
          mouthY - upperH,
        )
        ..quadraticBezierTo(
          right - half * 0.42,
          mouthY - upperH * 0.95,
          right,
          mouthY,
        )
        ..quadraticBezierTo(mid, mouthY + curve - 0.002 * hs, left, mouthY)
        ..close(),
      _fill(lip),
    );

    final lowerH = (0.0100 + mouthOpen * 0.030) * hs;
    canvas.drawPath(
      ui.Path()
        ..moveTo(left, mouthY)
        ..quadraticBezierTo(mid, mouthY + curve, right, mouthY)
        ..quadraticBezierTo(
          right - half * 0.30,
          mouthY + lowerH * 0.80,
          mid,
          mouthY + lowerH,
        )
        ..quadraticBezierTo(
          left + half * 0.30,
          mouthY + lowerH * 0.80,
          left,
          mouthY,
        )
        ..close(),
      _fill(ui.Color.lerp(lip, const ui.Color(0xFFFFFFFF), 0.16)!),
    );

    if (mouthOpen >= 0.10) {
      final inside = ui.Path()
        ..moveTo(left + half * 0.14, mouthY + curve * 0.40)
        ..quadraticBezierTo(
          mid,
          mouthY + lowerH * 0.74,
          right - half * 0.14,
          mouthY + curve * 0.40,
        )
        ..quadraticBezierTo(
          mid,
          mouthY + curve * 0.10,
          left + half * 0.14,
          mouthY + curve * 0.40,
        )
        ..close();
      canvas.drawPath(inside, _fill(const ui.Color(0xFF47282A)));
      canvas.save();
      canvas.clipPath(inside);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(mid, mouthY + curve * 0.26),
            width: half * 1.30,
            height: 0.009 * hs,
          ),
          Radius.circular(0.003 * hs),
        ),
        _fill(const ui.Color(0xFFF7F1E8)),
      );
      canvas.restore();
    }

    canvas.drawPath(
      ui.Path()
        ..moveTo(left, mouthY)
        ..quadraticBezierTo(mid, mouthY + curve, right, mouthY),
      _stroke(soft.withValues(alpha: 0.85), 0.0034 * hs),
    );
  }

  void _paintArm(
    Canvas canvas,
    ArmPose arm, {
    required double side,
    required bool back,
  }) {
    if (!arm.visible) return;

    final joints = armOf(pose, side);
    final shoulder = joints.shoulder;
    final elbow = joints.elbow;
    final wrist = joints.wrist;
    final a3 = joints.palmAngle;

    // The far arm sits in shade: the only depth cue a flat rig has.
    final skin = back
        ? ui.Color.lerp(palette.skin, palette.skinShade, 0.45)!
        : palette.skin;

    // One path for the whole limb, so the elbow never gains its own ring.
    final limb = ui.Path()
      ..moveTo(shoulder.dx, shoulder.dy)
      ..lineTo(elbow.dx, elbow.dy)
      ..lineTo(wrist.dx, wrist.dy);
    canvas.drawPath(limb, _stroke(palette.outline, _unitArm + _ink));
    canvas.drawPath(limb, _stroke(skin, _unitArm));

    _paintSleeve(
      canvas,
      shoulder,
      elbow,
      wrist,
      back: back,
      raise: _raiseOf(arm.shoulder),
    );
    _paintHand(
      canvas,
      arm,
      wrist: wrist,
      a3: a3,
      side: side,
      skin: skin,
      back: back,
    );
  }

  /// Short sleeve painted *inside* the arm silhouette. Clipping is what keeps
  /// it a sleeve: drawn free, the same shape floats off the limb as a pad.
  ///
  /// It also only exists while the arm is still hanging off the shoulder. A
  /// sleeve is cloth attached to a shirt, so it reads as one only while the
  /// upper arm drops from the body into the shirt's own silhouette. Two things
  /// break that: lifting the arm clear of the body, and folding the elbow far
  /// enough that the forearm comes back up — which is every sign whose hand
  /// sits at the face, and it leaves the band sitting right under the wrist,
  /// reading as an armband rather than a shoulder. Both retract it up and off
  /// the arm. Ramped rather than switched, because a hard cut pops mid-sign.
  void _paintSleeve(
    Canvas canvas,
    Offset shoulder,
    Offset elbow,
    Offset wrist, {
    required bool back,
    required double raise,
  }) {
    final forearmUp = ((elbow.dy - wrist.dy) / _unitFore).clamp(0.0, 1.0);
    final off = math.max(
      _ramp(0.25, 0.55, raise),
      _ramp(0.10, 0.45, forearmUp),
    );
    final coverage = 0.62 * (1 - off);
    if (coverage <= 0) return;
    final sleeve = back
        ? ui.Color.lerp(palette.sleeve, palette.shirtShade, 0.5)!
        : palette.sleeve;
    // The sleeve runs a little past the shoulder joint, up over the arm cap.
    // Starting at the joint leaves the top of the limb bare skin above the
    // shirt's shoulder line, which reads as a padded arm.
    final along = elbow - shoulder;
    final up = along.distance == 0
        ? Offset(0, -1)
        : Offset(along.dx / along.distance, along.dy / along.distance);
    final cap = _unitArm / 2 + _ink;
    final clip = ui.Path()
      ..addPath(
        taperedPath([shoulder - up * cap, elbow], [_unitArm / 2, _unitArm / 2]),
        Offset.zero,
      )
      ..addPath(
        taperedPath([elbow, wrist], [_unitArm / 2, _unitArm / 2]),
        Offset.zero,
      );

    canvas.save();
    canvas.clipPath(clip);
    final end = shoulder + along * coverage;
    canvas.drawPath(
      ui.Path()
        ..moveTo(shoulder.dx, shoulder.dy)
        ..lineTo(end.dx, end.dy),
      _stroke(sleeve, _unitArm + _ink * 2),
    );
    // Hem: a darker band at the cut edge, plus a shadow just inside it.
    final perp = Offset(-up.dy, up.dx);
    canvas.drawLine(
      end - perp * _unitArm,
      end + perp * _unitArm,
      _stroke(palette.shirtShade, 0.010),
    );
    canvas.restore();
  }

  /// A filled outline through [pts] with a half-width at each point: square at
  /// the first point, which is buried in the parent bone, and round at the tip.
  /// Everything soft-tissue gets drawn with this, which is what lets a finger
  /// narrow toward the nail instead of reading as a capsule.
  ///
  /// [closeBase] false leaves the square end open, tracing only the two edges
  /// and the round tip. That is the stroke a digit re-inked over a merged
  /// silhouette wants: the base chord would cut across it like a seam and make
  /// the digit look severed at its root.
  ///
  /// Exposed so the test suite can prove the contour stays simple — see
  /// `test/avatar/hand_union_test.dart`.
  @visibleForTesting
  static ui.Path taperedPath(
    List<Offset> pts,
    List<double> halfWidths, {
    bool closeBase = true,
  }) {
    Offset dirAt(int i) {
      // One-sided at both ends. Sampling `prev` and `next` at the ends collapses
      // the difference to zero and falls through to the (0, 1) default, which
      // hard-codes every chain as pointing down — and carves a notch instead of
      // a round cap on any finger that points up.
      final prev = i == 0 ? pts[i] : pts[i - 1];
      final next = i == pts.length - 1 ? pts[i] : pts[i + 1];
      var d = next - prev;
      // A sharp fold puts the tip almost back on the base, and the central
      // difference there is a near-zero vector whose direction is noise. That
      // rotated the knuckle normal the wrong way and grew a spike on the
      // outline. Below one half-width the chord says nothing about the local
      // direction, so fall back to the segment coming in.
      if (d.distance < halfWidths[i]) {
        d = i == 0 ? pts[1] - pts[0] : pts[i] - pts[i - 1];
      }
      if (d.distance == 0) return const Offset(0, 1);
      return d / d.distance;
    }

    final left = <Offset>[];
    final right = <Offset>[];
    for (var i = 0; i < pts.length; i++) {
      final d = dirAt(i);
      final n = Offset(-d.dy, d.dx) * halfWidths[i];
      left.add(pts[i] + n);
      right.add(pts[i] - n);
    }

    final path = ui.Path()..moveTo(left.first.dx, left.first.dy);
    for (final p in left.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    final tipDir = dirAt(pts.length - 1);
    final tipPerp = Offset(-tipDir.dy, tipDir.dx);
    // `useCenter: false` matters: routing the cap through the oval's centre
    // makes the digit self-intersect, and a self-intersecting contour is what
    // stops the hand's union below from merging the fingers into one outline.
    path.arcTo(
      Rect.fromCircle(center: pts.last, radius: halfWidths.last),
      math.atan2(tipPerp.dy, tipPerp.dx),
      -math.pi,
      false,
    );
    for (final p in right.reversed) {
      path.lineTo(p.dx, p.dy);
    }
    return closeBase ? (path..close()) : path;
  }

  /// The five digits as joint chains — base, knuckle, tip — in hand-local space,
  /// each with the half-width to draw its three links at. Fingers first, thumb
  /// last, which is the order [_seams] walks neighbours in.
  static ({List<List<Offset>> bones, List<List<double>> halves}) _digitChains(
    HandShape hand,
    double side,
  ) {
    final curls = [hand.index, hand.middle, hand.ring, hand.pinky];
    // No two fingers are the same: the middle leads, the pinky is three
    // quarters the length, and each is a little narrower than its neighbour.
    const lengthScale = [0.94, 1.00, 0.92, 0.76];
    const widthScale = [0.98, 1.00, 0.94, 0.90];

    final bones = <List<Offset>>[];
    final halves = <List<double>>[];
    final spread = 1 + hand.spread * 1.25;
    for (var i = 0; i < 4; i++) {
      final fan = side * (i - 1.5) * _unitFingerGap * spread;
      final curl = curls[i].clamp(0.0, 1.0);
      final hw = _unitFinger / 2 * widthScale[i];
      // A fold turns to 112 degrees and then finishes by shrinking. Turning
      // further lays the second link back beside the first, so the finger
      // becomes a hairpin: its tip surfaces under its own knuckle and pokes
      // out past its neighbour, which is what drew a sawtooth on a fist and a
      // gear-tooth crown on a bent hand. Past the cap the remaining curl is
      // spent on foreshortening instead, so the finger sinks toward the
      // knuckle line the way a real one does into a palm.
      final turn = curl * 2.30;
      final past = ((turn - _maxFold) / (2.30 - _maxFold)).clamp(0.0, 1.0);
      final bend = math.min(turn, _maxFold);
      // Two real joints. The knuckle only tilts the finger toward the thumb
      // side; the middle knuckle does nearly all the closing. The +0.13 keeps
      // an "extended" finger from looking like a board.
      final mcp = bend * 0.28;
      final pip = 0.13 + bend * 0.72;
      final near =
          _unitFinger1 * lengthScale[i] * (1 - curl * 0.10 - past * 0.46);
      final far = math.max(
        _unitFinger2 * lengthScale[i] * (1 - curl * 0.28 - past * 0.50),
        hw * 1.2,
      );
      // A slight inward lean, so the fan converges on the palm midline the way
      // knuckles do instead of spreading outward and opening daylight.
      final splay = -fan * 0.22;
      final base = Offset(fan, _unitPalm * 0.90);
      // The second joint sits a little *inside* its knuckle. Pushing it out
      // (a positive factor here) is what turned an open hand into five separate
      // prongs: it widens the spacing to 1.3x the knuckle spacing before the
      // taper even starts.
      final knuckle =
          base + _spin(Offset(fan * -0.25, near), side * mcp + splay);
      final tip = knuckle + _spin(Offset(0, far), side * (mcp + pip) + splay);
      bones.add([base, knuckle, tip]);
      // Nearly no taper. A finger that narrows toward the tip stops touching its
      // neighbour exactly where the eye looks for contact, and the exposed ink
      // reads as a black sliver.
      halves.add([hw, hw * 0.98, hw * 0.97]);
    }

    // Thumb: tucked across the palm at 0, out beside the index at 1. `thumbUp`
    // pulls the swing back to vertical, which is what ASL A and the 5-hand do.
    final thumbOut = hand.thumb.clamp(0.0, 1.0);
    // x direction the thumb points in, so the palm and its creases mirror.
    final t = -side;
    final swing =
        (-0.55 + thumbOut * 1.80 + hand.thumbSpread * 0.35) *
        (1 - hand.thumbUp.clamp(0.0, 1.0) * 0.85) *
        side;
    final thumbBase = Offset(t * _unitPalmWide * 0.34, _unitPalm * 0.40);
    final thumbMid = thumbBase + _spin(Offset(t * 0.004, _unitThumb1), swing);
    final thumbTip =
        thumbMid +
        _spin(Offset(0, _unitThumb2), swing + side * (0.45 - thumbOut * 0.55));
    bones.add([thumbBase, thumbMid, thumbTip]);
    halves.add([0.0112, 0.0102, 0.0086]);

    return (bones: bones, halves: halves);
  }

  static List<ui.Path> _digitPaths(
    List<List<Offset>> bones,
    List<List<double>> halves,
  ) => [
    for (var i = 0; i < bones.length; i++) taperedPath(bones[i], halves[i]),
  ];

  /// The thread-thin lines that tell the eye there are four fingers and not one
  /// paddle, computed from the drawn digit paths alone.
  ///
  /// Each candidate is walked along the midline between two neighbouring
  /// fingers — base midpoint to tip midpoint — and kept only for the stretch
  /// where a point lies inside *both* digit paths, which is exactly where the two
  /// touch, and outside the palm, which is what keeps the line off the hand's
  /// body. Starting the walk at the knuckle instead (its first 30% was skipped
  /// for years) cut the thread down to the distal half, so a card-size hand read
  /// as a paddle with tick marks at the fingertips rather than four fingers.
  ///
  /// What is left then has to be long enough to read, and that cut is the whole
  /// tuning surface. It sits in the empty band between two populations measured
  /// by walking a hand whose four fingers curl together from 0 to 1 in 0.05
  /// steps: every pair of a hand open to curl 0.70 contacts for 0.0485–0.0711
  /// unit (13.8–20.2px on a 284px card), and every pair of a hand closed to curl
  /// 0.95 or more for at most 0.0342 (9.7px). Nothing at all lands between, so
  /// the cut goes on the midpoint of that gap (0.0408) rather than a hair above
  /// the closed edge — a cut that hugs one population breaks the moment the
  /// fold changes, which is the exact bug an earlier 1.2-finger-width cut
  /// shipped. Below the cut a thread is a stray dash on the back of the hand
  /// rather than a finger edge. An earlier version also compared the authored
  /// curls (`(curls[i] - curls[i + 1]).abs() > 0.35`); measured across the
  /// library that comparison rejects nothing this one keeps, so it is gone.
  static List<ui.Path> _seams(
    List<List<Offset>> bones,
    List<ui.Path> digits,
    ui.Path palm,
  ) =>
      [
        for (final run in _seamRuns(bones, digits, palm))
          if (run.length > _unitFinger * 2.4) run.run,
      ];

  /// The contact stretch found for each of the three finger pairs, gated or not.
  static List<({ui.Path run, double length})> _seamRuns(
    List<List<Offset>> bones,
    List<ui.Path> digits,
    ui.Path palm,
  ) {
    final runs = <({ui.Path run, double length})>[];
    Offset mid(List<Offset> near, List<Offset> far, int joint) => Offset(
          (near[joint].dx + far[joint].dx) / 2,
          (near[joint].dy + far[joint].dy) / 2,
        );
    for (var i = 0; i < 3; i++) {
      final near = bones[i], far = bones[i + 1];
      // The valley follows the fingers' own links. A straight base-to-tip chord
      // cuts the inside corner of a bent finger and misses both digit paths
      // there, which silently dropped every half-closed thread.
      final root = mid(near, far, 0);
      final bend = mid(near, far, 1);
      final high = mid(near, far, 2);
      final run = ui.Path();
      var open = false;
      var length = 0.0;
      Offset? prev;
      final samples = <Offset>[
        for (var s = 0; s < 24; s++) root + (bend - root) * (s / 24),
        for (var s = 0; s <= 24; s++) bend + (high - bend) * (s / 24),
      ];
      for (final p in samples) {
        if (palm.contains(p) ||
            !digits[i].contains(p) ||
            !digits[i + 1].contains(p)) {
          if (open) break;
          continue;
        }
        if (open) {
          run.lineTo(p.dx, p.dy);
          length += (p - prev!).distance;
        } else {
          run.moveTo(p.dx, p.dy);
          open = true;
        }
        prev = p;
      }
      runs.add((run: run, length: open ? length : 0));
    }
    return runs;
  }

  /// The seams this painter will ink for [hand], in hand-local space. Exposed so
  /// the suite can pin the cases the geometry has to get right — see
  /// `test/avatar/hand_seam_test.dart`.
  @visibleForTesting
  static List<ui.Path> fingerSeams(HandShape hand, double side) {
    final chains = _digitChains(hand, side);
    return _seams(
      chains.bones,
      _digitPaths(chains.bones, chains.halves),
      _palmLocalPath(side),
    );
  }

  /// The centre-lines of the five digits, in hand-local unit space. Exposed so
  /// the suite can measure where a fingertip actually lands — the contact
  /// helpers below only see finger *neighbours*, never the thumb, so a shape
  /// that is supposed to close on the thumb has nothing else to check it with.
  @visibleForTesting
  static List<List<Offset>> digitBones(HandShape hand, double side) =>
      _digitChains(hand, side).bones;

  /// The contact length found for each of the three finger pairs, *before* the
  /// `_seams` cut throws the short ones away. Exposed because that cut is the
  /// only tuning knob the threads have, and a knob you cannot read is a knob
  /// you can only guess at.
  @visibleForTesting
  static List<double> fingerContact(HandShape hand, double side) {
    final chains = _digitChains(hand, side);
    return [
      for (final run in _seamRuns(
        chains.bones,
        _digitPaths(chains.bones, chains.halves),
        _palmLocalPath(side),
      ))
        run.length,
    ];
  }

  void _paintHand(
    Canvas canvas,
    ArmPose arm, {
    required Offset wrist,
    required double a3,
    required double side,
    required ui.Color skin,
    required bool back,
  }) {
    canvas.save();
    canvas.translate(wrist.dx, wrist.dy);
    canvas.rotate(_palmRotation(a3));

    // Which face reads to the viewer: `palm` 0 = palm, 180 = back of hand.
    final facing = 1.0 - arm.palm.abs().clamp(0.0, 180.0) / 180.0;
    final palmFill = facing > 0.5
        ? skin
        : ui.Color.lerp(skin, palette.skinShade, 0.40)!;

    final chains = _digitChains(arm.hand, side);
    final bones = chains.bones;
    final digits = _digitPaths(bones, chains.halves);

    // Palm and all five digits are unioned into one contour before anything is
    // painted. Inked part by part — even all-then-filled — each digit still
    // leaves a sliver of its own outline where a neighbour's fill does not
    // quite reach, and on the card those slivers are the "gap between fingers"
    // complaint. A single merged silhouette has no interior outline to leak.
    final hand = _handLocalPath(bones, chains.halves, side);
    canvas.drawPath(hand, _stroke(palette.outline, _ink * 0.44));
    canvas.drawPath(hand, _fill(palmFill));

    // The union has no interior outline, so these threads are the only thing
    // that tells the eye there are four fingers and not one paddle. Each one is
    // two strokes: a soft skin shade that reads as the valley between two
    // cylinders at card size, and the ink line itself on top.
    final valley = _stroke(palette.skinShade, _ink * 0.9)
      ..color = palette.skinShade.withValues(alpha: 0.55);
    final seam = _stroke(palette.outline, _ink * 0.42);
    final palm = _palmLocalPath(side);
    for (final run in _seams(bones, digits, palm)) {
      canvas.drawPath(run, valley);
      canvas.drawPath(run, seam);
    }

    // The union that makes the four fingers one silhouette also erases the
    // thumb: once it tucks across the palm its edges are interior and the hand
    // reads as a four-fingered mound. Re-inking the thumb on top gives it back
    // both edges and its round tip wherever it lies — across a fist, a pointing
    // hand or a pinch — while an extended thumb's outline lands on the silhouette
    // it already had. The base stays open so the digit grows out of the palm
    // instead of ending on a straight seam at its root.
    canvas.drawPath(digits.last, _fill(palmFill));
    canvas.drawPath(
      taperedPath(bones.last, chains.halves.last, closeBase: false),
      _stroke(palette.outline, _ink * 0.44),
    );

    canvas.restore();
  }

  /// The palm plus all five digits unioned into one contour, in hand-local
  /// space. [_paintHand] draws it under the wrist transform; [handUnitPath]
  /// maps it into unit space for the contact shadow.
  static ui.Path _handLocalPath(
    List<List<Offset>> bones,
    List<List<double>> halves,
    double side,
  ) {
    final digits = _digitPaths(bones, halves);
    var hand = digits.first;
    for (final part in digits.skip(1)) {
      hand = ui.Path.combine(ui.PathOperation.union, hand, part);
    }
    return ui.Path.combine(
      ui.PathOperation.union,
      hand,
      _palmLocalPath(side),
    );
  }

  /// The palm alone, in hand-local space. The seams need it separately: a
  /// thread is only drawn where a finger has already left the palm.
  ///
  /// The palm stops at the knuckle line instead of bulging past it. Inked any
  /// lower, its bottom edge survives as a dark band across the hand, because
  /// nothing covers the arc in the seam between two fingers.
  static ui.Path _palmLocalPath(double side) {
    final t = -side;
    return ui.Path()
      ..moveTo(t * _unitPalmWide * 0.46, _unitPalm * 0.86)
      ..quadraticBezierTo(
        t * _unitPalmWide * 0.64,
        _unitPalm * 0.50,
        t * _unitPalmWide * 0.40,
        _unitPalm * 0.04,
      )
      ..quadraticBezierTo(
        0,
        -_unitPalm * 0.12,
        -t * _unitPalmWide * 0.38,
        _unitPalm * 0.02,
      )
      ..quadraticBezierTo(
        -t * _unitPalmWide * 0.46,
        _unitPalm * 0.50,
        -t * _unitPalmWide * 0.44,
        _unitPalm * 0.86,
      )
      ..quadraticBezierTo(
        0,
        _unitPalm * 0.98,
        t * _unitPalmWide * 0.46,
        _unitPalm * 0.86,
      )
      ..close();
  }

  /// [_handLocalPath] mapped into unit canvas space: translated to [wrist] and
  /// rotated to the palm angle, the same transform [_paintHand] applies. The
  /// contact shadow works on these, so the suite can pin the geometry without
  /// a golden.
  @visibleForTesting
  static ui.Path handUnitPath(
    ArmPose arm,
    Offset wrist,
    double a3,
    double side,
  ) {
    final chains = _digitChains(arm.hand, side);
    final local = _handLocalPath(chains.bones, chains.halves, side);
    final m = Matrix4.identity()
      ..translateByDouble(wrist.dx, wrist.dy, 0, 1)
      ..rotateZ(_palmRotation(a3));
    return local.transform(m.storage);
  }

  /// The head silhouette in unit space, carrying the painter's tilt transform,
  /// so a hand-to-face shadow lands exactly where the head is actually drawn.
  @visibleForTesting
  static ui.Path headUnitPath(SignPose pose) {
    final headY = _unitHeadY - pose.breath * 0.007 * 1.6;
    final oval = ui.Path()
      ..addOval(
        Rect.fromCircle(center: Offset(0.5, headY), radius: _unitHeadR),
      );
    final pivotY = headY + _unitHeadR * 0.9;
    final m = Matrix4.identity()
      ..translateByDouble(0.5, pivotY, 0, 1)
      ..rotateZ(degrees(pose.face.headTilt))
      ..translateByDouble(-0.5, -pivotY, 0, 1);
    return oval.transform(m.storage);
  }

  /// The region where [caster] overlaps [receiver] — the pressed crease a
  /// touching hand casts — or null when the two silhouettes never meet. A hand
  /// hovering in signing space must cast nothing, which is why this is
  /// intersection geometry rather than a glow under the wrist.
  @visibleForTesting
  static ui.Path? contactShadow(ui.Path caster, ui.Path receiver) {
    if (!caster.getBounds().overlaps(receiver.getBounds())) return null;
    final overlap = ui.Path.combine(
      ui.PathOperation.intersect,
      caster,
      receiver,
    );
    final bounds = overlap.getBounds();
    if (bounds.width <= 0 || bounds.height <= 0) return null;
    return overlap;
  }

  void _paintContactShadow(
    Canvas canvas, {
    required ui.Path caster,
    required ui.Path receiver,
  }) {
    final shadow = contactShadow(caster, receiver);
    if (shadow != null) canvas.drawPath(shadow, _contactShadowPaint);
  }

  Paint _fill(ui.Color color) => Paint()..color = color;

  Paint _stroke(ui.Color color, double width) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  void _strokedFill(
    Canvas canvas,
    ui.Path path,
    ui.Color color, {
    double? stroke,
    double? ink,
  }) {
    if (stroke != null) {
      canvas.drawPath(path, _stroke(palette.outline, stroke + (ink ?? _ink)));
      canvas.drawPath(path, _stroke(color, stroke));
      return;
    }
    canvas.drawPath(path, _stroke(palette.outline, (ink ?? _ink) * 2));
    canvas.drawPath(path, _fill(color));
  }

  /// Unit direction from an angle measured off "straight down", positive
  /// toward the viewer's right.
  static Offset _dir(double screenDegrees) {
    final rad = degrees(screenDegrees);
    return Offset(math.sin(rad), math.cos(rad));
  }

  static Offset _spin(Offset point, double radians) => Offset(
    point.dx * math.cos(radians) - point.dy * math.sin(radians),
    point.dx * math.sin(radians) + point.dy * math.cos(radians),
  );

  /// Canvas rotation aligning the local +y axis with the outgoing forearm.
  static double _palmRotation(double a3) => -degrees(a3);

  @override
  bool shouldRepaint(covariant AvatarPainter oldDelegate) =>
      oldDelegate.pose != pose || oldDelegate.palette != palette;
}
