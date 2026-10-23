import 'package:flutter_test/flutter_test.dart';

import 'package:sign_bridge/services/avatar/rig/indic_spelling.dart';

/// The gloss engine hands the avatar a token id, and for a word its lexicon
/// does not know that id is still written in the caption's script. The manual
/// alphabet is the English one, so those tokens had no letters to spell and the
/// avatar held still for the length of a sign.
///
/// These pins are the rune-by-rune output of the mapping rather than a claim
/// about transliteration standards: each one was read off the table, so a table
/// that shifts a slot shows up here as a word spelled wrong.
void main() {
  group('indic letters to latin', () {
    test('devanagari', () {
      expect(IndicSpelling.toLatin('गर्म'), 'garma');
      expect(IndicSpelling.toLatin('हो'), 'ho');
      expect(IndicSpelling.toLatin('होगा'), 'hoga');
      expect(IndicSpelling.toLatin('धूप'), 'dhoopa');
      expect(IndicSpelling.toLatin('आसमान'), 'aasamana');
      expect(IndicSpelling.toLatin('पूर्वाभास'), 'poorvabhasa');
    });

    test('tamil', () {
      expect(IndicSpelling.toLatin('பெய்கிறது'), 'peykirathu');
      expect(IndicSpelling.toLatin('பெய்யும்'), 'peyyum');
      expect(IndicSpelling.toLatin('அதிகம்'), 'athikam');
      expect(IndicSpelling.toLatin('வானத்தில்'), 'vanaththil');
    });

    test('malayalam', () {
      expect(IndicSpelling.toLatin('പെയ്യുന്നു'), 'peyyunnu');
      expect(IndicSpelling.toLatin('വെറും'), 'verun');
    });

    test('a matra replaces the inherent a, a virama kills it', () {
      // प pa, े e -> pe. The same consonant with no matra keeps the vowel only
      // at the end of the word, and a virama takes it away anywhere else.
      expect(IndicSpelling.toLatin('प'), 'pa');
      expect(IndicSpelling.toLatin('प्'), 'p');
      expect(IndicSpelling.toLatin('प्प'), 'ppa');
      expect(IndicSpelling.toLatin('पे'), 'pe');
      expect(IndicSpelling.toLatin('पेप'), 'pepa');
    });

    test('a script with no table is passed through for the caller to reject', () {
      // Nothing here guesses at a language the avatar has no alphabet for; the
      // sign library then drops the token instead of spelling noise.
      expect(IndicSpelling.toLatin('水'), '水');
      expect(IndicSpelling.containsIndic('水'), isFalse);
      expect(IndicSpelling.containsIndic('गर्म'), isTrue);
    });

    test('latin text is returned untouched', () {
      for (final plain in ['today', 'hot_dog', 'cloud-in', 'num_5', '']) {
        expect(IndicSpelling.toLatin(plain), plain);
        expect(IndicSpelling.containsIndic(plain), isFalse);
      }
    });

    test('mixed ids keep both halves', () {
      expect(IndicSpelling.toLatin('गर्म2'), 'garma2');
      expect(IndicSpelling.containsIndic('गर्म2'), isTrue);
    });
  });
}
