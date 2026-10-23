import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sign_bridge/services/translate/asl_sign_lexicon.dart';
import 'package:sign_bridge/services/translate/english_lexicon.dart';
import 'package:sign_bridge/services/translate/sign_gloss_mapper.dart';

/// Regression probes for novel caption input (never-empty pipeline).
///
/// Each case reproduces a bug found by the rule-engine audit: clauses the
/// corpus never covered must still produce usable glosses instead of
/// collapsing, dropping content, or mis-resolving words.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await EnglishLexicon.load();
    await AslSignLexicon.load();
  });

  List<String> glosses(String transcript, String languageCode) {
    return SignGlossMapper.signSequence(
      transcript,
      languageCode,
    ).map((t) => t.gloss).toList();
  }

  group('never-empty guarantee', () {
    test('unknown content word still yields glosses', () {
      final out = glosses('The florbnitz is broken', 'ENG');
      expect(out, isNotEmpty);
    });

    test(
      'unresolvable words are fingerspelled or uppercased, never dropped',
      () {
        final out = glosses('The zqx jinxed the vorpal snarfblat', 'ENG');
        expect(out, isNotEmpty);
      },
    );

    test('auxiliary-only caption still yields a gloss', () {
      for (final caption in ['है', 'ने', 'रहा', 'ஆகும்', 'ആണ്', 'ആകുന്നു']) {
        final languageCode = switch (caption) {
          'ஆகும்' => 'TA',
          'ആണ്' || 'ആകുന്നു' => 'ML',
          _ => 'HI',
        };
        expect(glosses(caption, languageCode), isNotEmpty, reason: caption);
      }
    });
  });

  group('clause content preservation', () {
    test('verb object survives possessive topic reordering', () {
      final out = glosses('I need to buy medicine for my mother', 'ENG');
      expect(out, contains('BUY'));
      expect(out, contains('MEDICINE'));
    });

    test('rest resolves to REST not WAIT', () {
      final out = glosses('I want to rest', 'ENG');
      expect(out, contains('REST'));
      expect(out, isNot(contains('WAIT')));
    });
  });

  group('numeral duration compounds', () {
    test('two weeks incorporates to 2-WEEKS', () {
      final out = glosses('I will stay for two weeks', 'ENG');
      expect(out, contains('2-WEEKS'));
    });

    test('three days ago incorporates to 3-DAYS-AGO', () {
      final out = glosses('I called three days ago', 'ENG');
      expect(out.join(' '), contains('3-DAYS'));
    });
  });

  group('hindi caption repair', () {
    test('doctor and medicine resolve instead of passing through', () {
      final out = glosses('मुझे डॉक्टर को दवाई चाहिए', 'HI');
      expect(out, contains('DOCTOR'));
      expect(out, contains('MEDICINE'));
    });

    test('जा रहा हूँ drops the progressive auxiliary', () {
      final out = glosses('मैं अस्पताल जा रहा हूँ', 'HI');
      expect(out, contains('GO'));
      expect(out, contains('HOSPITAL'));
      expect(out.join(' '), isNot(contains('रहा')));
    });

    test('कर इम्पेराटिव drops as support verb, never TAX', () {
      final out = glosses('मुझे मदद करो', 'HI');
      expect(out, contains('HELP'));
      expect(out, isNot(contains('TAX')));
    });

    test('मिलूँगा resolves to MEET', () {
      final out = glosses('कल मैं डॉक्टर से मिलूँगा', 'HI');
      expect(out, contains('DOCTOR'));
      expect(out, contains('MEET'));
    });
  });

  group('कल tense awareness', () {
    test('future verb makes कल TOMORROW', () {
      final out = glosses('कल मैं डॉक्टर से मिलूँगा', 'HI');
      expect(out, contains('TOMORROW'));
      expect(out, isNot(contains('YESTERDAY')));
    });

    test('past verb makes कल YESTERDAY', () {
      final out = glosses('कल मैं स्कूल गया', 'HI');
      expect(out, contains('YESTERDAY'));
      expect(out, isNot(contains('TOMORROW')));
    });

    test('romanized future kal is TOMORROW', () {
      final out = glosses('kal main delhi jaunga', 'HI');
      expect(out, contains('TOMORROW'));
      expect(out, contains('GO'));
    });
  });

  group('asl-lex assigns a word to its own sign', () {
    /// ASL-LEX gives each sign a name and a list of loose English equivalents,
    /// and the build used to pick whichever entry was signed most often. That
    /// let a frequent sign claim a word another sign is named after: TEASE lists
    /// "warm" and out-frequency-signs WARM, so every warm sentence was glossed
    /// as a teasing gesture. Names now beat aliases, and these rows are the
    /// flips that rule paid for. `weather → COLD` and `temperature → HOT` came
    /// from the same contest, and both read as a wrong sign to a viewer.
    const ownSign = {
      'warm': ('WARM', 'warm'),
      'warmth': ('WARM', 'warm'),
      'weather': ('WEATHER', 'weather'),
      'windy': ('WINDY', 'windy'),
      'snow': ('SNOW', 'snow'),
      'cloud': ('CLOUD', 'cloud'),
      'cold': ('COLD', 'cold'),
      'shower': ('SHOWER', 'shower'),
      'degree': ('DEGREE', 'degree'),
      'temperature': ('THERMOMETER', 'thermometer'),
      'about': ('ABOUT', 'about'),
      'angry': ('ANGRY', 'angry'),
      'come': ('COME', 'come'),
      // ASL-LEX also carries a fingerspelled WHAT whose lemma is dotted out as
      // `w.h.a.t`, which normalises to the word "what" and nearly out-names the
      // real sign. The dotted form is a handshape, not a word.
      'what': ('WHAT', 'what_1'),
      'holiday': ('HOLIDAY', 'holiday'),
      'need': ('NEED', 'need'),
      'see': ('SEE', 'see'),
      'love': ('LOVE', 'love'),
    };

    for (final entry in ownSign.entries) {
      test('${entry.key} resolves to ${entry.value.$1}', () {
        final found = AslSignLexicon.lookup(entry.key);
        expect(found, isNotNull, reason: '${entry.key} left the lexicon');
        expect(found!.gloss, entry.value.$1);
        expect(found.id, entry.value.$2);
      });
    }

    test('no gloss carries an unconfirmed-reference tilde', () async {
      // SignBank prefixes a leading '~' on cross-references it has not
      // verified. Those reached the app as part of a token gloss, so the built
      // asset is scanned rather than a sample of sentences.
      final text = await rootBundle.loadString(
        'assets/lexicon/asl_sign_lexicon.txt',
      );
      expect(
        text.split('\n').where((line) => line.contains('~')).toList(),
        isEmpty,
      );
    });
  });
}
