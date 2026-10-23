import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sign_bridge/services/translate/spoken_text_prep.dart';

void main() {
  test('inferYesNoQuestion without question mark', () {
    expect(SpokenTextPrep.inferYesNoQuestion('Are you coming'), isTrue);
    expect(SpokenTextPrep.inferYesNoQuestion('Do you understand me'), isTrue);
    expect(SpokenTextPrep.inferYesNoQuestion('What are you doing'), isFalse);
    expect(SpokenTextPrep.inferYesNoQuestion('Are you coming?'), isTrue);
  });

  test('normalizeForGloss maps Hindi tokens to English grammar', () {
    final normalized = SpokenTextPrep.normalizeForGloss(
      'मैं घर जाता हूँ',
      'HI',
    );
    expect(normalized.toLowerCase(), contains('i'));
    expect(normalized.toLowerCase(), contains('home'));
    expect(normalized.toLowerCase(), contains('go'));
  });

  test('Hindi plural noun falls back to the dictionary root', () {
    expect(
      SpokenTextPrep.normalizeForGloss('मुझे किताबें चाहिए', 'HI'),
      'me book want',
    );
    expect(
      SpokenTextPrep.normalizeForGloss('बच्चों कहाँ हैं', 'HI'),
      'baby where',
    );
  });

  test('Tamil maps a spoken sentence word by word', () {
    final normalized = SpokenTextPrep.normalizeForGloss(
      'எனக்கு பழம் வேண்டும்',
      'TA',
    );
    expect(normalized.toLowerCase(), 'me fruit want');
  });

  test('Tamil strips case endings before lookup', () {
    expect(
      SpokenTextPrep.normalizeForGloss(
        'அவர் மருத்துவமனைக்கு போகிறார்',
        'TA',
      ).toLowerCase(),
      'he hospital go',
    );
    expect(
      SpokenTextPrep.normalizeForGloss(
        'பள்ளியில் புத்தகம் உள்ளது',
        'TA',
      ).toLowerCase(),
      'school book have',
    );
  });

  test('Tamil phrase map still wins over the word lexicon', () {
    expect(
      SpokenTextPrep.normalizeForGloss('எனக்கு ஒரு கப் டீ வேண்டும்.', 'TA'),
      'me one cup chai want',
    );
  });

  test('Malayalam maps a spoken sentence word by word', () {
    final normalized = SpokenTextPrep.normalizeForGloss(
      'എനിക്ക് വെള്ളം വേണം',
      'ML',
    );
    expect(normalized.toLowerCase(), 'me water want');
  });

  test('Malayalam chillu variants and case endings normalize', () {
    expect(
      SpokenTextPrep.normalizeForGloss(
        'എൻ്റെ വീട്ടിൽ പോകാം',
        'ML',
      ).toLowerCase(),
      'my home go',
    );
    expect(
      SpokenTextPrep.normalizeForGloss(
        'ഞാൻ ആശുപത്രിയിൽ മരുന്ന് വാങ്ങുന്നു',
        'ML',
      ).toLowerCase(),
      'i hospital medicine buy',
    );
  });

  group('inflected stems reach the lexicon', () {
    String prep(String text, String lang) =>
        SpokenTextPrep.normalizeForGloss(text, lang);

    test('Tamil case stems recover the doubled or dropped consonant', () {
      expect(prep('நான் வீட்டில் இருக்கிறேன்', 'TA'), 'I home have');
      expect(prep('நான் வீட்டிற்கு போகிறேன்', 'TA'), 'I home go');
      expect(prep('புத்தகங்களை கொடுங்கள்', 'TA'), 'book give');
      expect(prep('வணக்கம், எப்படி இருக்கிறீர்கள்?', 'TA'), 'hello how have');
    });

    test('Tamil finite endings strip down to the grammar verb', () {
      expect(prep('பையன் பள்ளிக்கு போகிறான்', 'TA'), 'boy school go');
      expect(prep('மொபைல் எங்கே', 'TA'), 'mobile where');
    });

    test('Hindi ī-stem plural keeps its gender', () {
      expect(prep('लड़कियों स्कूल जा रही हैं', 'HI'), 'girl school go');
      expect(prep('लड़कों स्कूल जा रहे हैं', 'HI'), 'boy school go');
    });

    test('Devanagari nukta spellings resolve through the base consonant', () {
      expect(prep('मुझे एक कलम चाहिए', 'HI'), 'me a pen want');
      expect(prep('क़लम', 'HI'), prep('कलम', 'HI'));
    });

    test('Hindi postpositions and adjectives map', () {
      expect(prep('मेरे पास पानी है', 'HI'), 'my near water');
      expect(prep('मैं ठीक हूँ', 'HI'), 'I ok');
    });

    test('Malayalam perception and article forms map', () {
      expect(prep('അവൻ പുസ്തകം കണ്ടു', 'ML'), contains('see'));
      expect(prep('അവന്റെ ആന വീട്ടിൽ ഉണ്ട്', 'ML'), 'his elephant home have');
    });
  });

  test('code-switched English noun is not rewritten as a pronoun', () {
    expect(
      SpokenTextPrep.normalizeForGloss('the app is good', 'HI'),
      'app is good',
    );
  });

  test('Unicode script variants of one word normalize the same', () {
    String prep(String text, String lang) =>
        SpokenTextPrep.normalizeForGloss(text, lang);

    // chillu, chillu + ZWJ, and explicit virama all mean എന്റെ.
    expect(
      prep('എ\u0D7B\u0D4Dറ\u0D46 വീട്', 'ML'),
      prep('എ\u0D28\u0D4Dറ\u0D46 വീട്', 'ML'),
    );
    expect(
      prep('എ\u0D7B\u200Dറ\u0D46 വീട്', 'ML'),
      prep('എ\u0D28\u0D4Dറ\u0D46 വീട്', 'ML'),
    );
    // Precomposed and decomposed Devanagari nukta.
    expect(prep('क़लम', 'HI'), prep('\u0958\u0932\u092E', 'HI'));
    expect(prep('\u0958\u0932\u092E', 'HI'), 'pen');
  });

  test('every curated native caption normalizes without leftovers', () {
    final lines = File(
      'test/fixtures/isl_conversational_sets.txt',
    ).readAsLinesSync();
    final native = RegExp(r'[\u0900-\u097F\u0B80-\u0BFF\u0D00-\u0D7F]');
    var checked = 0;
    for (final line in lines) {
      final parts = line.split('|');
      if (parts.length < 2) {
        continue;
      }
      final lang = parts[0].trim();
      if (lang != 'HI' && lang != 'TA' && lang != 'ML') {
        continue;
      }
      final caption = parts[1].trim();
      final prepared = SpokenTextPrep.normalizeForGloss(caption, lang);
      checked++;
      expect(prepared, isNotEmpty, reason: caption);
      expect(
        native.hasMatch(prepared),
        isFalse,
        reason: '$lang $caption => $prepared',
      );
    }
    expect(checked, greaterThan(200));
  });
}
