/// Latin spelling for Devanagari, Tamil and Malayalam.
///
/// Only one thing uses this: a gloss token the lexicon could not resolve keeps
/// its caption script as its id, and the avatar's manual alphabet is the
/// English one, so the token had no letters to spell. It rendered as a still
/// hand for the length of a sign, which the viewer reads as the app stopping.
/// Indian Sign Language fingerspells a word that has no sign of its own, so
/// turning the script into the sounds it writes is what the hand should do next.
///
/// This is a letter-name mapping, not a transliteration standard. The point is a
/// spelling a reader can decode, not a linguistic romanization, and it is what
/// most phone keyboards already produce for these languages.
///
/// Every table is listed in code-point order. The three scripts share the
/// scholarly order of the Devanagari block, so each has 37 consonants and 16
/// matras at a fixed offset, and a table is checked by counting rather than by
/// knowing the language; slots a script does not use are empty strings.
abstract final class IndicSpelling {
  /// True when [text] contains a letter of one of the three scripts.
  static bool containsIndic(String text) {
    for (final unit in text.runes) {
      if (unit >= 0x0900 && unit <= 0x0D7F) return true;
    }
    return false;
  }

  /// [text] with every Indic letter replaced by the latin letters that name its
  /// sound. Anything that is not one of the three scripts is passed through, so
  /// an english id comes back unchanged.
  ///
  /// A bare consonant carries its inherent 'a', which a matra replaces and a
  /// virama kills: गर्म becomes `garma` and हो becomes `ho`.
  static String toLatin(String text) {
    if (!containsIndic(text)) return text;

    var out = '';
    var inherentA = false;

    void flush() {
      if (inherentA) out += 'a';
      inherentA = false;
    }

    for (final unit in text.runes) {
      final consonant = _consonantAt(unit);
      if (consonant != null) {
        flush();
        out += consonant;
        inherentA = true;
        continue;
      }

      final matra = _matraAt(unit);
      if (matra != null) {
        // The 'aa' matra is the one that adds to the inherent vowel instead of
        // standing in for it.
        out += matra == 'aa' ? 'a' : matra;
        inherentA = false;
        continue;
      }

      final letter = _vowelOrMarkAt(unit);
      if (letter != null) {
        flush();
        out += letter;
        continue;
      }

      if (!_isIndic(unit)) {
        flush();
        out += String.fromCharCode(unit);
        continue;
      }

      // A virama, a nukta, a zero-width joiner: silence, so it ends the
      // consonant without releasing its inherent vowel.
      inherentA = false;
    }

    flush();
    return out;
  }

  static bool _isIndic(int unit) =>
      (unit >= _deva && unit <= _deva + 0x7F) ||
      (unit >= _tamil && unit <= _tamil + 0x7F) ||
      (unit >= _malayalam && unit <= _malayalam + 0x7F);

  static String? _consonantAt(int unit) {
    for (final block in _consonantBlocks) {
      final value = block.read(unit);
      if (value != null) return value.isEmpty ? null : value;
    }
    return null;
  }

  static String? _matraAt(int unit) {
    for (final block in _matraBlocks) {
      final value = block.read(unit);
      if (value != null) return value.isEmpty ? null : value;
    }
    return null;
  }

  static String? _vowelOrMarkAt(int unit) {
    for (final block in _vowelBlocks) {
      final value = block.read(unit);
      if (value != null) return value.isEmpty ? null : value;
    }
    return null;
  }
}

/// A run of code points and the latin spelling of each, index for index.
class _Table {
  const _Table(this.first, this.values);

  final int first;
  final List<String> values;

  /// null when [unit] is outside the run, so the caller can try the next script.
  String? read(int unit) {
    final offset = unit - first;
    if (offset < 0 || offset >= values.length) return null;
    return values[offset];
  }
}

const _deva = 0x0900;
const _tamil = 0x0B80;
const _malayalam = 0x0D00;

const _vowelBlocks = <_Table>[
  // अ आ इ ई उ ऊ ऋ ऌ ऍ ऎ ए ऐ ऑ ऒ ओ औ
  _Table(_deva + 0x04, [
    'a', 'a', 'aa', 'i', 'ee', 'u', 'oo', 'ri', 'li', 'e', 'e', //
    'e', 'ai', 'o', 'o', 'o', 'au',
  ]),
  // ँ ं ः
  _Table(_deva + 0x01, ['n', 'n', 'h']),
  // அ ஆ இ ஈ உ ஊ (three unused) எ ஏ ஐ (unused) ஒ ஓ ஔ
  _Table(_tamil + 0x05, [
    'a', 'aa', 'i', 'ee', 'u', 'oo', '', '', '', //
    'e', 'ee', 'ai', '', 'o', 'oo', 'au',
  ]),
  // ஂ ஃ
  _Table(_tamil + 0x02, ['n', 'h']),
  // അ ആ ഇ ഈ ഉ ഊ ഋ ഌ (unused) എ ഏ ഐ (unused) ഒ ഓ ഔ
  _Table(_malayalam + 0x05, [
    'a', 'aa', 'i', 'ee', 'u', 'oo', 'ri', 'li', '', //
    'e', 'ee', 'ai', '', 'o', 'oo', 'au',
  ]),
  // ം ഃ
  _Table(_malayalam + 0x02, ['n', 'h']),
];

const _consonantBlocks = <_Table>[
  // क ख ग घ ङ च छ ज झ ञ ट ठ ड ढ ण त थ द ध न ऩ प फ ब भ म य र ऱ ल ळ ऴ व श ष स ह
  _Table(_deva + 0x15, [
    'k', 'kh', 'g', 'gh', 'n', 'ch', 'chh', 'j', 'jh', 'n', //
    't', 'th', 'd', 'dh', 'n', 't', 'th', 'd', 'dh', 'n', //
    'n', 'p', 'ph', 'b', 'bh', 'm', 'y', 'r', 'r', 'l', //
    'l', 'l', 'v', 'sh', 'sh', 's', 'h',
  ]),
  // க (three unused) ங ச (unused) ஜ (unused) ஞ ட (three unused) ண த (three
  // unused) ந ன ப (three unused) ம ய ர ற ல ள ழ வ ஶ ஷ ஸ ஹ
  _Table(_tamil + 0x15, [
    'k', '', '', '', 'n', 'ch', '', 'j', '', 'n', //
    't', '', '', '', 'n', 'th', '', '', '', 'n', //
    'n', 'p', '', '', '', 'm', 'y', 'r', 'r', 'l', //
    'l', 'zh', 'v', 'sh', 'sh', 's', 'h',
  ]),
  // ക ഖ ഗ ഘ ങ ച ഛ ജ ഝ ഞ ട ഠ ഡ ഢ ണ ത ഥ ദ ധ ന ഩ പ ഫ ബ ഭ മ യ ര റ ല ള ഴ വ ശ ഷ സ ഹ
  _Table(_malayalam + 0x15, [
    'k', 'kh', 'g', 'gh', 'n', 'ch', 'chh', 'j', 'jh', 'n', //
    't', 'th', 'd', 'dh', 'n', 't', 'th', 'd', 'dh', 'n', //
    'n', 'p', 'ph', 'b', 'bh', 'm', 'y', 'r', 'r', 'l', //
    'l', 'l', 'v', 'sh', 'sh', 's', 'h',
  ]),
];

const _matraBlocks = <_Table>[
  // ा ि ी ु ू ृ ॄ ॅ ॆ े ै ॉ ॊ ो ौ ्
  _Table(_deva + 0x3E, [
    'aa', 'i', 'ee', 'u', 'oo', 'ri', 'ri', 'e', 'e', 'e', //
    'ai', 'o', 'o', 'o', 'au', '',
  ]),
  // ா ி ீ ு ூ (three unused) ெ ே ை (unused) ொ ோ ௌ ்
  _Table(_tamil + 0x3E, [
    'aa', 'i', 'ee', 'u', 'oo', '', '', '', //
    'e', 'ee', 'ai', '', 'o', 'oo', 'au', '',
  ]),
  // ാ ി ീ ു ൂ ഃ ഄ (unused) െ േ ൈ (unused) ൊ ോ ൌ ്
  _Table(_malayalam + 0x3E, [
    'aa', 'i', 'ee', 'u', 'oo', 'ri', 'ri', '', //
    'e', 'ee', 'ai', '', 'o', 'oo', 'au', '',
  ]),
];
