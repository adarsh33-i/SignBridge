/// Prepares speech-to-text captions for gloss mapping (Tier 1 / Tier 2 flow).
library;

import 'isl_malayalam_lexicon.dart';
import 'isl_spoken_corpus.dart';
import 'isl_hindi_lexicon.dart';
import 'isl_tamil_lexicon.dart';

abstract final class SpokenTextPrep {
  /// Maps Hindi / Tamil / Malayalam tokens to English grammar words for ISL rules.
  static String normalizeForGloss(String transcript, String languageCode) {
    if (transcript.trim().isEmpty) {
      return transcript;
    }

    final corpus = switch (languageCode) {
      'HI' => IslSpokenCorpus.hindiPhrases,
      'TA' => IslSpokenCorpus.tamilPhrases,
      'ML' => IslSpokenCorpus.malayalamPhrases,
      _ => null,
    };
    if (corpus != null) {
      final trimmed = transcript.trim();
      if (corpus.containsKey(trimmed)) {
        return corpus[trimmed]!;
      }
      final normalized = _normalizeNative(trimmed);
      for (final entry in corpus.entries) {
        if (_normalizeNative(entry.key) == normalized) {
          return entry.value;
        }
      }
    }

    final map = switch (languageCode) {
      'HI' => _hindiGrammarTokens,
      'TA' => _tamilGrammarTokens,
      'ML' => _malayalamGrammarTokens,
      _ => null,
    };
    if (map == null) {
      return transcript;
    }

    final tokens = transcript.split(RegExp(r'\s+'));
    final out = <String>[];
    for (var i = 0; i < tokens.length; i++) {
      final raw = tokens[i];
      if (raw.isEmpty) {
        continue;
      }
      final stripped = raw.replaceAll(
        RegExp(r"^[\p{P}\p{S}']+|[\p{P}\p{S}']+$", unicode: true),
        '',
      );
      if (stripped.isEmpty) {
        continue;
      }
      final canonical = _canonicalNative(stripped);
      if (languageCode == 'HI' &&
          (canonical == 'कल' || canonical.toLowerCase() == 'kal')) {
        out.add(_resolveKal(tokens, i));
        continue;
      }
      final mapped =
          map[stripped] ??
          map[stripped.toLowerCase()] ??
          map[canonical] ??
          map[canonical.toLowerCase()];
      if (mapped == null) {
        final indicEnglish = _indicEnglishFor(languageCode, canonical, map);
        if (indicEnglish != null) {
          if (indicEnglish.isNotEmpty) {
            out.add(indicEnglish);
          }
          continue;
        }
        // Unresolved native tokens: emit the canonical spelling so two Unicode
        // encodings of one word produce one gloss.
        out.add(canonical);
      } else if (mapped.isNotEmpty) {
        out.add(mapped);
      }
    }
    return out.join(' ');
  }

  static String _normalizeNative(String text) {
    return _canonicalNative(
      text,
    ).replaceAll(RegExp(r'[\s]+'), ' ').replaceAll(RegExp(r'[.!?।,;:]+$'), '');
  }

  /// Normalizes script variants that STT and translation sources disagree on:
  /// decomposed vowel signs, Malayalam chillu letters, and Devanagari nukta.
  static String _canonicalNative(String text) {
    var out = text.replaceAll('\u200c', '').replaceAll('\u200d', '').trim();
    for (final entry in _composedSigns.entries) {
      out = out.replaceAll(entry.key, entry.value);
    }
    final buffer = StringBuffer();
    for (var i = 0; i < out.length; i++) {
      final char = out[i];
      final expanded = _chilluLetters[char];
      if (expanded == null) {
        buffer.write(
          _devanagariDigits[char] ?? _devanagariNukta[char] ?? char,
        );
        continue;
      }
      buffer.write(expanded);
      if (i + 1 < out.length && out[i + 1] == '\u0D4D') {
        i++;
      }
    }
    return buffer.toString();
  }

  /// STT returns Devanagari digits for a Hindi caption (१० बजे); the number
  /// rules only read ASCII digits, so they are folded with the script variants.
  static const _devanagariDigits = <String, String>{
    '\u0966': '0',
    '\u0967': '1',
    '\u0968': '2',
    '\u0969': '3',
    '\u096A': '4',
    '\u096B': '5',
    '\u096C': '6',
    '\u096D': '7',
    '\u096E': '8',
    '\u096F': '9',
  };

  static const _composedSigns = <String, String>{
    '\u0BC6\u0BBE': '\u0BCA',
    '\u0BC7\u0BBE': '\u0BCB',
    '\u0BC6\u0BD7': '\u0BCC',
    '\u0D46\u0D3E': '\u0D4A',
    '\u0D47\u0D3E': '\u0D4B',
    '\u0D46\u0D57': '\u0D4C',
  };

  static const _chilluLetters = <String, String>{
    '\u0D7A': '\u0D23\u0D4D',
    '\u0D7B': '\u0D28\u0D4D',
    '\u0D7C': '\u0D30\u0D4D',
    '\u0D7D': '\u0D32\u0D4D',
    '\u0D7E': '\u0D33\u0D4D',
    '\u0D7F': '\u0D15\u0D4D',
  };

  static const _devanagariNukta = <String, String>{
    '\u0958': '\u0915\u093C',
    '\u0959': '\u0916\u093C',
    '\u095A': '\u0917\u093C',
    '\u095B': '\u091C\u093C',
    '\u095C': '\u0921\u093C',
    '\u095D': '\u0922\u093C',
    '\u095E': '\u092B\u093C',
    '\u095F': '\u092F\u093C',
  };

  /// Looks up a native token directly, then retries after stripping the
  /// case/verb endings Tamil, Malayalam, and Hindi add to dictionary roots.
  static String? _indicEnglishFor(
    String languageCode,
    String token,
    Map<String, String> grammar,
  ) {
    if (token.isEmpty) {
      return null;
    }
    final String? Function(String) lexiconLookup;
    final List<String> suffixes;
    switch (languageCode) {
      case 'HI':
        lexiconLookup = IslHindiLexicon.englishFor;
        suffixes = _hindiSuffixesOrdered;
      case 'TA':
        lexiconLookup = IslTamilLexicon.englishFor;
        suffixes = _tamilSuffixesOrdered;
      case 'ML':
        lexiconLookup = IslMalayalamLexicon.englishFor;
        suffixes = _malayalamSuffixesOrdered;
      default:
        return null;
    }
    String? lookup(String word) {
      final hit = lexiconLookup(word);
      return hit ?? grammar[word];
    }

    final direct = lookup(token);
    if (direct != null) {
      return direct;
    }
    // Devanagari nukta letters (क़ ख़ ग़ ज़ ड़ फ़ ज़) are stored in the lexicon
    // as their base consonant.
    final nuktaFree = token.replaceAll('\u093C', '');
    if (nuktaFree != token) {
      final hit = lookup(nuktaFree);
      if (hit != null) {
        return hit;
      }
    }
    for (final suffix in suffixes) {
      if (token.length <= suffix.length + 1 || !token.endsWith(suffix)) {
        continue;
      }
      final stem = token.substring(0, token.length - suffix.length);
      for (final variant in _stemVariants(languageCode, stem, suffix)) {
        final hit = lookup(variant);
        if (hit != null) {
          return hit;
        }
      }
    }
    return null;
  }

  /// Hindi stems lose their final vowel before an oblique ending, so the stem
  /// is retried with both. The ending decides which to try first: ियाँ/ियों come
  /// from ī-stems (लड़की), everything else from ā-stems (लड़का).
  static List<String> _stemVariants(
    String languageCode,
    String stem,
    String suffix,
  ) {
    final out = <String>[stem];
    if (languageCode == 'HI') {
      final iStem = suffix.contains('\u093F\u092F');
      out.addAll(iStem ? ['$stemी', '$stemा'] : ['$stemा', '$stemी']);
      return out;
    }
    if (languageCode == 'TA') {
      return _tamilStemCandidates(stem);
    }
    out.addAll(['$stem്', '$stemുക', '$stemക', '$stemൂ', '$stemം']);
    for (final entry in _malayalamGeminates.entries) {
      if (stem.contains(entry.key)) {
        out.add(stem.replaceAll(entry.key, entry.value));
      }
    }
    if (stem.endsWith('ത്ത')) {
      out.add('${stem.substring(0, stem.length - 3)}ം');
    }
    if (stem.endsWith('യ')) {
      out.add(stem.substring(0, stem.length - 1));
    }
    if (stem.endsWith('ക')) {
      out.add(stem.substring(0, stem.length - 1));
    }
    return out;
  }

  /// Tamil inflection both doubles and drops the root's final consonant, so a
  /// stripped stem is expanded through geminate reduction and consonant
  /// recovery before vowel endings are retried
  /// (வீட்ட → வீட → வீடு, இருக் → இரு → இருக்கு).
  static List<String> _tamilStemCandidates(String stem) {
    final bases = <String>{stem};
    if (stem.endsWith(_tamilPulli) && stem.length > 2) {
      bases.add(stem.substring(0, stem.length - 1));
      bases.add(stem.substring(0, stem.length - 2));
    }
    if (stem.endsWith('ய') || stem.endsWith('ு')) {
      bases.add(stem.substring(0, stem.length - 1));
    }
    for (final base in bases.toList()) {
      for (final entry in _tamilGeminates.entries) {
        if (base.contains(entry.key)) {
          bases.add(base.replaceAll(entry.key, entry.value));
        }
      }
    }
    final out = <String>[];
    for (final base in bases) {
      for (final ending in _tamilStemEndings) {
        final candidate = '$base$ending';
        if (candidate.isNotEmpty && !out.contains(candidate)) {
          out.add(candidate);
        }
      }
    }
    return out;
  }

  static const _tamilPulli = '்';
  static const _tamilStemEndings = [
    '',
    'ு',
    '்',
    'ம்',
    'ம',
    'அ',
    'ஆ',
    'இ',
    'ை',
    'ே',
    'க',
    'கு',
    'க்கு',
    'டு',
  ];

  static const _tamilGeminates = <String, String>{
    'ற்ற': 'ற',
    'ட்ட': 'ட',
    'ப்ப': 'ப',
    'க்க': 'க',
    'ச்ச': 'ச',
    'த்த': 'த',
    'ந்ந': 'ன',
    'ல்ல': 'ல',
    'ம்ம': 'ம',
    'வ்வ': 'வ',
  };

  static const _malayalamGeminates = <String, String>{
    'ട്ട': 'ട്',
    'ക്ക': 'ക്',
    'ച്ച': 'ച്',
    'ത്ത': 'ത്',
    'ന്ന': 'ന്',
    'മ്മ': 'മ്',
    'പ്പ': 'പ്',
    'ല്ല': 'ല്',
    'റ്റ': 'റ്',
    'ഗ്ഗ': 'ഗ്',
    'ദ്ദ': 'ദ്',
    'ബ്ബ': 'ബ്',
    'സ്സ': 'സ്',
  };

  static final List<String> _hindiSuffixesOrdered = _longestFirst(
    _hindiSuffixes,
  );
  static final List<String> _tamilSuffixesOrdered = _longestFirst(
    _tamilSuffixes,
  );
  static final List<String> _malayalamSuffixesOrdered = _longestFirst(
    _malayalamSuffixes,
  );

  /// Strip the most specific postposition first so 'க்களுக்கு' wins over 'க்கு'.
  static List<String> _longestFirst(List<String> suffixes) =>
      [...suffixes]..sort((a, b) => b.length.compareTo(a.length));

  static const _hindiSuffixes = ['ियों', 'ियाँ', 'ों', 'ें', 'े'];
  static const _tamilSuffixes = [
    'ிலிருந்து',
    'இலிருந்து',
    'ுக்கான',
    'க்கான',
    'க்கும்',
    'வுக்கு',
    'ுக்கு',
    'க்கு',
    'யில்',
    'இல்',
    'ில்',
    'ற்கு',
    'ிற்கு',
    'த்தில்',
    'வில்',
    'யை',
    'ஐ',
    'ை',
    'வை',
    'ால்',
    'ஆல்',
    'ுடன்',
    'ஓடு',
    'ிடம்',
    'க்காக',
    'ாக',
    'ஆக',
    'ான',
    'ஆன',
    'ின்',
    'இன்',
    'ும்',
    'உம்',
    'க்கள்',
    'கள்',
    'களை',
    'களுக்கு',
    'வுடன்',
    'ோடு',
    'கிறேன்',
    'கிறோம்',
    'கிறார்',
    'கிறாள்',
    'கிறான்',
    'கிறது',
    'கிறீர்கள்',
    'கிறாய்',
    'கின்றன',
    'கின்றான்',
    'கின்றாள்',
    'கின்றோம்',
    'கின்றீர்கள்',
    'கின்றார்கள்',
    'கின்றது',
    'கிறார்கள்',
    'ங்கள்',
    'ட்டேன்',
    'த்தேன்',
    'ந்தேன்',
    'னேன்',
    'டேன்',
    'க்க',
    'க',
  ];
  static const _malayalamSuffixes = [
    'ില്നിന്ന്',
    'ിലേക്ക്',
    'ലേക്ക്',
    'യില്',
    'ില്',
    'ല്',
    'യ്ക്ക്',
    'ക്ക്',
    'ിന്',
    'ന്റെ',
    'യുടെ',
    'ുടെ',
    'യെ',
    'ിനെ',
    'ോട്',
    'ഓട്',
    'ുമായി',
    'ായി',
    'ാക്കി',
    'വരെ',
    'ോളം',
    'ും',
    'ഉം',
    'കള്',
    'കളെ',
    'കളില്',
    'കളുടെ',
    'യാണ്',
    'മാണ്',
    'ാണ്',
    'ഉണ്ട്',
    'ുണ്ട്',
    'ആണ്',
    'ഉണ്ടോ',
    'ാണോ',
    'ുന്നു',
    'ുന്നുണ്ട്',
    'ുന്നത്',
    'ിക്കുന്നു',
    'ണം',
    'ാം',
    'ച്ചു',
    'ന്നു',
    'ട്ടു',
    'ാൻ',
    'ുക',
    'കൂ',
    'രൂ',
    'ടൂ',
    'ക',
  ];

  /// WH questions when STT omits `?` (तुमारा नाम क्या है / tumara nam kya hai).
  static bool inferWhQuestion(String clause) {
    final trimmed = clause.trim();
    if (trimmed.isEmpty || trimmed.endsWith('?')) {
      return false;
    }
    final lower = trimmed
        .toLowerCase()
        .replaceAll(RegExp(r"[\p{P}\p{S}']", unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    const whFragments = [
      'kya hai',
      'kya ho',
      'kya hain',
      'kab hai',
      'kahan hai',
      'kaha hai',
      'kaun hai',
      'kitna hai',
      'kitni hai',
      'क्या है',
      'कहाँ है',
      'कहां है',
      'कब है',
    ];
    for (final fragment in whFragments) {
      if (lower.contains(fragment)) {
        return true;
      }
    }
    return false;
  }

  /// Y/N when STT omits trailing `?` (Are you… / Do you… / क्या आप…).
  static bool inferYesNoQuestion(String clause) {
    final trimmed = clause.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    if (trimmed.endsWith('?')) {
      return true;
    }

    final lower = trimmed
        .toLowerCase()
        .replaceAll(RegExp(r"[\p{P}\p{S}']", unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    for (final pattern in _yesNoLeadPatterns) {
      if (pattern.hasMatch(lower)) {
        return true;
      }
    }

    for (final prefix in _yesNoHindiPrefixes) {
      if (trimmed.startsWith(prefix)) {
        return true;
      }
    }

    for (final suffix in _yesNoTamilSuffixes) {
      if (trimmed.contains(suffix)) {
        return true;
      }
    }

    for (final suffix in _yesNoMalayalamSuffixes) {
      if (trimmed.contains(suffix)) {
        return true;
      }
    }

    return false;
  }

  static const _yesNoTamilSuffixes = [
    'இருக்கிறதா',
    'போகுமா',
    'ஏற்குமா',
    'விட்டதா',
  ];
  static const _yesNoMalayalamSuffixes = [
    'ഉണ്ടോ',
    'പോകുമോ',
    'സ്വീകരിക്കുമോ',
    'എട്ടിട്ടുണ്ടോ',
  ];

  static final _yesNoLeadPatterns = [
    RegExp(r'^are you\b'),
    RegExp(r'^are we\b'),
    RegExp(r'^are they\b'),
    RegExp(r'^is (he|she|it|this|that|there)\b'),
    RegExp(r'^is your\b'),
    RegExp(r'^do you\b'),
    RegExp(r'^do we\b'),
    RegExp(r'^do they\b'),
    RegExp(r'^does (he|she|it)\b'),
    RegExp(r'^can you\b'),
    RegExp(r'^can we\b'),
    RegExp(r'^could you\b'),
    RegExp(r'^will you\b'),
    RegExp(r'^will we\b'),
    RegExp(r'^would you\b'),
    RegExp(r'^have you\b'),
    RegExp(r'^have we\b'),
    RegExp(r'^has (he|she|it)\b'),
    RegExp(r'^did you\b'),
    RegExp(r'^did we\b'),
    RegExp(r'^was (he|she|it|that)\b'),
    RegExp(r'^were you\b'),
    RegExp(r'^were we\b'),
    RegExp(r'^am i\b'),
  ];

  static const _yesNoHindiPrefixes = ['क्या', 'क्या आप', 'क्या तुम'];

  static const _hindiPastMarkers = {
    'था',
    'थे',
    'थी',
    'थीं',
    'गया',
    'गयी',
    'गये',
    'गए',
    'गई',
    'गईं',
  };

  static const _romanPastMarkers = {
    'tha',
    'thi',
    'the',
    'thin',
    'gaya',
    'gayi',
    'gaye',
    'gayen',
  };

  /// कल means both tomorrow and yesterday; verb tense after it decides
  /// (कल जाऊँगा = tomorrow, कल गया था = yesterday). Defaults to tomorrow.
  static String _resolveKal(List<String> tokens, int kalIndex) {
    for (var i = kalIndex + 1; i < tokens.length; i++) {
      final token = tokens[i].replaceAll(
        RegExp(r"^[\p{P}\p{S}']+|[\p{P}\p{S}']+$", unicode: true),
        '',
      );
      if (token.isEmpty) {
        continue;
      }
      if (_hindiPastMarkers.contains(token) ||
          _romanPastMarkers.contains(token.toLowerCase())) {
        return 'yesterday';
      }
      final lower = token.toLowerCase();
      if (token.endsWith('गा') ||
          token.endsWith('गी') ||
          token.endsWith('गे') ||
          lower.endsWith('ga') ||
          lower.endsWith('gi') ||
          lower.endsWith('ge')) {
        return 'tomorrow';
      }
    }
    return 'tomorrow';
  }

  static const _hindiGrammarTokens = {
    'मैं': 'I',
    'मेरा': 'my',
    'मेरी': 'my',
    'मेरे': 'my',
    'मुझे': 'me',
    'आप': 'you',
    'आपका': 'your',
    'आपकी': 'your',
    'आपके': 'your',
    'तुम': 'you',
    'तुम्हारा': 'your',
    'तुम्हारी': 'your',
    'तुम्हारे': 'your',
    'नाम': 'name',
    'हम': 'we',
    'हमारा': 'our',
    'वे': 'they',
    'वह': 'he',
    'उस': 'he',
    'इस': 'this',
    'नहीं': 'not',
    'नमस्ते': 'hello',
    'कैसे': 'how',
    'कहाँ': 'where',
    'कहां': 'where',
    'क्या': 'what',
    'कौन': 'who',
    'कब': 'when',
    'क्यों': 'why',
    'आज': 'today',
    'स्कूल': 'school',
    'स्कूल में': 'school',
    'घर': 'home',
    'पुस्तक': 'book',
    'किताब': 'book',
    'सेब': 'apple',
    'खाना': 'eat',
    'जाना': 'go',
    'जाता': 'go',
    'जाती': 'go',
    'जाते': 'go',
    'जा': 'go',
    'जाओ': 'go',
    'जाऊँगा': 'go',
    'जाएगा': 'go',
    'जाएगी': 'go',
    'जाएँगे': 'go',
    'जाएँगी': 'go',
    'गया': 'go',
    'गयी': 'go',
    'गये': 'go',
    'गई': 'go',
    'गए': 'go',
    'रहा': '',
    'रही': '',
    'रहे': '',
    'रहें': '',
    'हूँ': '',
    'हूं': '',
    'है': '',
    'हैं': '',
    'था': '',
    'थे': '',
    'थी': '',
    'को': '',
    'में': 'in',
    'पर': 'on',
    'से': 'from',
    'और': '',
    'एक': 'a',
    // Forms the whole-sentence phrase corpus used to be the only path to: a
    // caption that is not one of those lines — or a prefix of one, which is what
    // the live preview sends while the speaker is still talking — fell through
    // to these tokens untranslated and showed as Devanagari instead of a sign.
    // Each gloss is the one the phrase corpus already uses for that word.
    'हो': '',
    'होने': '',
    'होना': '',
    'लिए': '',
    'वाली': '',
    'लगी': '',
    'बजे': "o'clock",
    'मैंने': 'i',
    'कोई': 'any',
    'दो': 'two',
    'बार': 'time',
    'रहता': 'live',
    'रहती': 'live',
    'रहते': 'live',
    'सीख': 'learn',
    'चल': 'go',
    'आ': 'come',
    'आए': 'arrive',
    'लेते': 'take',
    'लेनी': 'take',
    'दिया': 'give',
    'करानी': 'do',
    'तेज': 'strong',
    'जमा': 'submit',
    'पूरा': 'finish',
    'खत्म': 'finish',
    'अच्छी': 'good',
    'कितनी': 'how-much',
    'कितने': 'how-many',
    'चक्कर': 'dizzy',
    'सूज': 'swelling',
    'टपक': 'drip',
    'जांच': 'test',
    'उधार': 'borrow',
    // Romanized Hindi (common STT output on phones)
    'main': 'I',
    'mein': 'I',
    'mera': 'my',
    'meri': 'my',
    'mere': 'my',
    'mujhe': 'me',
    'mujhko': 'me',
    'aap': 'you',
    // 'app' is deliberately absent: it is the usual English spelling of the
    // noun, and mapping it to 'you' rewrites code-switched captions.
    'ap': 'you',
    'aapka': 'your',
    'aapki': 'your',
    'aapke': 'your',
    'apka': 'your',
    'apki': 'your',
    'apke': 'your',
    'tum': 'you',
    'tu': 'you',
    'tumhara': 'your',
    'tumhari': 'your',
    'tumhare': 'your',
    'tumara': 'your',
    'tumari': 'your',
    'tumare': 'your',
    'nam': 'name',
    'naam': 'name',
    'kya': 'what',
    'kaun': 'who',
    'kab': 'when',
    'kahan': 'where',
    'kaha': 'where',
    'kyun': 'why',
    'kyon': 'why',
    'kaise': 'how',
    'nahi': 'not',
    'nahin': 'not',
    'mat': "don't",
    'hai': '',
    'hain': '',
    'ho': '',
    'hun': '',
    'hoon': '',
    'tha': '',
    'the': '',
    'thi': '',
    'aaj': 'today',
    'ghar': 'home',
    'school': 'school',
    'khana': 'eat',
    'jana': 'go',
    'jao': 'go',
    'ja': 'go',
    'jaunga': 'go',
    'jaungi': 'go',
    'jayega': 'go',
    'jayegi': 'go',
    'jayenge': 'go',
    'gaya': 'go',
    'gayi': 'go',
    'gaye': 'go',
    'raha': '',
    'rahi': '',
    'rahe': '',
    'chahiye': 'want',
    'chahie': 'want',
  };

  static const _tamilGrammarTokens = {
    'நான்': 'I',
    'என்': 'my',
    'என்னுடைய': 'my',
    'நீ': 'you',
    'உன்': 'your',
    'நீங்கள்': 'you',
    'உங்கள்': 'your',
    'உங்களுடைய': 'your',
    'நாங்கள்': 'we',
    'நாம்': 'we',
    'நமக்கு': 'we',
    'அவர்': 'he',
    'அவன்': 'he',
    'இவர்': 'he',
    'இவன்': 'he',
    'அவள்': 'she',
    'இவள்': 'she',
    'அவர்கள்': 'they',
    'இவர்கள்': 'they',
    'இது': 'this',
    'அது': 'that',
    'இந்த': 'this',
    'அந்த': 'that',
    'எனக்கு': 'me',
    'என்னிடம்': 'me',
    'உனக்கு': 'you',
    'உன்னிடம்': 'you',
    'உங்களுக்கு': 'you',
    'அவருக்கு': 'he',
    'அவளுக்கு': 'she',
    'எங்களுக்கு': 'we',
    'அவர்களுக்கு': 'they',
    'வணக்கம்': 'hello',
    'எப்படி': 'how',
    'எங்கே': 'where',
    'என்ன': 'what',
    'எப்போது': 'when',
    'ஏன்': 'why',
    'யார்': 'who',
    'எத்தனை': 'how many',
    'எவ்வளவு': 'how much',
    'இன்று': 'today',
    'நேற்று': 'yesterday',
    'நாளை': 'tomorrow',
    'இப்போது': 'now',
    'பிறகு': 'after',
    'முன்': 'before',
    'பள்ளி': 'school',
    'வீடு': 'home',
    'சாப்பிட': 'eat',
    'போ': 'go',
    'இல்லை': 'not',
    'ஆம்': 'yes',
    'சரி': 'ok',
    'தயவுசெய்து': 'please',
    'மன்னிக்கவும்': 'sorry',
    'நன்றி': 'thank you',
    'இருக்கிறது': 'have',
    'இருக்கிறதா': 'have',
    'இருக்கு': 'have',
    'உள்ளது': 'have',
    'உள்ளதா': 'have',
    'உண்டு': 'have',
    'உண்டா': 'have',
    'இருந்தது': 'have',
    'ஆகும்': '',
    'ஆகிறது': '',
    'ஒரு': 'a',
    'ரொம்ப': 'very',
    'மிகவும்': 'very',
    'அதிகமாக': 'much',
    'கொஞ்சம்': 'little',
    'மட்டும்': 'only',
    'மற்றும்': 'and',
    'அல்லது': 'or',
    'ஆனால்': 'but',
    'வேண்டும்': 'want',
    'வேண்டாம்': "don't want",
    'முடியும்': 'can',
    'முடியாது': 'cannot',
    'செய்யவில்லை': 'do not',
    'சாப்பிடவில்லை': 'eat not',
    'புரியவில்லை': 'understand not',
    'தெரியவில்லை': 'know not',
    'வரவில்லை': 'come not',
    'போகவில்லை': 'go not',
    'வாருங்கள்': 'come',
    'போங்கள்': 'go',
    'சொல்லுங்கள்': 'say',
    'கேளுங்கள்': 'listen',
    'பாருங்கள்': 'see',
    'சாப்பிடுங்கள்': 'eat',
    'கொண்டு': '',
    'வெளியே': 'outside',
    'உள்ளே': 'inside',
    'அருகில்': 'near',
    'தூரம்': 'far',
    'வலது': 'right',
    'இடது': 'left',
    'நேராக': 'straight',
    'வேகமாக': 'fast',
    'மெதுவாக': 'slow',
    'தயார்': 'ready',
    'தவறு': 'wrong',
    'எப்போதும்': 'always',
    'சிலநேரம்': 'sometimes',
    'போக': 'go',
    'எழுத': 'write',
    'கேட்க': 'listen',
    'சொல்ல': 'say',
    'பேச': 'speak',
    'வாங்க': 'buy',
    'செய்ய': 'do',
    'மூட': 'close',
    'தொடங்க': 'start',
    'தூங்க': 'sleep',
    'உட்கார': 'sit',
    'நிற்க': 'stand',
    'ஓட': 'run',
    'விளையாட': 'play',
    'பாட': 'sing',
    'ஆட': 'dance',
    'அழ': 'cry',
    'புரிந்துகொள்ள': 'understand',
    'மறக்க': 'forget',
    'தெரிய': 'know',
    'பிடிக்க': 'like',
    'விரும்ப': 'want',
    'கழுவ': 'wash',
    'ஓட்ட': 'drive',
    'அனுப்ப': 'send',
    'கொண்டுவர': 'bring',
    'நிறுத்த': 'stop',
    'வாழ': 'live',
  };

  static const _malayalamGrammarTokens = {
    'ഞാൻ': 'I',
    'എന്റെ': 'my',
    'എൻ്റെ': 'my',
    'നിന്റെ': 'your',
    'നിങ്ങളുടെ': 'your',
    'അവന്റെ': 'his',
    'അവളുടെ': 'her',
    'ഞങ്ങളുടെ': 'our',
    'അവരുടെ': 'their',
    'നീ': 'you',
    'നിങ്ങൾ': 'you',
    'ഞങ്ങൾ': 'we',
    'നമ്മൾ': 'we',
    'നമുക്ക്': 'we',
    'അവൻ': 'he',
    'അവൾ': 'she',
    'അവർ': 'they',
    'ഇവൻ': 'he',
    'ഇവൾ': 'she',
    'ഇവർ': 'they',
    'ഇത്': 'this',
    'അത്': 'that',
    'ഈ': 'this',
    'ആ': 'that',
    'എനിക്ക്': 'me',
    'എനിക്കു': 'me',
    'എന്നോട്': 'me',
    'നിനക്ക്': 'you',
    'നിങ്ങൾക്ക്': 'you',
    'നിങ്ങൾക്കു': 'you',
    'അവന്': 'he',
    'അവൾക്ക്': 'she',
    'ഞങ്ങൾക്ക്': 'we',
    'അവർക്ക്': 'they',
    'ഹലോ': 'hello',
    'എങ്ങനെ': 'how',
    'എവിടെ': 'where',
    'എവിടെയാണ്': 'where',
    'എന്ത്': 'what',
    'എന്താണ്': 'what',
    'എപ്പോൾ': 'when',
    'എപ്പോഴാണ്': 'when',
    'എന്തുകൊണ്ട്': 'why',
    'ആർ': 'who',
    'ആരാണ്': 'who',
    'എത്ര': 'how much',
    'എത്രയാണ്': 'how much',
    'ഇന്ന്': 'today',
    'ഇന്നലെ': 'yesterday',
    'നാളെ': 'tomorrow',
    'ഇപ്പോൾ': 'now',
    'പിന്നീട്': 'after',
    'മുമ്പ്': 'before',
    'സ്കൂൾ': 'school',
    'വീട്': 'home',
    'തിന്ന': 'eat',
    'പോ': 'go',
    'ഇല്ല': 'not',
    'ഒരു': 'a',
    'അതെ': 'yes',
    'ശരി': 'ok',
    'ദയവായി': 'please',
    'ക്ഷമിക്കണം': 'sorry',
    'നന്ദി': 'thank you',
    'ഉണ്ട്': 'have',
    'ഉണ്ടോ': 'have',
    'ഉണ്ടായിരുന്നു': 'have',
    'ആണ്': '',
    'ആണോ': '',
    'ആയിരുന്നു': '',
    'ആകും': '',
    'ആകുന്നു': '',
    'അല്ല': 'not',
    'വേണം': 'want',
    'വേണ്ട': "don't want",
    'വേണ്ടി': 'for',
    'കഴിയും': 'can',
    'കഴിയില്ല': 'cannot',
    'അറിയാം': 'know',
    'അറിയില്ല': 'know not',
    'മനസ്സിലാകും': 'understand',
    'മനസ്സിലായില്ല': 'understand not',
    'തീർന്നു': 'finish',
    'പോയി': 'go',
    'വന്നു': 'come',
    'കഴിച്ചില്ല': 'eat not',
    'പോകാം': 'go',
    'വരാം': 'come',
    'വളരെ': 'very',
    'കൂടുതൽ': 'more',
    'കുറവ്': 'less',
    'വീണ്ടും': 'again',
    'വേഗത്തിൽ': 'fast',
    'പതുക്കെ': 'slow',
    'പുറത്ത്': 'outside',
    'അകത്ത്': 'inside',
    'അടുത്ത്': 'near',
    'ദൂരെ': 'far',
    'വലത്': 'right',
    'ഇടത്': 'left',
    'നേരെ': 'straight',
    'ഉടൻ': 'quick',
    'തെറ്റ്': 'wrong',
    'ആദ്യം': 'first',
    'എപ്പോഴും': 'always',
    'ചിലപ്പോൾ': 'sometimes',
    'ഒരിക്കലും': 'never',
    'കൂടാതെ': 'and',
    'അല്ലെങ്കിൽ': 'or',
    'പക്ഷേ': 'but',
    'മാത്രം': 'only',
  };
}
