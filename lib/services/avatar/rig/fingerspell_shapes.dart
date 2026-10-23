import 'sign_pose.dart';

/// Manual alphabet used by the fingerspelling fallback.
///
/// These are approximations of the one-handed fingerspelling handshapes,
/// shared by ASL and ISL. Unknown glosses are spelled out with them rather
/// than shown as a made-up sign, so the viewer always gets the letters.
///
/// F, O and Q are the three letters whose whole identity is the index tip
/// touching the thumb, so their curls are measured against that contact rather
/// than picked — see [HandShape.pinch], which carries the numbers. The rest are
/// distinguished by which fingers stand up, and stay open on purpose.
abstract final class FingerspellShapes {
  static const letters = <String, HandShape>{
    'a': HandShape(
      index: 1,
      middle: 1,
      ring: 1,
      pinky: 1,
      thumb: 0.85,
      thumbUp: 1,
      thumbSpread: 0.25,
    ),
    'b': HandShape(index: 0, middle: 0, ring: 0, pinky: 0, thumb: 0.25),
    'c': HandShape(
      index: 0.5,
      middle: 0.5,
      ring: 0.5,
      pinky: 0.5,
      thumb: 0.45,
      thumbSpread: 0.5,
    ),
    'd': HandShape(index: 0, middle: 0.8, ring: 0.85, pinky: 0.85, thumb: 0.5),
    'e': HandShape(index: 0.8, middle: 0.8, ring: 0.8, pinky: 0.8, thumb: 0.3),
    'f': HandShape(index: 0.88, middle: 0, ring: 0, pinky: 0, thumb: 0.34),
    'g': HandShape(
      index: 0.3,
      middle: 1,
      ring: 1,
      pinky: 1,
      thumb: 0.3,
      thumbSpread: 0.5,
    ),
    'h': HandShape(index: 0, middle: 0, ring: 1, pinky: 1, thumb: 0.5),
    'i': HandShape(index: 1, middle: 1, ring: 1, pinky: 0, thumb: 0.4),
    'j': HandShape(index: 1, middle: 1, ring: 1, pinky: 0, thumb: 0.4),
    'k': HandShape(
      index: 0,
      middle: 0,
      ring: 1,
      pinky: 1,
      thumb: 0.55,
      thumbSpread: 0.8,
      spread: 0.5,
    ),
    'l': HandShape(
      index: 0,
      middle: 1,
      ring: 1,
      pinky: 1,
      thumb: 1,
      thumbSpread: 1,
    ),
    'm': HandShape(index: 0.9, middle: 0.9, ring: 0.9, pinky: 1, thumb: 0.15),
    'n': HandShape(index: 0.9, middle: 0.9, ring: 1, pinky: 1, thumb: 0.15),
    'o': HandShape.o,
    'p': HandShape(index: 0, middle: 0.6, ring: 1, pinky: 1, thumb: 0.6),
    'q': HandShape(index: 0.88, middle: 1, ring: 1, pinky: 1, thumb: 0.40),
    'r': HandShape(index: 0, middle: 0, ring: 1, pinky: 1, thumb: 0.6),
    's': HandShape(index: 1, middle: 1, ring: 1, pinky: 1, thumb: 0.2),
    't': HandShape(index: 1, middle: 1, ring: 1, pinky: 1, thumb: 0.55),
    'u': HandShape(index: 0, middle: 0, ring: 1, pinky: 1, thumb: 0.5),
    'v': HandShape(
      index: 0,
      middle: 0,
      ring: 1,
      pinky: 1,
      thumb: 0.5,
      spread: 0.85,
    ),
    'w': HandShape(
      index: 0,
      middle: 0,
      ring: 0,
      pinky: 1,
      thumb: 0.5,
      spread: 0.7,
    ),
    'x': HandShape(index: 0.4, middle: 1, ring: 1, pinky: 1, thumb: 0.5),
    'y': HandShape(
      index: 1,
      middle: 1,
      ring: 1,
      pinky: 0,
      thumb: 1,
      thumbSpread: 1,
    ),
    'z': HandShape(index: 0, middle: 1, ring: 1, pinky: 1, thumb: 0.6),
  };

  static HandShape forLetter(String letter) =>
      letters[letter.toLowerCase()] ?? HandShape.flat;
}
