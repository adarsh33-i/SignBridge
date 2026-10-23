import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../translate/sign_token.dart';
import 'fingerspell_shapes.dart';
import 'indic_spelling.dart';
import 'sign_animation.dart';
import 'sign_pose.dart';

/// Authored hand movements, keyed on the ids the gloss engine emits.
///
/// Coverage is deliberately tiered: a core vocabulary has real, authored
/// motion, non-manual markers drive the face only, and anything else is
/// fingerspelled letter by letter. No gloss is ever rendered as a random
/// made-up sign.
abstract final class SignLibrary {
  /// Silence between two signs so the boundary reads as a word break.
  static const restGap = Duration(milliseconds: 120);

  static SignAnimation? forToken(SignToken token) {
    if (token.id == SignToken.thinking.id) return null;
    final authored =
        _core[token.id] ??
        _core[_weatherAliases[token.id] ?? ''] ??
        _core[_baseOf(token.id)];
    if (authored != null) return authored;
    if (token.id.startsWith('nmm_')) return _marker(token.id);
    // An id the lexicon never saw keeps its caption script: a Hindi, Tamil or
    // Malayalam word arrives as गर्म, which has no letter the manual alphabet
    // knows. Spelling the sounds it writes is the only sign available, and it
    // is what ISL does for a word with no sign of its own.
    final word = IndicSpelling.toLatin(token.id).replaceAll('_', '');
    if (!_hasLetter(word)) return null;
    return fingerspell(word);
  }

  /// ASL-LEX numbers the variants of one sign — `snow_2`, `cloud_4` — and the
  /// id the gloss engine hands over is the numbering, not the sign. An authored
  /// animation has to answer for all of them or the second variant of a word
  /// is spelled while the first one is signed.
  static String _baseOf(String id) {
    final match = RegExp(r'^(.*)_\d+$').firstMatch(id);
    return match == null ? id : match.group(1)!;
  }

  /// Words the lexicon gives their own id, signed as the base word.
  ///
  /// This is only for a word whose id names the very sign that is already
  /// authored — the `-y` weather forms, and THERMOMETER, which the gloss engine
  /// also emits for `temperature`. It is not for a word that merely means
  /// something close: HUG is not LOVE and CONSUME is not EAT, so those get their
  /// own animation instead of being pointed at a neighbour's.
  static const _weatherAliases = {
    'cloudy': 'cloud',
    'snowy': 'snow',
    'rainy': 'rain',
    'sunny': 'sun',
    'foggy': 'fog',
    'stormy': 'storm',
    'freezing': 'cold',
    'chilly': 'cold',
    'thermometer': 'temperature',
  };

  static bool _hasLetter(String word) => word.runes.any(
    (u) => (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A),
  );

  /// Expands a gloss sequence into the animations to play, one per token.
  static List<SignAnimation> forSequence(List<SignToken> sequence) {
    final out = <SignAnimation>[];
    for (final token in sequence) {
      final animation = forToken(token);
      if (animation != null) out.add(animation);
    }
    return out;
  }

  /// One-handed letters travelled in sequence, each with a small tap so the
  /// boundary between letters stays visible.
  static SignAnimation fingerspell(String word) {
    final letters = word.split('').where(FingerspellShapes.letters.containsKey);
    final keys = <PoseKey>[
      PoseKey(pose: _hand(HandShape.relax), travelMs: 120, holdMs: 40),
    ];
    for (final letter in letters) {
      keys.add(
        PoseKey(
          pose: _hand(FingerspellShapes.letters[letter]!),
          travelMs: 110,
          holdMs: 90,
        ),
      );
      // A slight drop between letters reads as the tap that separates them.
      keys.add(
        PoseKey(
          pose: _hand(FingerspellShapes.letters[letter]!, lower: 9),
          travelMs: 60,
          holdMs: 20,
        ),
      );
    }
    keys.add(PoseKey(pose: _hand(HandShape.relax), travelMs: 120, holdMs: 40));
    return SignAnimation(
      id: 'spell_$word',
      gloss: word.toUpperCase(),
      keys: keys,
    );
  }

  static SignAnimation? _marker(String id) {
    return switch (id) {
      // wh-questions furrow: the brows come down, they do not rise. The
      // y/n-q marker below owns the raised-brow face.
      'nmm_whQ' => _faceOnly(
        id,
        '[wh-q]',
        const FacePose(brow: -0.85, headTilt: -6, headTurn: 0.3),
      ),
      'nmm_ynQ' => _faceOnly(
        id,
        '[y/n-q]',
        const FacePose(brow: 0.7, headTilt: 5),
      ),
      'nmm_rhQ' => _faceOnly(
        id,
        '[rh-q]',
        const FacePose(brow: 0.8, headTurn: -0.7, eyes: 0.5),
      ),
      'nmm_headshake' => _faceOnly(
        id,
        '[headshake]',
        const FacePose(brow: 0.5, mouth: 0.2),
        sway: true,
      ),
      'nmm_mm' => _faceOnly(id, '[mm]', const FacePose(mouth: 0.45)),
      'nmm_cha' => _faceOnly(
        id,
        '[cha]',
        const FacePose(brow: 0.6, mouth: 0.3),
      ),
      'nmm_th' => _faceOnly(id, '[th]', const FacePose(mouth: 0.2)),
      'nmm_cs' => _faceOnly(id, '[cs]', const FacePose(headTurn: 0.6)),
      'nmm_roleShift' => _faceOnly(
        id,
        '[role-shift]',
        const FacePose(headTurn: -0.8, shift: -0.5),
      ),
      _ => null,
    };
  }

  static SignAnimation _faceOnly(
    String id,
    String gloss,
    FacePose face, {
    bool sway = false,
  }) {
    final neutral = SignPose(
      name: id,
      left: ArmPose.resting,
      right: ArmPose.resting,
      face: FacePose.neutral,
    );
    final marked = SignPose(
      name: id,
      left: ArmPose.resting,
      right: ArmPose.resting,
      face: face,
    );
    if (!sway) {
      return SignAnimation(
        id: id,
        gloss: gloss,
        faceOnly: true,
        keys: [
          PoseKey(pose: neutral, travelMs: 0, holdMs: 40),
          PoseKey(pose: marked, travelMs: 180, holdMs: 260),
        ],
      );
    }
    final left = SignPose(
      name: id,
      left: ArmPose.resting,
      right: ArmPose.resting,
      face: FacePose(
        brow: face.brow,
        mouth: face.mouth,
        headTilt: face.headTilt,
        headTurn: -0.8,
      ),
    );
    final right = SignPose(
      name: id,
      left: ArmPose.resting,
      right: ArmPose.resting,
      face: FacePose(
        brow: face.brow,
        mouth: face.mouth,
        headTilt: face.headTilt,
        headTurn: 0.8,
      ),
    );
    return SignAnimation(
      id: id,
      gloss: gloss,
      faceOnly: true,
      keys: [
        PoseKey(pose: left, travelMs: 0, holdMs: 60),
        PoseKey(pose: right, travelMs: 170, holdMs: 60),
      ],
      repeat: 2,
      pingpong: true,
    );
  }

  /// Every authored core animation, for duration-budget tests that would
  /// otherwise have no way to enumerate the lexicon.
  @visibleForTesting
  static Map<String, SignAnimation> get debugCore => _core;

  static final Map<String, SignAnimation> _core = {
    'hello': SignAnimation(
      id: 'hello',
      gloss: 'HELLO',
      keys: [
        // The salute starts on the temple, not beside it, and the fingers stay
        // up rather than laying across the eyes.
        _k(
          _atFace(HandShape.flat, _FaceSpot.temple, wrist: -14),
          travel: 0,
          hold: 90,
        ),
        _k(
          _hand(HandShape.flat, shoulder: 78, elbow: 128, lift: 0.4),
          hold: 70,
        ),
      ],
      repeat: 2,
      pingpong: true,
    ),

    // Index fingertip taps the sternum: ME.
    // Measured, not guessed: at these angles the fingertip lands on (0.51,
    // 0.50) of the card, and the wrist stays off the shirt.
    'me': SignAnimation(
      id: 'me',
      gloss: 'ME',
      keys: [
        _k(
          _hand(HandShape.point, shoulder: 52, elbow: 196, wrist: 50, lift: 0.4),
          travel: 0,
          hold: 80,
        ),
        _k(
          _hand(HandShape.point, shoulder: 46, elbow: 188, wrist: 44, lift: 0.4),
          hold: 60,
        ),
      ],
      repeat: 2,
    ),

    // Index across the space between the two bodies: YOU.
    'you': SignAnimation(
      id: 'you',
      gloss: 'YOU',
      keys: [
        _k(
          _hand(
            HandShape.point,
            shoulder: 54,
            elbow: 162,
            wrist: -16,
            lift: 0.5,
          ),
          travel: 0,
          hold: 70,
        ),
        _k(
          _hand(
            HandShape.point,
            shoulder: 66,
            elbow: 152,
            wrist: -20,
            lift: 0.42,
          ),
          hold: 160,
        ),
      ],
    ),

    // Flat hand leaves the chin and moves out: THANK-YOU.
    'thank_you': SignAnimation(
      id: 'thank_you',
      gloss: 'THANK-YOU',
      keys: [
        _k(
          _atFace(HandShape.flat, _FaceSpot.chin, wrist: -10),
          travel: 0,
          hold: 110,
        ),
        _k(
          _hand(HandShape.flat, shoulder: 84, elbow: 96, lift: 0.2),
          hold: 150,
        ),
      ],
    ),

    // Small circle on the chest: PLEASE.
    'please': SignAnimation(
      id: 'please',
      gloss: 'PLEASE',
      keys: [
        _k(
          _hand(HandShape.flat, shoulder: 26, elbow: 176, lower: 6),
          travel: 0,
          hold: 60,
        ),
        _k(
          _hand(
            HandShape.flat,
            shoulder: 20,
            elbow: 186,
            lower: -6,
            lift: 0.62,
          ),
          hold: 60,
        ),
        _k(_hand(HandShape.flat, shoulder: 26, elbow: 176, lower: 6), hold: 60),
      ],
      repeat: 2,
    ),

    // Fist nods at chin height: YES.
    'yes': SignAnimation(
      id: 'yes',
      gloss: 'YES',
      keys: [
        _k(
          _hand(HandShape.fist, shoulder: 22, elbow: 184, lower: -10),
          travel: 0,
          hold: 70,
        ),
        _k(_hand(HandShape.fist, shoulder: 22, elbow: 168, lower: 8), hold: 90),
      ],
      repeat: 2,
      pingpong: true,
    ),

    // Index finger snaps down against the thumb: NO.
    'no': SignAnimation(
      id: 'no',
      gloss: 'NO',
      keys: [
        _k(
          _hand(HandShape.point, shoulder: 20, elbow: 186, wrist: -18),
          travel: 0,
          hold: 60,
        ),
        _k(
          _hand(HandShape.fist, shoulder: 20, elbow: 186, wrist: -18),
          hold: 70,
        ),
      ],
      repeat: 2,
    ),

    // Bent hand drops onto the flat non-dominant palm, twice: GOOD.
    'good': SignAnimation(
      id: 'good',
      gloss: 'GOOD',
      keys: [
        _k(
          _two(HandShape.bent, HandShape.flat, shoulder: 46, elbow: 176),
          travel: 0,
          hold: 70,
        ),
        _k(
          _two(HandShape.fist, HandShape.flat, shoulder: 30, elbow: 172),
          hold: 90,
        ),
      ],
      repeat: 2,
    ),

    // Same place, thumb pointing down: BAD.
    'bad': SignAnimation(
      id: 'bad',
      gloss: 'BAD',
      keys: [
        _k(
          _two(
            HandShape.bent,
            HandShape.flat,
            shoulder: 30,
            elbow: 172,
            invert: true,
          ),
          travel: 0,
          hold: 70,
        ),
        _k(
          _two(
            HandShape.fist,
            HandShape.flat,
            shoulder: 46,
            elbow: 176,
            invert: true,
          ),
          hold: 90,
        ),
      ],
      repeat: 2,
    ),

    // Fist circles over the heart: SORRY.
    'sorry': SignAnimation(
      id: 'sorry',
      gloss: 'SORRY',
      keys: [
        _k(
          _hand(HandShape.fist, shoulder: 24, elbow: 178, lower: 8),
          travel: 0,
          hold: 60,
        ),
        _k(
          _hand(
            HandShape.fist,
            shoulder: 18,
            elbow: 188,
            lower: -2,
            lift: 0.62,
          ),
          hold: 60,
        ),
        _k(_hand(HandShape.fist, shoulder: 24, elbow: 178, lower: 8), hold: 60),
      ],
      repeat: 2,
    ),

    // Upright hand rides up off the flat palm: HELP.
    'help': SignAnimation(
      id: 'help',
      gloss: 'HELP',
      keys: [
        _k(
          _two(
            HandShape.point,
            HandShape.flat,
            shoulder: 26,
            elbow: 178,
            lower: 10,
          ),
          travel: 0,
          hold: 80,
        ),
        _k(
          _two(
            HandShape.point,
            HandShape.flat,
            shoulder: 40,
            elbow: 162,
            lower: -14,
          ),
          hold: 150,
        ),
      ],
    ),

    // Open 5 thumb to the chin, then release: MOTHER.
    // A single hold read as the avatar freezing mid-sentence, so the contact
    // keeps most of the run and the hand leaves the chin at the end.
    'mother': SignAnimation(
      id: 'mother',
      gloss: 'MOTHER',
      keys: [
        // Inverted, so the back of the hand faces the viewer and the palm lies
        // against the chin. THANK-YOU touches the same spot and used to open in
        // exactly this silhouette; the palm is what tells a chin-held MOTHER
        // from a hand leaving the chin.
        _k(
          _atFace(HandShape.flat, _FaceSpot.chin, wrist: -10, invert: true),
          travel: 0,
          hold: 160,
        ),
        _k(
          _hand(
            HandShape.flat,
            shoulder: 146,
            elbow: 138,
            wrist: -8,
            lift: 0.92,
            invert: true,
          ),
          travel: 180,
          hold: 60,
        ),
      ],
    ),

    // Open 5 thumb to the forehead, then release: FATHER.
    'father': SignAnimation(
      id: 'father',
      gloss: 'FATHER',
      keys: [
        // Thumb to the brow. The old angles kept the hand beside the head, so
        // FATHER and MOTHER read as the same hold at different heights.
        _k(
          _atFace(HandShape.flat, _FaceSpot.forehead, wrist: -14),
          travel: 0,
          hold: 160,
        ),
        _k(
          _hand(
            HandShape.flat,
            shoulder: 132,
            elbow: 112,
            wrist: -10,
            lift: 0.93,
          ),
          travel: 180,
          hold: 60,
        ),
      ],
    ),

    // Flat-O taps the mouth twice: EAT.
    'eat': SignAnimation(
      id: 'eat',
      gloss: 'EAT',
      keys: [
        _k(
          _atFace(HandShape.flat, _FaceSpot.mouth, wrist: -22),
          travel: 0,
          hold: 60,
        ),
        _k(_atFace(HandShape.pinch, _FaceSpot.mouth, wrist: 12), hold: 70),
      ],
      repeat: 2,
    ),

    // Modified W at the mouth: WATER.
    'water': SignAnimation(
      id: 'water',
      gloss: 'WATER',
      keys: [
        _k(
          _atFace(FingerspellShapes.letters['w']!, _FaceSpot.mouth, wrist: -20),
          travel: 0,
          hold: 70,
        ),
        _k(
          _atFace(FingerspellShapes.letters['w']!, _FaceSpot.mouth, wrist: 20),
          hold: 80,
        ),
      ],
      repeat: 2,
    ),

    // Both 5-hands start at the cheeks then swing forward: HOME.
    'home': SignAnimation(
      id: 'home',
      gloss: 'HOME',
      keys: [
        _k(
          _both(HandShape.flat, shoulder: 134, elbow: 124, lift: 1.0),
          travel: 0,
          hold: 110,
        ),
        _k(
          _both(HandShape.flat, shoulder: 78, elbow: 96, lift: 0.1),
          hold: 160,
        ),
      ],
    ),

    // Two H-hands tap twice, then two L-hands: NAME.
    'name': SignAnimation(
      id: 'name',
      gloss: 'NAME',
      keys: [
        _k(
          _both(
            FingerspellShapes.letters['h']!,
            shoulder: 34,
            elbow: 182,
            lift: 0.5,
          ),
          travel: 0,
          hold: 60,
        ),
        _k(
          _both(
            FingerspellShapes.letters['h']!,
            shoulder: 30,
            elbow: 176,
            lift: 0.6,
          ),
          hold: 60,
        ),
        _k(
          _both(
            FingerspellShapes.letters['l']!,
            shoulder: 36,
            elbow: 180,
            lift: 0.5,
          ),
          hold: 60,
        ),
        _k(
          _both(
            FingerspellShapes.letters['l']!,
            shoulder: 31,
            elbow: 175,
            lift: 0.6,
          ),
          hold: 70,
        ),
      ],
    ),

    // Index points up and rocks forward: WHERE.
    'where': SignAnimation(
      id: 'where',
      gloss: 'WHERE',
      keys: [
        _k(
          _hand(
            HandShape.point,
            shoulder: 62,
            elbow: 152,
            wrist: -14,
            lift: 0.45,
            face: const FacePose(brow: 1, headTilt: -5),
          ),
          travel: 0,
          hold: 80,
        ),
        _k(
          _hand(
            HandShape.point,
            shoulder: 76,
            elbow: 140,
            wrist: 12,
            lift: 0.3,
          ),
          hold: 100,
        ),
      ],
      repeat: 2,
      pingpong: true,
    ),

    // H-hand moves forward twice: GO.
    'go': SignAnimation(
      id: 'go',
      gloss: 'GO',
      keys: [
        _k(
          _hand(
            FingerspellShapes.letters['h']!,
            shoulder: 66,
            elbow: 150,
            lift: 0.35,
          ),
          travel: 0,
          hold: 60,
        ),
        _k(
          _hand(
            FingerspellShapes.letters['h']!,
            shoulder: 88,
            elbow: 128,
            lift: 0.15,
          ),
          hold: 80,
        ),
      ],
      repeat: 2,
    ),

    // Index curls toward the body twice: COME.
    'come': SignAnimation(
      id: 'come',
      gloss: 'COME',
      keys: [
        _k(
          _hand(
            HandShape.point,
            shoulder: 84,
            elbow: 132,
            wrist: -6,
            lift: 0.25,
          ),
          travel: 0,
          hold: 60,
        ),
        _k(
          _hand(
            HandShape.bent,
            shoulder: 66,
            elbow: 156,
            wrist: -16,
            lift: 0.5,
          ),
          hold: 80,
        ),
      ],
      repeat: 2,
    ),

    // Index sweeps from the eye outward: SEE.
    'see': SignAnimation(
      id: 'see',
      gloss: 'SEE',
      keys: [
        _k(
          _atFace(HandShape.point, _FaceSpot.eye, wrist: -6),
          travel: 0,
          hold: 90,
        ),
        _k(
          _hand(HandShape.point, shoulder: 96, elbow: 128, lift: 0.3),
          hold: 130,
        ),
      ],
    ),

    // Index taps the forehead and pulls away: KNOW.
    'know': SignAnimation(
      id: 'know',
      gloss: 'KNOW',
      keys: [
        _k(
          _atFace(HandShape.point, _FaceSpot.forehead, wrist: -10),
          travel: 0,
          hold: 90,
        ),
        _k(
          _hand(
            HandShape.point,
            shoulder: 96,
            elbow: 150,
            lower: 16,
            lift: 0.5,
          ),
          hold: 110,
        ),
      ],
    ),

    // Both A-hands cross over the chest and press in: LOVE.
    'love': SignAnimation(
      id: 'love',
      gloss: 'LOVE',
      keys: [
        _k(
          _both(HandShape.fist, shoulder: 52, elbow: 150, lift: 0.45),
          travel: 0,
          hold: 160,
        ),
        _k(
          _both(HandShape.fist, shoulder: 60, elbow: 158, lift: 0.38),
          travel: 200,
          hold: 120,
        ),
      ],
    ),

    // S-fist taps the S-palm twice: WORK.
    'work': SignAnimation(
      id: 'work',
      gloss: 'WORK',
      keys: [
        _k(
          _two(
            FingerspellShapes.letters['s']!,
            FingerspellShapes.letters['s']!,
            shoulder: 26,
            elbow: 180,
            lower: -6,
          ),
          travel: 0,
          hold: 60,
        ),
        _k(
          _two(
            FingerspellShapes.letters['s']!,
            FingerspellShapes.letters['s']!,
            shoulder: 22,
            elbow: 172,
            lower: 8,
          ),
          hold: 80,
        ),
      ],
      repeat: 2,
    ),

    // Bent fingers drop from the face: SLEEP.
    'sleep': SignAnimation(
      id: 'sleep',
      gloss: 'SLEEP',
      keys: [
        _k(
          _atFace(
            HandShape.bent,
            _FaceSpot.forehead,
            wrist: -12,
            face: const FacePose(eyes: 0.8, mouth: 0.15),
          ),
          travel: 0,
          hold: 110,
        ),
        _k(
          _atFace(
            HandShape.bent,
            _FaceSpot.chin,
            wrist: -12,
            face: const FacePose(eyes: 0.9, mouth: 0.1),
          ),
          hold: 170,
        ),
      ],
    ),

    // Claw hands pull toward the body: WANT.
    'want': SignAnimation(
      id: 'want',
      gloss: 'WANT',
      keys: [
        _k(
          _both(HandShape.bent, shoulder: 74, elbow: 140, lift: 0.3),
          travel: 0,
          hold: 70,
        ),
        _k(
          _both(HandShape.claw, shoulder: 34, elbow: 176, lift: 0.55),
          hold: 100,
        ),
      ],
      repeat: 2,
    ),

    // N-hands drop twice: NEED.
    'need': SignAnimation(
      id: 'need',
      gloss: 'NEED',
      keys: [
        _k(
          _both(HandShape.fist, shoulder: 40, elbow: 170, lower: -8),
          travel: 0,
          hold: 60,
        ),
        _k(_both(HandShape.fist, shoulder: 34, elbow: 176, lower: 6), hold: 70),
      ],
      repeat: 2,
    ),

    // Flat hand sweeps into the other palm: BUY.
    'buy': SignAnimation(
      id: 'buy',
      gloss: 'BUY',
      keys: [
        _k(
          _two(
            HandShape.flat,
            HandShape.flat,
            shoulder: 44,
            elbow: 172,
            lower: -6,
          ),
          travel: 0,
          hold: 80,
        ),
        _k(
          _two(
            HandShape.pinch,
            HandShape.flat,
            shoulder: 28,
            elbow: 178,
            lower: 8,
          ),
          hold: 130,
        ),
      ],
    ),

    // Thumb slaps the palm twice: MONEY.
    'money': SignAnimation(
      id: 'money',
      gloss: 'MONEY',
      keys: [
        _k(
          _two(
            HandShape.flat,
            HandShape.flat,
            shoulder: 30,
            elbow: 178,
            lower: -4,
          ),
          travel: 0,
          hold: 50,
        ),
        _k(
          _two(
            HandShape.pinch,
            HandShape.flat,
            shoulder: 28,
            elbow: 176,
            lower: 4,
          ),
          hold: 70,
        ),
      ],
      repeat: 2,
    ),

    // D-hand taps the wrist twice: DOCTOR.
    'doctor': SignAnimation(
      id: 'doctor',
      gloss: 'DOCTOR',
      keys: [
        _k(
          _two(
            FingerspellShapes.letters['d']!,
            HandShape.flat,
            shoulder: 34,
            elbow: 182,
            lower: -4,
          ),
          travel: 0,
          hold: 60,
        ),
        _k(
          _two(
            FingerspellShapes.letters['d']!,
            HandShape.flat,
            shoulder: 28,
            elbow: 176,
            lower: 6,
          ),
          hold: 70,
        ),
      ],
      repeat: 2,
    ),

    // Two flat hands clap twice: SCHOOL.
    'school': SignAnimation(
      id: 'school',
      gloss: 'SCHOOL',
      keys: [
        _k(
          _both(HandShape.flat, shoulder: 56, elbow: 160, lift: 0.35),
          travel: 0,
          hold: 50,
        ),
        _k(
          _both(HandShape.flat, shoulder: 34, elbow: 178, lift: 0.55),
          hold: 70,
        ),
      ],
      repeat: 2,
    ),

    // Two index fingers hook together twice: FRIEND.
    'friend': SignAnimation(
      id: 'friend',
      gloss: 'FRIEND',
      keys: [
        _k(
          _both(HandShape.point, shoulder: 40, elbow: 176, lift: 0.5),
          travel: 0,
          hold: 60,
        ),
        _k(
          _both(HandShape.point, shoulder: 34, elbow: 182, lift: 0.55),
          hold: 70,
        ),
      ],
      repeat: 2,
      pingpong: true,
    ),

    // ---- everyday verbs --------------------------------------------------
    // Thirteen glosses the ASL-LEX tier rule left with no sign of their own.
    // Each is authored on its own motion rather than borrowed from a neighbour:
    // mapping HUG onto LOVE, or CONSUME onto EAT, claims the words are the same
    // sign, which is the claim the tier rule refused to make.
    //
    // Every zone below is a recipe already proven by an older sign — the mouth
    // is EAT's shoulder 54 / elbow 170, the chest is WORK's 26 / 180, an arm
    // laid across the body is 78 / 186 with the lift nearly gone. Inventing an
    // angle for a hand that has to *touch* something puts it beside the head
    // instead, which is how the first pass at this block read.

    // Two A-hands lift off the chest together: ASSIST.
    // HELP sends one hand up off the other's palm; this is the both-hands form,
    // so upright thumbs on two fists carry the difference.
    'assist': SignAnimation(
      id: 'assist',
      gloss: 'ASSIST',
      keys: [
        _k(
          _both(
            FingerspellShapes.letters['a']!,
            shoulder: 34,
            elbow: 158,
            lift: 0.52,
          ),
          travel: 0,
          hold: 60,
        ),
        _k(
          _both(
            FingerspellShapes.letters['a']!,
            shoulder: 52,
            elbow: 142,
            lift: 0.42,
          ),
          hold: 90,
        ),
      ],
      repeat: 2,
      pingpong: true,
    ),

    // The O-hand leaves the pursed mouth and comes back: BLOW.
    // Held at EAT's mouth height so the air, not the arm, is what moves; the
    // hand stays shut the whole way out, which is what separates it from the
    // opening tap of EAT.
    'blow': SignAnimation(
      id: 'blow',
      gloss: 'BLOW',
      keys: [
        _k(
          _atFace(
            HandShape.o,
            _FaceSpot.cheek,
            wrist: -10,
            face: const FacePose(mouth: 0.3),
          ),
          travel: 0,
          hold: 55,
        ),
        _k(
          _hand(
            _five,
            shoulder: 92,
            elbow: 138,
            lift: 0.42,
            face: const FacePose(mouth: 0.3, eyes: 0.45),
          ),
          hold: 85,
        ),
      ],
      repeat: 2,
      pingpong: true,
    ),

    // A closed hand rises from the chest to the mouth and opens: CONSUME.
    // EAT taps at the lips; this travels the food inward from below, so the
    // path is the contrast and the hand finishes where EAT starts.
    'consume': SignAnimation(
      id: 'consume',
      gloss: 'CONSUME',
      keys: [
        _k(
          _hand(HandShape.pinch, shoulder: 26, elbow: 180, lower: 4, lift: 0.5),
          travel: 0,
          hold: 55,
        ),
        _k(_atFace(HandShape.pinch, _FaceSpot.mouth, wrist: -12), hold: 60),
        _k(_atFace(HandShape.flat, _FaceSpot.mouth, wrist: -22), hold: 90),
      ],
      repeat: 2,
      pingpong: true,
    ),

    // Both 8-hands rub a circle on the chest: ENJOY.
    // One hand at chest height sits out to the side of the body rather than on
    // it, so the rub is authored mirrored — three offsets of shoulder and wrist
    // trace the arc, and a still circle reads as NEED.
    'enjoy': SignAnimation(
      id: 'enjoy',
      gloss: 'ENJOY',
      keys: [
        _k(
          _both(_eight, shoulder: 32, elbow: 174, wrist: -18, lift: 0.52),
          travel: 0,
          hold: 50,
        ),
        _k(
          _both(_eight, shoulder: 42, elbow: 166, wrist: 10, lift: 0.44),
          hold: 55,
        ),
        _k(
          _both(_eight, shoulder: 36, elbow: 178, wrist: -26, lift: 0.56),
          hold: 55,
        ),
      ],
      repeat: 2,
    ),

    // The F-hand strikes the flat palm twice: FINANCE.
    // MONEY slaps the same palm with the thumb; here the ring of index and
    // thumb comes down onto it, so the handshape is the whole contrast.
    'finance': SignAnimation(
      id: 'finance',
      gloss: 'FINANCE',
      keys: [
        _k(
          _two(
            FingerspellShapes.letters['f']!,
            HandShape.flat,
            shoulder: 32,
            elbow: 176,
            lower: -2,
            lift: 0.5,
          ),
          travel: 0,
          hold: 50,
        ),
        _k(
          _two(
            FingerspellShapes.letters['f']!,
            HandShape.flat,
            shoulder: 26,
            elbow: 182,
            lower: 6,
            lift: 0.54,
          ),
          hold: 70,
        ),
      ],
      repeat: 2,
    ),

    // Both arms open and then lay across the chest: HUG.
    // LOVE presses two fists together over the heart; HUG is the reach-in of
    // two open arms, so the elbows stay wide and the hands end up on the far
    // shoulder. Only a nearly straight elbow with the lift dropped carries a
    // hand past the middle of the body.
    'hug': SignAnimation(
      id: 'hug',
      gloss: 'HUG',
      keys: [
        _k(
          _both(HandShape.flat, shoulder: 56, elbow: 168, lift: 0.42),
          travel: 0,
          hold: 70,
        ),
        _k(
          _both(HandShape.relax, shoulder: 78, elbow: 186, lift: 0.12),
          hold: 170,
        ),
      ],
      repeat: 2,
      pingpong: true,
    ),

    // Two fingers strike the open palm twice: MENTION.
    // NAME presses two H-hands together at the chest; MENTION brings them down
    // onto the other palm, which is the difference at card size.
    'mention': SignAnimation(
      id: 'mention',
      gloss: 'MENTION',
      keys: [
        _k(
          _two(
            FingerspellShapes.letters['u']!,
            HandShape.flat,
            shoulder: 34,
            elbow: 172,
            lower: -4,
            lift: 0.5,
          ),
          travel: 0,
          hold: 50,
        ),
        _k(
          _two(
            FingerspellShapes.letters['u']!,
            HandShape.flat,
            shoulder: 26,
            elbow: 182,
            lower: 8,
            lift: 0.56,
          ),
          hold: 70,
        ),
      ],
      repeat: 2,
    ),

    // The three fingers close onto the thumb over the flat palm: NEGATIVE.
    // NO is that same closing at face height with nothing under it; the
    // supporting palm is what makes it the adverbial form.
    'negative': SignAnimation(
      id: 'negative',
      gloss: 'NEGATIVE',
      keys: [
        _k(
          _two(
            _mHand,
            HandShape.flat,
            shoulder: 32,
            elbow: 176,
            lower: -2,
            lift: 0.5,
          ),
          travel: 0,
          hold: 55,
        ),
        _k(
          _two(
            HandShape.point,
            HandShape.flat,
            shoulder: 26,
            elbow: 182,
            lower: 6,
            lift: 0.54,
          ),
          hold: 75,
        ),
      ],
      repeat: 2,
    ),

    // Two H-hands turn over into each other across the chest: RELATIONSHIP.
    // FRIEND hooks single index fingers at the side; this crosses two-finger
    // hands over the middle of the body, which is where the linking reads.
    'relationship': SignAnimation(
      id: 'relationship',
      gloss: 'RELATIONSHIP',
      keys: [
        _k(
          _both(
            FingerspellShapes.letters['h']!,
            shoulder: 62,
            elbow: 182,
            wrist: -16,
            lift: 0.22,
          ),
          travel: 0,
          hold: 60,
        ),
        _k(
          _both(
            FingerspellShapes.letters['h']!,
            shoulder: 76,
            elbow: 188,
            wrist: 16,
            lift: 0.12,
          ),
          hold: 95,
        ),
      ],
      repeat: 2,
      pingpong: true,
    ),

    // The hand falls down the body, fingers spreading and closing: SHOWER.
    // SLEEP's drop, but in four steps and with the fingers moving — a hand that
    // only travels down reads as SLEEP again, and the wiggle is the water.
    'shower': SignAnimation(
      id: 'shower',
      gloss: 'SHOWER',
      keys: [
        _k(_atFace(_five, _FaceSpot.temple, wrist: -12), travel: 0, hold: 45),
        _k(
          _hand(HandShape.flat, shoulder: 74, elbow: 160, lower: 8, lift: 0.45),
          hold: 45,
        ),
        _k(
          _hand(_five, shoulder: 54, elbow: 170, lower: 16, lift: 0.5),
          hold: 45,
        ),
        _k(
          _hand(
            HandShape.flat,
            shoulder: 38,
            elbow: 178,
            lower: 24,
            lift: 0.55,
          ),
          hold: 70,
        ),
      ],
    ),

    // The pinched hand shakes down the other arm: THERMOMETER.
    // DOCTOR taps the wrist once with a single finger; this grips with two and
    // shakes, and the shake is the only thing that says it, so the drop is
    // small and repeated rather than one long travel.
    'temperature': SignAnimation(
      id: 'temperature',
      gloss: 'THERMOMETER',
      keys: [
        _k(
          _two(
            HandShape.pinch,
            HandShape.flat,
            shoulder: 32,
            elbow: 176,
            lower: -4,
            lift: 0.5,
          ),
          travel: 0,
          hold: 45,
        ),
        _k(
          _two(
            HandShape.pinch,
            HandShape.flat,
            shoulder: 26,
            elbow: 182,
            lower: 8,
            lift: 0.55,
          ),
          hold: 40,
        ),
        _k(
          _two(
            HandShape.pinch,
            HandShape.flat,
            shoulder: 30,
            elbow: 178,
            lower: 0,
            lift: 0.52,
          ),
          hold: 40,
        ),
      ],
      repeat: 2,
    ),

    // The V-hand points out of the eye: VISION.
    // SEE sweeps one index finger from the eye; the noun keeps two fingers
    // apart and travels less, so the hand never leaves the face.
    'vision': SignAnimation(
      id: 'vision',
      gloss: 'VISION',
      keys: [
        _k(
          _atFace(
            _vee,
            _FaceSpot.eye,
            wrist: -6,
            face: const FacePose(eyes: 0.6),
          ),
          travel: 0,
          hold: 70,
        ),
        _k(
          _atFace(
            _vee,
            _FaceSpot.temple,
            wrist: -2,
            face: const FacePose(eyes: 0.6),
          ),
          hold: 110,
        ),
      ],
      repeat: 2,
      pingpong: true,
    ),

    // The O-hand taps the other wrist: WATCH.
    // The non-dominant arm hangs with the thumb out so the wrist it is tapped
    // on reads as the one wearing the watch, and the reaching hand has to cross
    // to it, which is the whole sign.
    'watch': SignAnimation(
      id: 'watch',
      gloss: 'WATCH',
      keys: [
        _k(
          _two(
            HandShape.o,
            FingerspellShapes.letters['a']!,
            shoulder: 26,
            elbow: 184,
            lower: 2,
            lift: 0.62,
          ),
          travel: 0,
          hold: 55,
        ),
        _k(
          _two(
            HandShape.o,
            FingerspellShapes.letters['a']!,
            shoulder: 22,
            elbow: 188,
            lower: 8,
            lift: 0.66,
          ),
          hold: 75,
        ),
      ],
      repeat: 2,
    ),
    // Both bent hands start knuckles-in and roll outward: HOW.
    // The roll is the sign. Held still at chest height the pair is a pose, which
    // is what the fingerspelled H-O-W used to read as.
    'how': SignAnimation(
      id: 'how',
      gloss: 'HOW',
      keys: [
        _k(
          _mirrored(
            HandShape.bent,
            shoulder: 30,
            elbow: 170,
            wrist: 16,
            lift: 0.58,
          ),
          travel: 0,
          hold: 60,
        ),
        _k(
          _mirrored(
            HandShape.bent,
            shoulder: 46,
            elbow: 160,
            wrist: -38,
            lift: 0.44,
          ),
          hold: 70,
        ),
      ],
      repeat: 2,
      pingpong: true,
    ),

    // Both flat palms lift in front of the chest and settle twice: TODAY.
    'today': SignAnimation(
      id: 'today',
      gloss: 'TODAY',
      keys: [
        _k(
          _mirrored(HandShape.flat, shoulder: 44, elbow: 154, lift: 0.62),
          travel: 0,
          hold: 60,
        ),
        _k(
          _mirrored(HandShape.flat, shoulder: 22, elbow: 178, lift: 0.46),
          hold: 60,
        ),
      ],
      repeat: 2,
      pingpong: true,
    ),

    // ---- weather ---------------------------------------------------------
    // Every sign below is handshape plus one direction, held for two passes.
    // A caption about the weather arrives as four or five of these in a row, so
    // the budget for each is the time it takes to read a hand at card size: a
    // longer path stops looking like a sign and starts looking like jitter.

    // Both 3-hands fall from above the head to the chest, fingers down: RAIN.
    // The hands have to start above the crown and finish in front of the shirt;
    // stopping at the temples reads as patting the hair, and one hand alone
    // reads as a wave beside the head.
    'rain': SignAnimation(
      id: 'rain',
      gloss: 'RAIN',
      keys: [
        _k(
          _mirrored(_three, shoulder: 138, elbow: 118, wrist: -20, lift: 1.0),
          travel: 0,
          hold: 55,
        ),
        _k(
          _mirrored(_three, shoulder: 44, elbow: -70, wrist: 26, lift: 0.5),
          travel: 320,
          hold: 75,
        ),
      ],
      repeat: 2,
      pingpong: true,
    ),

    // The same fall from both fanned-open hands: SNOW. The handshape, not the
    // path, is what separates it from RAIN — at card size a sideways drift reads
    // as the same dip, so two signs that differ only in direction look
    // duplicated.
    'snow': SignAnimation(
      id: 'snow',
      gloss: 'SNOW',
      keys: [
        _k(
          _mirrored(_five, shoulder: 136, elbow: 122, wrist: -18, lift: 1.0),
          travel: 0,
          hold: 55,
        ),
        _k(
          _mirrored(_five, shoulder: 40, elbow: -66, wrist: 26, lift: 0.48),
          travel: 320,
          hold: 70,
        ),
      ],
      repeat: 2,
      pingpong: true,
    ),

    // Open hand leaves the rounded mouth and travels out: WIND.
    'wind': SignAnimation(
      id: 'wind',
      gloss: 'WIND',
      keys: [
        _k(
          _atFace(
            HandShape.flat,
            _FaceSpot.cheek,
            wrist: -10,
            face: const FacePose(mouth: 0.45),
          ),
          travel: 0,
          hold: 50,
        ),
        _k(
          _hand(HandShape.flat, shoulder: 78, elbow: 148, lift: 0.14),
          hold: 80,
        ),
      ],
      repeat: 2,
      pingpong: true,
    ),

    // The idiom for a blustery day is WIND's handshape on both hands, wagging
    // at head height: WINDY. One hand would be the noun, and a fanned hand
    // keeps the pair apart from CLOUD's cups in the same zone.
    'windy': SignAnimation(
      id: 'windy',
      gloss: 'WINDY',
      keys: [
        _k(
          _both(
            _five,
            shoulder: 100,
            elbow: 112,
            lift: 0.24,
            face: const FacePose(mouth: 0.5, eyes: 0.4),
          ),
          travel: 0,
          hold: 45,
        ),
        _k(
          _both(
            _five,
            shoulder: 110,
            elbow: 100,
            lift: 0.44,
            face: const FacePose(mouth: 0.5, eyes: 0.4),
          ),
          hold: 55,
        ),
      ],
      repeat: 2,
      pingpong: true,
    ),

    // Two C-hands draw in from outside the head and sit on the temples: CLOUD.
    // STORM shakes in the same zone, so the cups and the slow press in are what
    // keep the two apart.
    'cloud': SignAnimation(
      id: 'cloud',
      gloss: 'CLOUD',
      keys: [
        _k(
          _both(_cHand, shoulder: 126, elbow: 124, lift: 1.0),
          travel: 0,
          hold: 50,
        ),
        _k(_both(_cHand, shoulder: 140, elbow: 118, lift: 1.0), hold: 60),
      ],
      repeat: 2,
      pingpong: true,
    ),

    // Claw hands held high and wide, flapping at the wrists: STORM.
    'storm': SignAnimation(
      id: 'storm',
      gloss: 'STORM',
      keys: [
        _k(
          _both(
            HandShape.claw,
            shoulder: 114,
            elbow: 98,
            wrist: -38,
            lift: 0.5,
            face: const FacePose(brow: 0.7, eyes: 0.55),
          ),
          travel: 0,
          hold: 40,
        ),
        _k(
          _both(
            HandShape.claw,
            shoulder: 108,
            elbow: 106,
            wrist: 26,
            lift: 0.34,
            face: const FacePose(brow: 0.7, eyes: 0.55),
          ),
          hold: 45,
        ),
      ],
      repeat: 2,
      pingpong: true,
    ),

    // Two fists rattle downward: THUNDER.
    'thunder': SignAnimation(
      id: 'thunder',
      gloss: 'THUNDER',
      keys: [
        _k(
          _both(
            HandShape.fist,
            shoulder: 96,
            elbow: 116,
            lift: 0.36,
            face: const FacePose(brow: 0.8, eyes: 0.6),
          ),
          travel: 0,
          hold: 40,
        ),
        _k(
          _both(HandShape.fist, shoulder: 72, elbow: 148, lift: 0.28),
          hold: 60,
        ),
      ],
      repeat: 2,
      pingpong: true,
    ),

    // The index jogs from above the head down to the chest twice: LIGHTNING.
    // WEATHER is the same finger circling at the forehead, so the drop to the
    // chest is what separates them.
    'lightning': SignAnimation(
      id: 'lightning',
      gloss: 'LIGHTNING',
      keys: [
        _k(
          _hand(
            HandShape.point,
            shoulder: 118,
            elbow: 92,
            lift: 0.16,
            face: const FacePose(eyes: 0.7, brow: 0.6),
          ),
          travel: 0,
          hold: 45,
        ),
        _k(
          _hand(HandShape.point, shoulder: 74, elbow: 132, lift: 0.56),
          travel: 110,
          hold: 30,
        ),
        _k(
          _hand(HandShape.point, shoulder: 26, elbow: 178, lift: 0.18),
          travel: 110,
          hold: 55,
        ),
      ],
      repeat: 2,
    ),

    // Flat hands roll outward through the space in front of the chest: FOG.
    // Kept below the chin — at cheek height this is WINDY's silhouette.
    'fog': SignAnimation(
      id: 'fog',
      gloss: 'FOG',
      keys: [
        _k(
          _both(
            HandShape.flat,
            shoulder: 26,
            elbow: 178,
            wrist: -18,
            lift: 0.44,
          ),
          travel: 0,
          hold: 60,
        ),
        _k(
          _both(
            HandShape.flat,
            shoulder: 34,
            elbow: 170,
            wrist: 14,
            lift: 0.26,
          ),
          hold: 90,
        ),
      ],
      repeat: 2,
      pingpong: true,
    ),

    // The index points up and circles once at the forehead: WEATHER. A flat
    // hand here would be WIND, so the pointer is the whole difference.
    'weather': SignAnimation(
      id: 'weather',
      gloss: 'WEATHER',
      keys: [
        _k(_atFace(HandShape.point, _FaceSpot.forehead), travel: 0, hold: 50),
        _k(_atFace(HandShape.point, _FaceSpot.temple), hold: 55),
        _k(_atFace(HandShape.point, _FaceSpot.forehead, wrist: -20), hold: 50),
      ],
      repeat: 2,
    ),

    // Fists hugged in against the sternum, elbows tucked, shivering: COLD.
    // THUNDER shakes fists at head height, so the hug and the low lift are what
    // keep the two shivering signs apart.
    'cold': SignAnimation(
      id: 'cold',
      gloss: 'COLD',
      keys: [
        _k(
          _both(
            HandShape.fist,
            shoulder: 34,
            elbow: 150,
            lift: 0.1,
            face: const FacePose(brow: 0.4, eyes: 0.5, mouth: 0.25),
          ),
          travel: 0,
          hold: 35,
        ),
        _k(
          _both(
            HandShape.fist,
            shoulder: 42,
            elbow: 142,
            lift: 0.22,
            face: const FacePose(brow: 0.55, eyes: 0.6, mouth: 0.4),
          ),
          hold: 35,
        ),
      ],
      repeat: 3,
      pingpong: true,
    ),

    // The hooked index leaves the mouth and flicks outward, palm away: HOT.
    'hot': SignAnimation(
      id: 'hot',
      gloss: 'HOT',
      keys: [
        _k(
          _atFace(
            _xHand,
            _FaceSpot.mouth,
            wrist: -18,
            face: const FacePose(mouth: 0.45, eyes: 0.55),
          ),
          travel: 0,
          hold: 55,
        ),
        _k(
          _hand(
            _xHand,
            shoulder: 38,
            elbow: 184,
            wrist: 16,
            lift: 0.06,
            invert: true,
            face: const FacePose(mouth: 0.55, eyes: 0.3),
          ),
          hold: 75,
        ),
      ],
      repeat: 2,
      pingpong: true,
    ),

    // The O-hand opens and sweeps a wide circle above the crown, then closes:
    // SUN. WEATHER keeps a steady pointer at the forehead and LIGHTNING drops
    // to the chest, so the raised arc plus the shape change is what reads here.
    'sun': SignAnimation(
      id: 'sun',
      gloss: 'SUN',
      keys: [
        _k(
          _hand(HandShape.o, shoulder: 124, elbow: 88, lift: 0.14),
          travel: 0,
          hold: 50,
        ),
        _k(
          _hand(HandShape.point, shoulder: 122, elbow: 90, lift: 0.56),
          hold: 55,
        ),
        _k(_hand(HandShape.o, shoulder: 118, elbow: 96, lift: 0.3), hold: 50),
      ],
      repeat: 2,
    ),
  };

  /// Thumb, index and middle out, ring and pinky into the palm: the 8 hand that
  /// ENJOY rubs in a circle on the chest with.
  static const _eight = HandShape(
    index: 0,
    middle: 0,
    ring: 1,
    pinky: 1,
    thumb: 1,
    thumbSpread: 0.9,
  );

  /// Three fingers extended and held apart with the thumb: the V that VISION
  /// points at the eye with. U is the same two fingers kept together.
  static const _vee = HandShape(
    index: 0,
    middle: 0,
    ring: 1,
    pinky: 1,
    thumb: 0.5,
    spread: 0.85,
  );

  /// Index, middle and ring bent onto the thumb with the pinky folded: the M
  /// that NEGATIVE closes and reopens.
  static const _mHand = HandShape(
    index: 0.85,
    middle: 0.85,
    ring: 0.85,
    pinky: 1,
    thumb: 0.3,
  );

  /// Index, middle and ring extended with the pinky and thumb pulled in: the 3
  /// hand that rain and snow fall out of.
  static const _three = HandShape(
    index: 0,
    middle: 0,
    ring: 0,
    pinky: 1,
    thumb: 0.06,
  );

  /// All five fingers out and fanned: the hand snow flutters down from. WIND
  /// keeps its fingers together so the two open hands read differently.
  static const _five = HandShape(
    index: 0,
    middle: 0,
    ring: 0,
    pinky: 0,
    thumb: 0.35,
    thumbSpread: 0.35,
    spread: 0.8,
  );

  /// Every finger bent past half with the thumb curved to meet it: the hollow C
  /// hand. Bent to half it still reads as an open hand at card size, which is
  /// how CLOUD got confused with WINDY.
  static const _cHand = HandShape(
    index: 0.62,
    middle: 0.62,
    ring: 0.62,
    pinky: 0.62,
    thumb: 0.6,
    thumbSpread: 0.3,
  );

  /// The index hooked over its own knuckle, the rest folded: the X hand.
  static const _xHand = HandShape(
    index: 0.7,
    middle: 1,
    ring: 1,
    pinky: 1,
    thumb: 0.12,
  );

  /// Right-hand sign in signing space. `lower` drops the whole arm, `invert`
  /// flips the palm so the same shape reads as its opposite (GOOD vs BAD).
  static PoseKey _k(SignPose pose, {int travel = 200, int hold = 0}) =>
      PoseKey(pose: pose, travelMs: travel, holdMs: hold);

  static SignPose _hand(
    HandShape hand, {
    double shoulder = 12,
    double elbow = 198,
    double wrist = -10,
    double lift = 0.55,
    double lower = 0,
    bool invert = false,
    FacePose face = FacePose.neutral,
  }) => SignPose(
    name: 'sign',
    left: ArmPose.resting,
    right: ArmPose(
      shoulder: shoulder - lower,
      elbow: elbow,
      wrist: wrist,
      palm: invert ? 150 : 0,
      lift: lift,
      hand: hand,
    ),
    face: face,
  );

  /// The same hand placed on a feature of the face.
  ///
  /// Only for a sign whose hand has to *touch* the head. For anything that
  /// moves through the space in front of it, use [_hand].
  static SignPose _atFace(
    HandShape hand,
    _FaceSpot spot, {
    double wrist = -14,
    bool invert = false,
    FacePose face = FacePose.neutral,
  }) => _hand(
    hand,
    shoulder: spot.shoulder,
    elbow: spot.elbow,
    wrist: wrist,
    lift: spot.lift,
    invert: invert,
    face: face,
  );

  /// Both hands mirrored at the same joint angles, for two-handed signs.
  ///
  /// A mirrored pair reaches the face at shoulder 134, elbow ~122, lift 1.0:
  /// measured across the range, the two sets of fingertips are still 0.14 of the
  /// card apart there, so they sit on the temples without meeting, and past 142
  /// they overlap and cross the eyes. Below ~126 they are outside the head.
  static SignPose _both(
    HandShape hand, {
    required double shoulder,
    required double elbow,
    double wrist = -8,
    double lift = 0.5,
    double lower = 0,
    FacePose face = FacePose.neutral,
  }) => SignPose(
    name: 'sign',
    left: ArmPose(
      shoulder: shoulder - lower,
      elbow: elbow,
      wrist: -wrist,
      lift: lift,
      hand: hand,
    ),
    right: ArmPose(
      shoulder: shoulder - lower,
      elbow: elbow,
      wrist: wrist,
      lift: lift,
      hand: hand,
    ),
    face: face,
  );

  /// The same hand mirrored onto both sides of the body.
  ///
  /// [_both] negates the wrist, which turns the far hand the same way as the
  /// near one — the shape STORM, FOG and ENJOY were authored against, where
  /// both hands flap in one direction. A sign whose hands are one movement seen
  /// in a mirror — RAIN's pair falling, HOW's pair rolling outward — needs the
  /// wrist to carry the same sign on both sides instead.
  static SignPose _mirrored(
    HandShape hand, {
    required double shoulder,
    required double elbow,
    double wrist = 0,
    double lift = 0.5,
    double lower = 0,
    double palm = 0,
    FacePose face = FacePose.neutral,
  }) => SignPose(
    name: 'sign',
    left: ArmPose(
      shoulder: shoulder - lower,
      elbow: elbow,
      wrist: wrist,
      palm: palm,
      lift: lift,
      hand: hand,
    ),
    right: ArmPose(
      shoulder: shoulder - lower,
      elbow: elbow,
      wrist: wrist,
      palm: palm,
      lift: lift,
      hand: hand,
    ),
    face: face,
  );

  /// Dominant hand over a supporting non-dominant palm.
  ///
  /// The support arm is folded hard and lifted, which is the only shape the
  /// joint model has that brings a hand toward the middle of the chest: measured
  /// across every shoulder and elbow the rig reaches, the two wrists get no
  /// closer than 0.21 of the card (a palm is 0.078), and the hanging support arm
  /// the signs used to be authored over left them 0.36 apart. So the base is
  /// close, and the dominant hand finishes the gesture rather than meeting the
  /// other palm exactly.
  static SignPose _two(
    HandShape dominant,
    HandShape support, {
    required double shoulder,
    required double elbow,
    double lift = 0.5,
    double lower = 0,
    bool invert = false,
    FacePose face = FacePose.neutral,
  }) => SignPose(
    name: 'sign',
    left: ArmPose(
      shoulder: 24,
      elbow: 192,
      wrist: -62,
      lift: 0.68,
      hand: support,
    ),
    right: ArmPose(
      shoulder: shoulder - lower,
      elbow: elbow,
      wrist: -8,
      palm: invert ? 170 : 0,
      lift: lift,
      hand: dominant,
    ),
    face: face,
  );
}

/// A feature of the face, at the arm angles that put a hand on it.
///
/// Measured, not chosen. The shoulder joint sits at x 0.68 of the card and the
/// head spans 0.40–0.60, so the arm reaches a landmark only by pointing the
/// upper arm almost straight up and folding the forearm back across the face.
/// Sweeping every shoulder, elbow and lift the rig accepts, the wrist gets no
/// closer than x 0.60 unless the shoulder is past 140; below that the hand sits
/// beside the head, which is where most of the authored face signs started.
///
/// The upper-face entries are deliberately the *shallowest* reach that still
/// touches, because the same sweep showed an open hand driven any deeper lays
/// across the eyes and erases the facial grammar the signs depend on. A sign
/// whose handshape is narrow — one or two fingers — can use [_FaceSpot.eye]
/// without hiding anything, which is why that one sits deeper.
enum _FaceSpot {
  /// The brow, fingers up: FATHER, KNOW, RAIN, SNOW, WEATHER, SHOWER.
  forehead(138, 118, 1.0),

  /// The hairline at the side of the brow: the HELLO salute.
  temple(130, 118, 1.0),

  /// The eye, for a narrow handshape only: SEE, VISION.
  eye(146, 120, 1.0),

  /// The corner of the mouth, where air leaves: WIND, BLOW.
  cheek(150, 132, 1.0),

  /// The lips: EAT, WATER, CONSUME, HOT.
  mouth(150, 138, 1.0),

  /// Point of the chin: MOTHER, THANK-YOU.
  chin(152, 146, 1.0);

  const _FaceSpot(this.shoulder, this.elbow, this.lift);

  final double shoulder;
  final double elbow;
  final double lift;
}
