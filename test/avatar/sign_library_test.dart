import 'package:flutter_test/flutter_test.dart';

import 'package:sign_bridge/services/avatar/rig/avatar_painter.dart';
import 'package:sign_bridge/services/avatar/rig/sign_animation.dart';
import 'package:sign_bridge/services/avatar/rig/sign_library.dart';
import 'package:sign_bridge/services/avatar/rig/sign_pose.dart';
import 'package:sign_bridge/services/translate/asl_nmm_markers.dart';
import 'package:sign_bridge/services/translate/isl_nmm_markers.dart';
import 'package:sign_bridge/services/translate/sign_language_system.dart';
import 'package:sign_bridge/services/translate/sign_token.dart';

void main() {
  SignToken token(String id, {String? gloss}) => SignToken(
    id: id,
    gloss: gloss ?? id.toUpperCase(),
    system: SignLanguageSystem.asl,
  );

  // The everyday verbs the ASL-LEX tier rule left without a sign: each word now
  // answers with the sign named after it, so all thirteen had to be authored
  // rather than pointed at a neighbour's animation.
  const everyday = [
    'assist',
    'blow',
    'consume',
    'enjoy',
    'finance',
    'hug',
    'mention',
    'negative',
    'relationship',
    'shower',
    'temperature',
    'vision',
    'watch',
  ];

  const authored = [
      'hello',
      'me',
      'you',
      'thank_you',
      'please',
      'yes',
      'no',
      'good',
      'bad',
      'sorry',
      'help',
      'mother',
      'father',
      'eat',
      'water',
      'home',
      'name',
      'where',
      'how',
      'today',
      'go',
      'come',
      'see',
      'know',
      'love',
      'work',
      'sleep',
      'want',
      'need',
      'buy',
      'money',
      'doctor',
      'school',
      'friend',
      'rain',
      'snow',
      'wind',
      'windy',
      'cloud',
      'storm',
      'thunder',
      'lightning',
      'fog',
      'weather',
      'cold',
      'hot',
      'sun',
    ];

  group('authored core', () {
    for (final id in [...authored, ...everyday]) {
      test('$id resolves to its authored animation', () {
        final animation = SignLibrary.forToken(token(id));
        expect(animation, isNotNull);
        expect(animation!.id, id, reason: '$id fell through to fingerspell');
        expect(animation.totalMs, greaterThan(0));
      });
    }

    test('every authored animation produces a pose across its timeline', () {
      for (final id in [...authored, ...everyday]) {
        final animation = SignLibrary.forToken(token(id))!;
        for (final fraction in [0.0, 0.25, 0.5, 0.75, 1.0]) {
          final pose = animation.poseAt(
            Duration(milliseconds: (animation.totalMs * fraction).round()),
          );
          expect(pose, isA<SignPose>(), reason: '$id at $fraction');
        }
      }
    });

    test('every authored sign fits the signing tempo budget', () {
      // The whole lexicon lives between the one-tap signs (200ms) and the
      // slowest two-handed sign (just under 2s). A new sign outside this band
      // is either a snap or a drag — both read as wrong next to neighbours
      // that obey it, so the band is pinned across the whole library.
      for (final entry in SignLibrary.debugCore.entries) {
        expect(
          entry.value.totalMs,
          inInclusiveRange(200, 2000),
          reason: '${entry.key} runs ${entry.value.totalMs}ms',
        );
      }
    });
  });

  group('two-handed authoring', () {
    // The report that started this: a live caption played with one hand doing
    // everything. Some signs are one-handed by nature; these four are not.
    test('the two-handed vocabulary moves both arms', () {
      for (final id in ['rain', 'snow', 'how', 'today']) {
        final animation = SignLibrary.forToken(token(id))!;
        double span(ArmPose Function(PoseKey) armOf) {
          final first = armOf(animation.frames.first);
          var peak = 0.0;
          for (final frame in animation.frames.skip(1)) {
            final pose = armOf(frame);
            final travel = (pose.shoulder - first.shoulder).abs() +
                (pose.elbow - first.elbow).abs() +
                (pose.wrist - first.wrist).abs();
            if (travel > peak) peak = travel;
          }
          return peak;
        }

        expect(
          span((key) => key.pose.left),
          greaterThan(8),
          reason: '$id leaves the far arm hanging',
        );
        expect(
          span((key) => key.pose.right),
          greaterThan(8),
          reason: '$id leaves the near arm still',
        );
      }
    });

    test('ME lands its fingertip on the sternum', () {
      // Copied from AvatarPainter: palm plus the two finger segments. If the
      // rig is resized these fail, which is the point — the angles in ME were
      // measured against this body.
      const palm = 0.078;
      const finger = 0.044 + 0.031;
      const sternum = Offset(0.51, 0.50);
      final pose = SignLibrary.forToken(token('me'))!.frames.first.pose;
      final arm = AvatarPainter.armOf(pose, 1);
      final direction = arm.palmTop - arm.wrist;
      final tip = arm.wrist + direction / direction.distance * (palm + finger);
      expect(
        (tip - sternum).distance,
        lessThan(0.03),
        reason: 'ME points at $tip instead of the chest',
      );
    });
  });

  String shapeOf(SignPose pose) {
    String arm(ArmPose a) => [
      a.shoulder,
      a.elbow,
      a.wrist,
      a.palm,
      a.lift,
      a.hand.index,
      a.hand.middle,
      a.hand.ring,
      a.hand.pinky,
      a.hand.thumb,
      a.hand.thumbSpread,
      a.hand.thumbUp,
      a.hand.spread,
    ].map((v) => v.toStringAsFixed(2)).join(',');
    return '${arm(pose.right)};${arm(pose.left)}';
  }

  group('weather', () {
    const weather = [
      'rain',
      'snow',
      'wind',
      'windy',
      'cloud',
      'storm',
      'thunder',
      'lightning',
      'fog',
      'weather',
      'cold',
      'hot',
      'sun',
    ];

    // A weather caption strings four or five of these together, so two signs
    // that start in the same shape read as one sign held twice. Every collision
    // found at card size — RAIN/SNOW, CLOUD/STORM/WINDY, SUN/WEATHER/LIGHTNING —
    // was a shared first frame.
    test('no two signs start in the same pose', () {
      final firstOwner = <String, String>{};
      for (final id in weather) {
        final pose = SignLibrary.forToken(token(id))!.frames.first.pose;
        final owner = firstOwner.putIfAbsent(shapeOf(pose), () => id);
        expect(owner, id, reason: '$id opens in the same shape as $owner');
      }
    });

    test('the -y forms sign the weather word, not a spelled suffix', () {
      const alias = {
        'cloudy': 'cloud',
        'snowy': 'snow',
        'rainy': 'rain',
        'sunny': 'sun',
        'foggy': 'fog',
        'stormy': 'storm',
        'freezing': 'cold',
        'chilly': 'cold',
      };
      for (final entry in alias.entries) {
        final animation = SignLibrary.forToken(token(entry.key));
        expect(animation, isNotNull, reason: entry.key);
        expect(
          animation!.id,
          entry.value,
          reason: '${entry.key} fell through to fingerspell',
        );
      }
    });

    test('a numbered ASL-LEX variant answers with the base sign', () {
      for (final id in ['snow_2', 'cloud_4', 'rain_3', 'cold_9']) {
        final animation = SignLibrary.forToken(token(id));
        expect(animation, isNotNull, reason: id);
        expect(
          animation!.id,
          id.split('_').first,
          reason: '$id spelled its own digits',
        );
      }
    });
  });

  group('everyday verbs', () {
    // The same check that found four collisions in weather, run over the whole
    // authored vocabulary: a caption that uses HELP and ASSIST in one sentence
    // shows two signs, not one sign twice.
    test('no two authored signs open in the same pose', () {
      final firstOwner = <String, String>{};
      for (final id in [...authored, ...everyday]) {
        final pose = SignLibrary.forToken(token(id))!.frames.first.pose;
        final owner = firstOwner.putIfAbsent(shapeOf(pose), () => id);
        expect(owner, id, reason: '$id opens in the same shape as $owner');
      }
    });

    test('the word that lost its sign keeps its own, not a neighbour', () {
      // Aliasing was the tempting fix and the wrong one: HUG signed as LOVE is a
      // claim about the words that the lexicon tier rule refuses to make.
      for (final id in everyday) {
        expect(
          SignLibrary.forToken(token(id))!.id,
          id,
          reason: '$id borrowed another sign',
        );
      }
    });

    test('THERMOMETER is the sign the temperature gloss names', () {
      final animation = SignLibrary.forToken(token('thermometer'));
      expect(animation, isNotNull);
      expect(animation!.id, 'temperature');
    });
  });

  group('non-manual markers', () {
    for (final id in [
      'nmm_whQ',
      'nmm_ynQ',
      'nmm_rhQ',
      'nmm_headshake',
      'nmm_mm',
      'nmm_cha',
      'nmm_th',
      'nmm_cs',
      'nmm_roleShift',
    ]) {
      test('$id animates the face, not the hands', () {
        final animation = SignLibrary.forToken(token(id));
        expect(animation, isNotNull);
        final end = animation!.poseAt(Duration(milliseconds: animation.totalMs));
        expect(
          end.left.shoulder,
          ArmPose.resting.shoulder,
          reason: '$id should leave the hands at rest',
        );
        expect(
          end.right.shoulder,
          ArmPose.resting.shoulder,
        );
      });
    }

    test('wh-question furrows the brow', () {
      final animation = SignLibrary.forToken(token('nmm_whQ'))!;
      final pose = animation.poseAt(animation.duration);
      expect(pose.face.brow, lessThan(-0.5));
    });

    test('every production marker token resolves to a face animation', () {
      // The ids the grammar engine actually emits — not the camelCase ids
      // hand-built above. A spelling drift here once shipped questions as
      // fingerspelled "[WH-Q]" instead of a face cue.
      for (final markerId in AslNmmMarkers.allMarkers) {
        final production = AslNmmMarkers.token(markerId, SignLanguageSystem.asl);
        expect(
          SignLibrary.forToken(production),
          isNotNull,
          reason: '${production.id} ($markerId) found no animation',
        );
      }
      for (final markerId in [
        IslNmmMarkers.whQ,
        IslNmmMarkers.ynQ,
        IslNmmMarkers.headshake,
        IslNmmMarkers.mm,
        IslNmmMarkers.cha,
        IslNmmMarkers.th,
        IslNmmMarkers.cs,
      ]) {
        final production = IslNmmMarkers.token(markerId, SignLanguageSystem.isl);
        expect(
          SignLibrary.forToken(production),
          isNotNull,
          reason: '${production.id} ($markerId) found no animation',
        );
      }
    });

    test('headshake sways the head both ways', () {
      final animation = SignLibrary.forToken(token('nmm_headshake'))!;
      final turns = [0.1, 0.3, 0.5, 0.7, 0.9]
          .map(
            (f) =>
                animation
                    .poseAt(
                      Duration(milliseconds: (animation.totalMs * f).round()),
                    )
                    .face
                    .headTurn,
          )
          .toList();
      expect(turns.any((t) => t < 0), isTrue, reason: '$turns');
      expect(turns.any((t) => t > 0), isTrue, reason: '$turns');
    });
  });

  group('fingerspell fallback', () {
    test('unknown gloss is spelled, never invented', () {
      final animation = SignLibrary.forToken(token('zqx'));
      expect(animation, isNotNull);
      expect(animation!.id, 'spell_zqx');
      expect(animation.gloss, 'ZQX');
      expect(animation.totalMs, greaterThan(300));
    });

    test('longer words take longer', () {
      final short = SignLibrary.forToken(token('cat'))!;
      final long = SignLibrary.forToken(token('telephone'))!;
      expect(long.totalMs, greaterThan(short.totalMs));
    });

    test('letters outside the alphabet are skipped, not fatal', () {
      final animation = SignLibrary.forToken(token('num_5'))!;
      expect(animation.id, startsWith('spell_'));
      expect(animation.totalMs, greaterThan(0));
    });

    test('compound ids are spelled without the underscore', () {
      final animation = SignLibrary.forToken(token('hot_dog'))!;
      expect(animation.id, 'spell_hotdog');
    });

    test('an indic id is spelled as it sounds', () {
      // The lexicon only knows english glosses, so a Hindi, Tamil or Malayalam
      // word the grammar could not resolve reaches here still in its caption
      // script. It used to render as a hand that does not move.
      for (final pair in [
        ('गर्म', 'spell_garma'),
        ('பெய்கிறது', 'spell_peykirathu'),
        ('പെയ്യുന്നു', 'spell_peyyunnu'),
      ]) {
        final animation = SignLibrary.forToken(token(pair.$1));
        expect(animation, isNotNull, reason: pair.$1);
        expect(animation!.id, pair.$2);
        expect(animation.totalMs, greaterThan(500), reason: pair.$1);
      }
    });

    test('an id with nothing to spell contributes no animation', () {
      // Skipping the token is honest; a still hand reads as the app stopping.
      expect(SignLibrary.forToken(token('5')), isNull);
      expect(SignLibrary.forToken(token('水')), isNull);
    });
  });

  group('sequence resolution', () {
    test('empty sequence yields no cues', () {
      expect(SignLibrary.forSequence(const []), isEmpty);
    });

    test('every token in a mixed sequence yields an animation', () {
      final sequence = [
        token('hello'),
        token('nmm_ynQ'),
        token('florbnitz'),
        token('thank_you'),
      ];
      final animations = SignLibrary.forSequence(sequence);
      expect(animations.length, sequence.length);
      expect(animations.map((a) => a.id), [
        'hello',
        'nmm_ynQ',
        'spell_florbnitz',
        'thank_you',
      ]);
    });

    test('thinking token contributes nothing', () {
      expect(SignLibrary.forSequence(const [SignToken.thinking]), isEmpty);
    });
  });

  // A sign that names a feature of the face has to put a hand on it. Every one
  // of these used to float beside the head instead, because the angles were
  // picked by eye; see the `_FaceSpot` table for the sweep that found them.
  group('face reach', () {
    // Head circle and palm width, copied from AvatarPainter's unit constants.
    // If the head is resized these fail, which is the point: the face signs
    // were authored against this circle.
    const head = Offset(0.5, 0.245);
    const headRadius = 0.099;
    const palm = 0.078;

    /// Where the body of the hand sits, between the wrist and the fingertips.
    Offset touchPoint(String id, {int key = 0}) {
      final pose = SignLibrary.forToken(token(id))!.frames[key].pose;
      final arm = AvatarPainter.armOf(pose, 1);
      return (arm.wrist + arm.palmTop) / 2;
    }

    // id → which keyframe of it is the one on the face.
    const onFace = {
      'hello': 0,
      'father': 0,
      'mother': 0,
      'thank_you': 0,
      'eat': 0,
      'water': 0,
      'see': 0,
      'know': 0,
      'sleep': 0,
      'vision': 0,
      'blow': 0,
      'wind': 0,
      'rain': 0,
      'snow': 0,
      'weather': 0,
      'hot': 0,
      'shower': 0,
      'consume': 1,
    };

    test('every face sign lands a hand on the head', () {
      onFace.forEach((id, key) {
        final distance = (touchPoint(id, key: key) - head).distance;
        expect(
          distance,
          lessThan(headRadius + palm / 2),
          reason:
              '$id key $key puts its hand $distance from the head centre, '
              'outside the head plus half a palm',
        );
      });
    });

    test('the sweep that found these angles is not reversible', () {
      // The angles these signs replaced. Pinning the failure keeps a future
      // edit from sliding back to them and passing the check above by accident.
      final floated = SignPose(
        name: 'p',
        left: ArmPose.resting,
        right: ArmPose(shoulder: 102, elbow: 106, wrist: -6, lift: 0.36),
        face: FacePose.neutral,
      );
      final arm = AvatarPainter.armOf(floated, 1);
      final centre = (arm.wrist + arm.palmTop) / 2;
      expect(
        (centre - head).distance,
        greaterThan(headRadius + palm / 2),
        reason: 'the old beside-the-head angle should read as off the face',
      );
    });

    test('a mirrored pair reaches the temples without crossing over', () {
      for (final id in ['home', 'cloud']) {
        final pose = SignLibrary.forToken(token(id))!.frames.first.pose;
        final near = AvatarPainter.armOf(pose, 1);
        final far = AvatarPainter.armOf(pose, -1);
        for (final arm in [near, far]) {
          final centre = (arm.wrist + arm.palmTop) / 2;
          expect(
            (centre - head).distance,
            lessThan(headRadius + palm),
            reason: '$id does not bring both hands to the head',
          );
        }
        expect(
          (near.palmTop - far.palmTop).distance,
          greaterThan(palm),
          reason: '$id overlaps its own two hands across the face',
        );
      }
    });
  });
}
