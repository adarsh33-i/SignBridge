import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sign_bridge/services/avatar/rig/sign_library.dart';
import 'package:sign_bridge/services/translate/asl_core_lexicon.dart';
import 'package:sign_bridge/services/translate/asl_grammar_rules.dart';
import 'package:sign_bridge/services/translate/asl_sign_lexicon.dart';
import 'package:sign_bridge/services/translate/english_lexicon.dart';
import 'package:sign_bridge/services/translate/sign_language_catalog.dart';
import 'package:sign_bridge/services/translate/sign_language_system.dart';
import 'package:sign_bridge/services/translate/sign_grammar_engine.dart';
import 'package:sign_bridge/services/translate/sign_lexicon_builder.dart';
import 'package:sign_bridge/services/translate/sign_token.dart';
import 'package:sign_bridge/services/translate/spoken_text_prep.dart';

/// Audits the caption-to-gloss stage: spoken text in, gloss token sequence out.
///
/// This is the stage *upstream* of `sign_resolution_audit_test.dart`. That one
/// asks whether a gloss token has an animation; this one asks whether the
/// engine built a gloss at all, and whether the gloss still says what the
/// caption said:
///
/// - did every clause produce signs,
/// - is every label gloss notation (uppercase latin, not the caption's script),
/// - did negation, future and past survive, or did the gloss change the meaning,
/// - is every gloss token traceable to a caption word, or did the engine invent
///   a sign the speaker never used,
/// - did a word the lexicon signs disappear inside the rule engine,
/// - does a word reach the sign that *is* that word, or a different sign that
///   merely translates to it,
/// - does the live preview show signs the final playback then drops,
/// - what share of the output is a real gloss versus an English word uppercased.
///
/// Runs on the same sentence fixtures as the sign-resolution audit, so the two
/// reports describe the same corpus.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await EnglishLexicon.load();
    await AslSignLexicon.load();
  });

  test('caption to gloss generation audit', () {
    // The report goes to stdout: a failing expect truncates the log, so the
    // numbers are printed before any gate runs.
    void report(String line) {
      // ignore: avoid_print
      print(line);
    }

    const englishFixtures = [
      'test/fixtures/audit_sentences.txt',
      'test/fixtures/musings_sentences.txt',
      'test/fixtures/themed_sentences.txt',
      'test/fixtures/travel_electronics_sentences.txt',
      'test/fixtures/family_life_sentences.txt',
      'test/fixtures/civic_social_sentences.txt',
      'test/fixtures/dialogue_scenarios_sentences.txt',
      'test/fixtures/category_corpus_sentences.txt',
      'test/fixtures/theme_dialogues_sentences.txt',
    ];

    const islFixture = 'test/fixtures/isl_conversational_sets.txt';

    /// Words the engine is documented to drop, fold into a non-manual marker, or
    /// carry as tense/modality instead of as their own sign. A word outside this
    /// list that vanishes from the gloss is a loss, not a grammar rule.
    const grammaticalDrops = {
      'am', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
      'have', 'has', 'had', 'do', 'does', 'did',
      // Modals — carried by WILL / NOT-CAN / MUST, not by their own sign.
      'can',
      'could',
      'will',
      'shall',
      'would',
      'should',
      'may',
      'might',
      'must',
      'going',
      // Articles, conjunctions, prepositions.
      'a', 'an', 'the', 'and', 'but', 'or', 'of', 'for', 'with', 'at', 'by',
      'from', 'in', 'on', 'into', 'over', 'about', 'as', 'than', 'so', 'too',
      // Negation triggers — carried by NOT / -NOT / headshake.
      'not', 'no', 'never', 'none',
      // Hindi auxiliaries and postpositions.
      'है',
      'हैं',
      'था',
      'थे',
      'का',
      'की',
      'के',
      'को',
      'में',
      'से',
      'पर',
      'और',
      'नहीं',
    };

    /// Past readings the caption states without ambiguity: a past copula, or an
    /// irregular past whose surface cannot also be present tense. Regular `-ed`
    /// goes through [verbStem] instead, because English spells nouns and
    /// adjectives the same way (`speed`, `unused`, `complicated`).
    const explicitPast = {
      'was',
      'were',
      'had',
      'went',
      'made',
      'took',
      'came',
      'saw',
      'said',
      'told',
      'gave',
      'found',
      'knew',
      'wrote',
      'ate',
      'bought',
      'thought',
      'understood',
      'did',
    };

    final authoredIds = SignLibrary.debugCore.keys.toSet();

    String baseOf(String id) => id.replaceAll(RegExp(r'_\d+$'), '');

    /// Whether a lexicon entry documents a sign behind this id.
    bool documentedId(String id) {
      final base = baseOf(id);
      if (authoredIds.contains(base)) return true;
      if (AslSignLexicon.contains(base)) return true;
      final gloss = base.toUpperCase().replaceAll('_', '-');
      return AslCoreLexicon.corpusGlosses.containsKey(base) ||
          AslCoreLexicon.corpusGlosses.values.contains(gloss) ||
          AslCoreLexicon.glossOverrides.containsKey(base) ||
          AslCoreLexicon.pedagogicalOverrides.containsKey(base);
    }

    String tierOf(SignToken token) {
      if (token.id.startsWith('nmm_') || token.gloss.startsWith('[')) {
        return 'marker';
      }
      if (token.id.startsWith('letter_')) return 'spelled-letter';
      if (token.id.startsWith('num_') || token.id.startsWith('time_')) {
        return 'number';
      }
      if (authoredIds.contains(baseOf(token.id))) return 'authored';
      if (documentedId(token.id)) return 'documented';
      return 'passthrough';
    }

    bool isNegation(SignToken t) {
      final g = t.gloss.toUpperCase();
      if (g == '[HEADSHAKE]') return true;
      // Whole words only: NOTIFY, NOTIFICATION and NOTHING are not negations.
      final parts = g.split(RegExp(r'[-_ ]'));
      return parts.contains('NOT') ||
          parts.contains('NO') ||
          parts.contains('NEVER') ||
          parts.contains('NONE') ||
          parts.contains('CANNOT');
    }

    bool isFuture(SignToken t) => t.gloss.toUpperCase().contains('WILL');

    bool isPastMarker(SignToken t) {
      final g = t.gloss.toUpperCase();
      return g == 'FINISH' ||
          g == 'PAST' ||
          g.endsWith('-AGO') ||
          SignGrammarEngine.isPastTimeWord(g.toLowerCase());
    }

    /// Whether `gloss` carries `word` inside it: `BOOK-ON` carries ON, `3-DAYS`
    /// carries TWO as the numeral, `BASED-ON-TOP` carries BASED.
    bool compoundCarries(String gloss, String word) {
      final parts = gloss.toUpperCase().split(RegExp(r'[-/]'));
      final want = word.toUpperCase();
      if (parts.contains(want) || parts.contains(want.replaceAll('_', ''))) {
        return true;
      }
      if (parts.contains(_numerals[want])) return true;
      final singular = want.endsWith('S') && want.length > 3
          ? want.substring(0, want.length - 1)
          : want;
      return parts.any((p) => p == singular) ||
          parts.any((p) => p == '${want}S');
    }

    /// Whether the gloss still represents `word`, allowing the case, number and
    /// pronoun changes the engine documents (them → THEY, ideas → IDEA).
    bool represented(SignToken t, String word, String expectedGloss) {
      if (t.id == word || t.gloss == expectedGloss) return true;
      if (compoundCarries(t.gloss, word) ||
          compoundCarries(t.gloss, expectedGloss)) {
        return true;
      }
      String strip(String x) =>
          x.endsWith('S') && x.length > 3 ? x.substring(0, x.length - 1) : x;
      if (strip(t.gloss.toUpperCase()) == strip(expectedGloss.toUpperCase())) {
        return true;
      }
      final idWord = baseOf(t.id).toLowerCase();
      if (_lookupForms(word).contains(idWord) || '${idWord}s' == word) {
        return true;
      }
      return _pronounTargets[word]?.contains(t.gloss.toLowerCase()) ?? false;
    }

    final sentences = <({String sentence, String code})>[];
    for (final path in englishFixtures) {
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: path);
      for (final line in file.readAsLinesSync()) {
        final s = line.trim();
        if (s.isEmpty || s.startsWith('#')) continue;
        sentences.add((sentence: s, code: 'ENG'));
      }
    }
    final isl = File(islFixture);
    expect(isl.existsSync(), isTrue, reason: 'ISL fixture missing');
    for (final line in isl.readAsLinesSync()) {
      final s = line.trim();
      if (s.isEmpty || s.startsWith('#')) continue;
      final parts = s.split('|');
      expect(parts.length, greaterThanOrEqualTo(2), reason: s);
      sentences.add((sentence: parts[1], code: parts[0]));
    }

    final perLang = <String, _Lang>{};
    final negationLoss = <String>[];
    final futureLoss = <String>[];
    final pastLoss = <String>[];
    final pastQuestionUnmarked = <String>[];
    final labelLeaks = <String>[];
    final whNotFinal = <String>[];
    final timeNotFirst = <String>[];
    final negNotFinal = <String>[];
    final noYesNoFace = <String>[];
    final invented = <String, int>{};
    final inventedSamples = <String>[];
    final lexiconBorrowed = <String, int>{};
    final borrowClasses = <String, int>{};
    final contentLoss = <String, int>{};
    final contentLossSamples = <String>[];
    final passthroughTop = <String, int>{};
    final unreadableLabels = <String, int>{};
    final strays = <String, int>{};
    final straySamples = <String>[];
    final nativePreview = <String, int>{};
    final noisyFailures = <String>[];
    var nonDeterministic = 0;
    var whQuestions = 0;
    var negated = 0;
    var futuring = 0;
    var pastTensed = 0;
    var pastQuestions = 0;
    var yesNoQuestions = 0;
    var noisySentences = 0;
    var lexiconLookups = 0;
    var tokensChecked = 0;
    var tokensUntraced = 0;

    for (final entry in sentences) {
      final code = entry.code;
      final lang = perLang.putIfAbsent(code, () => _Lang());
      lang.sentences++;

      final tokens = SignLanguageCatalog.sequenceFor(entry.sentence, code);
      final again = SignLanguageCatalog.sequenceFor(entry.sentence, code);
      if (tokens.map((t) => t.id).join(' ') !=
          again.map((t) => t.id).join(' ')) {
        nonDeterministic++;
      }

      final glosses = [for (final t in tokens) t.gloss];
      if (tokens.isEmpty) {
        lang.empty++;
        report('EMPTY GLOSS: ${entry.sentence}');
        continue;
      }

      for (final t in tokens) {
        final tier = tierOf(t);
        lang.tiers[tier] = (lang.tiers[tier] ?? 0) + 1;
        lang.tokens++;
        if (tier == 'passthrough') {
          passthroughTop[t.gloss] = (passthroughTop[t.gloss] ?? 0) + 1;
        }
        // Gloss notation is uppercase latin: a word, a numeral, a hyphenated or
        // underscored compound, a two-word gloss like `TWO TIMES`, a contact
        // sign like `I(SNAP)`, a bracketed non-manual marker. Anything else — lower case, or the caption's own
        // Devanagari / Tamil / Malayalam — means source text reached the chip
        // instead of a gloss.
        final shaped =
            RegExp(r'^\[[^\[\]]+\]$').hasMatch(t.gloss) ||
            RegExp(r"^[A-Z0-9][A-Z0-9'’./:,()\-_ ]*[?!]?$").hasMatch(t.gloss);
        if (!shaped) {
          labelLeaks.add('${entry.sentence} => "${t.gloss}" (${t.id})');
        }
        // A variant index (`STAMP_1`) or a contact paren (`E(CALM-DOWN)`) is
        // valid SignBank notation, but it reads to a viewer like a database key
        // rather than a word. The lexicon builder reduces both to the sign's
        // name, so anything left here means a raw key reached the chip.
        if (RegExp(r'_\d+$').hasMatch(t.gloss) || t.gloss.contains('(')) {
          unreadableLabels[t.gloss] = (unreadableLabels[t.gloss] ?? 0) + 1;
        }
      }

      // Meaning checks run on the prepared words — what the rule engine sees
      // after phrase lookup and grammar-token mapping.
      final system = _systemOf(code);
      final prepared = SpokenTextPrep.normalizeForGloss(
        entry.sentence,
        code,
      ).toLowerCase();
      final rawWords = SignLanguageCatalog.splitWords(
        prepared,
      ).map(SignLanguageCatalog.normalize).where((w) => w.isNotEmpty).toList();
      final wordSet = rawWords.toSet();

      if ({'not', 'no', 'never', 'none', 'नहीं'}.any(wordSet.contains)) {
        negated++;
        if (!tokens.any(isNegation)) negationLoss.add(entry.sentence);
      }
      if (wordSet.contains('will') ||
          wordSet.contains('shall') ||
          (wordSet.contains('going') && wordSet.contains('to'))) {
        futuring++;
        if (!tokens.any(isFuture)) futureLoss.add(entry.sentence);
      }
      // Past is a rule of the ASL grammar path; ISL marks its own aspects
      // (गया, -viṭṭatu) and is measured by its own audit.
      // A future auxiliary scopes everything after it, so an -ed word there is
      // a participle ("grade entered on the form", "items left inside") and the
      // caption is not a past statement. A past verb before the auxiliary
      // ("went blank, and now it won't") still counts.
      var firstFutureAt = -1;
      for (var i = 0; i < rawWords.length; i++) {
        final w = rawWords[i];
        final goingTo = w == 'going' && i + 1 < rawWords.length &&
            rawWords[i + 1] == 'to';
        if (w == 'will' || w == 'shall' || goingTo) {
          if (firstFutureAt < 0) firstFutureAt = i;
        }
      }
      final pastWords = code == 'ENG'
          ? <String>[
              for (var i = 0; i < rawWords.length; i++)
                if ((firstFutureAt < 0 || i < firstFutureAt) &&
                    (explicitPast.contains(rawWords[i]) ||
                        SignGrammarEngine.irregularPast
                            .containsKey(rawWords[i]) ||
                        ((rawWords[i].endsWith('ed') ||
                                SignGrammarEngine.irregularPastParticiple
                                    .containsKey(rawWords[i])) &&
                            SignGrammarEngine.isFinitePastSurface(
                              rawWords,
                              i,
                            ))))
                  rawWords[i],
            ]
          : const <String>[];
      final isQuestion = entry.sentence.trim().endsWith('?');
      if (pastWords.isNotEmpty) {
        pastTensed++;
        if (isQuestion) pastQuestions++;
        if (!tokens.any(isPastMarker)) {
          if (isQuestion) {
            pastQuestionUnmarked.add(
              '${entry.sentence} => ${glosses.join(' ')}',
            );
          } else {
            pastLoss.add('${entry.sentence} [${pastWords.join(', ')}]');
          }
        }
      }

      // WH order is only a rule for a clause that asks a question; `how` inside
      // a statement ("...dictate how high you climb") stays where English put it.
      if (entry.sentence.trim().endsWith('?')) {
        final whAt = [
          for (var i = 0; i < tokens.length; i++)
            if (AslGrammarRules.questionWords.contains(
              tokens[i].gloss.toLowerCase(),
            ))
              i,
        ];
        if (whAt.isNotEmpty) {
          whQuestions++;
          final lastContent = tokens.lastIndexWhere(
            (t) => tierOf(t) != 'marker' && !isNegation(t),
          );
          if (whAt.last != lastContent) {
            whNotFinal.add('${entry.sentence} => ${glosses.join(' ')}');
          }
        }
      }

      // Ordering — the grammar, not just the vocabulary. ASL is Time + Topic +
      // Comment, negation sits at the end of the clause, and a yes/no question
      // carries a [y/n-q] face. A gloss can trace every word and still be
      // ungrammatical if these are wrong.
      if (code == 'ENG') {
        final content = [
          for (var i = 0; i < tokens.length; i++)
            if (tierOf(tokens[i]) != 'marker' && !isNegation(tokens[i])) i,
        ];
        // These two checks read one clause's word order, so a fixture that
        // holds two sentences ("... old tree. Shopping.") would compare them
        // against each other.
        final body = entry.sentence.trim().replaceAll(RegExp(r'[.!?]+$'), '');
        final singleSentence = !RegExp(r'[.!?]').hasMatch(body);
        // A conditional keeps its time word inside the condition, and a
        // question puts the WH sign last. This checks the one case that needs
        // no part-of-speech guess: the speaker opened with a time word.
        final captionOpensWithTime =
            rawWords.isNotEmpty && SignGrammarEngine.isTimeWord(rawWords.first);
        if (singleSentence &&
            captionOpensWithTime &&
            !isQuestion &&
            content.isNotEmpty &&
            !SignGrammarEngine.isTimeWord(tokens[content.first].gloss)) {
          timeNotFirst.add('${entry.sentence} => ${glosses.join(' ')}');
        }
        // A negation inside the condition is deliberate (finding 1).
        final conditional = tokens.any(
          (t) => t.gloss.toUpperCase() == 'IF',
        );
        final negAt = tokens.indexWhere(isNegation);
        if (singleSentence && negAt >= 0 && !conditional) {
          final afterNegation = content.where((i) => i > negAt).toList();
          final trailingSubject = afterNegation.length == 1 &&
              _subjectPronouns.contains(
                tokens[afterNegation.single].gloss.toLowerCase(),
              );
          if (afterNegation.length > 1 ||
              (afterNegation.length == 1 && !trailingSubject)) {
            negNotFinal.add('${entry.sentence} => ${glosses.join(' ')}');
          }
        }
        if (isQuestion) {
          final hasWh = tokens.any(
            (t) => AslGrammarRules.questionWords.contains(
              t.gloss.toLowerCase(),
            ),
          );
          if (!hasWh) {
            yesNoQuestions++;
            if (!tokens.any((t) => t.gloss.toUpperCase().contains('Y/N'))) {
              noYesNoFace.add('${entry.sentence} => ${glosses.join(' ')}');
            }
          }
        }
      }

      // Provenance: every content token must descend from a caption word (or a
      // form the engine documents for it), or be one of the tense / polarity /
      // reference signs the engine adds on purpose.
      final stems = <String>{for (final w in wordSet) ..._lookupForms(w)};
      final reachable = <String>{
        for (final stem in stems) ...[
          stem,
          if (SignLexiconBuilder.resolve(stem, system) != null)
            SignLexiconBuilder.resolve(stem, system)!.id,
        ],
      };
      for (final t in tokens) {
        final tier = tierOf(t);
        if (tier == 'marker' || tier == 'spelled-letter' || tier == 'number') {
          continue;
        }
        tokensChecked++;
        final gloss = t.gloss.toUpperCase().replaceAll(RegExp(r'[?!]$'), '');
        final added =
            _engineAdditions.contains(gloss) ||
            _engineAdditions.contains(baseOf(t.id));
        final fromCaption =
            reachable.contains(t.id) ||
            reachable.contains(baseOf(t.id)) ||
            _builtFromCaption(baseOf(t.id), stems);
        if (added || fromCaption) continue;
        lang.invented++;
        tokensUntraced++;
        final key = '$gloss (${t.id})';
        invented[key] = (invented[key] ?? 0) + 1;
        if (inventedSamples.length < 120) {
          inventedSamples.add(
            '$code ${entry.sentence} => ${glosses.join(' ')}  [added $key]',
          );
        }
      }

      // Lexicon fidelity: does the word reach the sign that *is* that word?
      if (code == 'ENG') {
        for (final word in wordSet) {
          if (word.length < 3 || grammaticalDrops.contains(word)) continue;
          final hit = AslSignLexicon.lookup(word);
          if (hit == null) continue;
          lexiconLookups++;
          final base = baseOf(hit.id);
          // `shop -> SHOP (shop_2)` is the word's own sign under a variant key.
          if (hit.id == word ||
              hit.id.replaceAll('_', '') == word ||
              base == word ||
              base.replaceAll('_', '') == word) {
            continue;
          }
          final plural = word.endsWith('s') &&
              (base == word.substring(0, word.length - 1) ||
                  base == word.substring(0, word.length - 2));
          final category = plural ? 'plural' : 'synonym';
          borrowClasses[category] = (borrowClasses[category] ?? 0) + 1;
          final key = '$word -> ${hit.gloss} (${hit.id})';
          lexiconBorrowed[key] = (lexiconBorrowed[key] ?? 0) + 1;
        }
      }

      // Recall: every word the lexicon signs must still be visible in the gloss.
      for (final word in wordSet) {
        if (word.length < 3 || grammaticalDrops.contains(word)) continue;
        // The engine looks a lemma up, so test the same forms it would try.
        final expected =
            [
              for (final stem in _lookupForms(word))
                if (SignLexiconBuilder.resolve(stem, system) != null)
                  SignLexiconBuilder.resolve(stem, system)!,
            ].where(
              (t) =>
                  !t.id.startsWith('letter_') &&
                  !t.id.startsWith('num_') &&
                  !t.id.startsWith('time_'),
            );
        if (expected.isEmpty ||
            expected.any(
              (hit) => tokens.any((t) => represented(t, word, hit.gloss)),
            )) {
          continue;
        }
        final hit = expected.first;
        contentLoss[word] = (contentLoss[word] ?? 0) + 1;
        if (contentLossSamples.length < 30) {
          contentLossSamples.add(
            '$code ${entry.sentence} -> "$word" as ${hit.gloss} '
            'absent from ${glosses.join(' ')}',
          );
        }
      }

      // Live preview: mirror what the viewer actually watches. The recorder
      // appends each partial caption's new signs and nothing else
      // (`LocalTranslateService._liveSequence`), skips a prefix that has no
      // content word, and then replaces the whole run with the reordered final
      // sequence. A stray is a sign the viewer saw that the finished gloss
      // removed.
      final words = entry.sentence.split(RegExp(r'\s+'));
      if (words.length >= 5) {
        final seen = <String>{};
        final preview = <SignToken>[];
        for (var k = 1; k < words.length; k++) {
          final prefix = words.take(k).join(' ');
          if (!SignLanguageCatalog.hasSignableContent(prefix, code)) {
            continue;
          }
          for (final t in SignLanguageCatalog.sequenceFor(prefix, code)) {
            if (seen.add('${t.id}|${t.gloss}')) preview.add(t);
            // A Hindi, Tamil or Malayalam word has no fingerspellable letters,
            // so a preview that reaches the chip in its own script shows the
            // viewer text with no sign behind it. Those languages were only
            // translated inside whole-sentence phrase rules, which a
            // mid-sentence prefix never matches.
            if (_nativeScript.hasMatch(t.gloss)) {
              lang.previewNative++;
              nativePreview['$code ${t.gloss}'] =
                  (nativePreview['$code ${t.gloss}'] ?? 0) + 1;
            }
          }
        }
        final stray = {
          // A preview sign is not a stray if the finished gloss carries the same
          // word inside a compound: the prefix `… stuck in` signs IN and the
          // sentence signs TRAFFIC-ON-TOP, which is the same preposition fused
          // into the verb, not a word the viewer was shown and then lost.
          for (final t in preview)
            if (tierOf(t) != 'marker' &&
                !tokens.any(
                  (f) => f.id == t.id || compoundCarries(f.gloss, t.gloss),
                ))
              t.gloss,
        };
        if (stray.isNotEmpty) {
          lang.previewDrift++;
          for (final s in stray) {
            strays[s] = (strays[s] ?? 0) + 1;
          }
          if (straySamples.length < 20) {
            straySamples.add('${entry.sentence} :: ${stray.join(', ')}');
          }
        }
      }
    }

    // Noisy captions: speech recognition hands over lowercase text with no
    // punctuation, fillers and stutters. Two deterministic degradations of
    // every English fixture must keep the invariants that protect the viewer:
    // never empty, never a raw key, never a word the caption did not say.
    for (final entry in sentences.where((e) => e.code == 'ENG')) {
      final words = entry.sentence.split(RegExp(r'\s+'));
      final bare = entry.sentence
          .replaceAll(RegExp(r'[.,!?;:"]'), '')
          .toLowerCase();
      final variants = <String>{
        bare,
        if (words.length > 3) 'um $bare',
        if (words.length > 6)
          '${words.take(3).join(' ').toLowerCase()} '
              '${words[2].toLowerCase()} '
              '${words.skip(3).join(' ').toLowerCase()}',
      };
      for (final variant in variants) {
        noisySentences++;
        final noisyTokens = SignLanguageCatalog.sequenceFor(variant, 'ENG');
        final noisyAgain = SignLanguageCatalog.sequenceFor(variant, 'ENG');
        if (noisyTokens.map((t) => t.id).join(' ') !=
            noisyAgain.map((t) => t.id).join(' ')) {
          noisyFailures.add('non-deterministic: $variant');
          continue;
        }
        if (noisyTokens.isEmpty) {
          noisyFailures.add('empty: $variant');
          continue;
        }
        for (final t in noisyTokens) {
          final shaped =
              RegExp(r'^\[[^\[\]]+\]$').hasMatch(t.gloss) ||
              RegExp(
                r"^[A-Z0-9][A-Z0-9'’./:,()\-_ ]*[?!]?$",
              ).hasMatch(t.gloss);
          if (!shaped) {
            noisyFailures.add('label ${t.gloss}: $variant');
          }
          if (RegExp(r'_\d+$').hasMatch(t.gloss) || t.gloss.contains('(')) {
            noisyFailures.add('key ${t.gloss}: $variant');
          }
        }
        final noisyPrepared = SpokenTextPrep.normalizeForGloss(
          variant,
          'ENG',
        ).toLowerCase();
        final noisyWords = SignLanguageCatalog.splitWords(noisyPrepared)
            .map(SignLanguageCatalog.normalize)
            .where((w) => w.isNotEmpty)
            .toList();
        final noisySet = noisyWords.toSet();
        if ({'not', 'no', 'never', 'none'}.any(noisySet.contains) &&
            !noisyTokens.any(isNegation)) {
          noisyFailures.add('negation: $variant');
        }
        final noisyStems = <String>{
          for (final w in noisySet) ..._lookupForms(w),
        };
        final noisyReachable = <String>{
          for (final stem in noisyStems) ...[
            stem,
            if (SignLexiconBuilder.resolve(stem, SignLanguageSystem.asl) !=
                null)
              SignLexiconBuilder.resolve(stem, SignLanguageSystem.asl)!.id,
          ],
        };
        for (final t in noisyTokens) {
          final tier = tierOf(t);
          if (tier == 'marker' ||
              tier == 'spelled-letter' ||
              tier == 'number') {
            continue;
          }
          final gloss = t.gloss.toUpperCase().replaceAll(RegExp(r'[?!]$'), '');
          if (_engineAdditions.contains(gloss) ||
              _engineAdditions.contains(baseOf(t.id))) {
            continue;
          }
          if (noisyReachable.contains(t.id) ||
              noisyReachable.contains(baseOf(t.id)) ||
              _builtFromCaption(baseOf(t.id), noisyStems)) {
            continue;
          }
          noisyFailures.add('untraced ${t.gloss}: $variant');
        }
      }
    }

    report('=== CAPTION -> GLOSS GENERATION AUDIT ===');
    for (final entry in perLang.entries) {
      final l = entry.value;
      String pct(int x) => (x * 100 / l.tokens).toStringAsFixed(1);
      report(
        '${entry.key}: ${l.sentences} sentences, ${l.tokens} gloss tokens, '
        'empty glosses ${l.empty}',
      );
      report(
        '  authored ${l.tiers['authored'] ?? 0} (${pct(l.tiers['authored'] ?? 0)})'
        ' | documented ${l.tiers['documented'] ?? 0} (${pct(l.tiers['documented'] ?? 0)})'
        ' | spelled ${l.tiers['spelled-letter'] ?? 0} (${pct(l.tiers['spelled-letter'] ?? 0)})'
        ' | marker ${l.tiers['marker'] ?? 0} (${pct(l.tiers['marker'] ?? 0)})'
        ' | number ${l.tiers['number'] ?? 0} (${pct(l.tiers['number'] ?? 0)})'
        ' | passthrough ${l.tiers['passthrough'] ?? 0} (${pct(l.tiers['passthrough'] ?? 0)})',
      );
      report(
        '  preview shows a sign the final run drops: ${l.previewDrift} clauses'
        ' (${(l.previewDrift * 100 / l.sentences).toStringAsFixed(1)}%)'
        ' | tokens with no caption word behind them: ${l.invented}'
        ' | preview words left in their own script: ${l.previewNative}',
      );
    }
    report('--- meaning checks ---');
    report('negated clauses: $negated, negation lost: ${negationLoss.length}');
    report('future clauses: $futuring, WILL lost: ${futureLoss.length}');
    report('past clauses: $pastTensed, past marking lost: ${pastLoss.length}');
    report(
      'past questions: $pastQuestions, left unmarked (question face carries '
      'tense): ${pastQuestionUnmarked.length}',
    );
    report(
      'question clauses with a wh-sign: $whQuestions, wh not final: '
      '${whNotFinal.length}',
    );
    report('yes/no questions: $yesNoQuestions, without a [y/n] face: '
        '${noYesNoFace.length}');
    report('time sign not first in its clause: ${timeNotFirst.length}');
    report('negation with content after it: ${negNotFinal.length}');
    report('gloss labels that are not gloss notation: ${labelLeaks.length}');
    report('non-deterministic glosses: $nonDeterministic');
    report(
      'content tokens traced to a caption word: '
      '${tokensChecked - tokensUntraced} of $tokensChecked',
    );
    report(
      'lexicon lookups that reached a different sign: '
      '${lexiconBorrowed.length} distinct words, '
      '${lexiconBorrowed.values.fold(0, (a, b) => a + b)} of $lexiconLookups'
      ' (${borrowClasses['plural'] ?? 0} plural, '
      '${borrowClasses['synonym'] ?? 0} synonym)',
    );
    report(
      'words the lexicon signs that vanished from the gloss: '
      '${contentLoss.values.fold(0, (a, b) => a + b)} occurrences of '
      '${contentLoss.length} distinct words',
    );
    report(
      'noisy captions: $noisySentences, invariant failures: '
      '${noisyFailures.length}',
    );

    void dumpList(String heading, List<String> lines, int limit) {
      if (lines.isEmpty) return;
      report('--- $heading (${lines.length}, showing $limit) ---');
      for (final line in lines.take(limit)) {
        report('  $line');
      }
    }

    void dumpTop(String heading, Map<String, int> map, int limit) {
      if (map.isEmpty) return;
      final sorted = map.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      report('--- $heading (${map.length} distinct, top $limit) ---');
      for (final e in sorted.take(limit)) {
        report('  ${e.key}: ${e.value}');
      }
    }

    dumpList('NEGATION LOST', negationLoss, 25);
    dumpList('FUTURE LOST', futureLoss, 25);
    dumpList('PAST MARKING LOST', pastLoss, 25);
    dumpList('PAST QUESTION LEFT UNMARKED', pastQuestionUnmarked, 15);
    dumpList('WH NOT FINAL', whNotFinal, 25);
    dumpList('TIME SIGN NOT FIRST', timeNotFirst, 25);
    dumpList('NEGATION NOT CLAUSE-FINAL', negNotFinal, 25);
    dumpList('YES/NO QUESTION WITHOUT A FACE', noYesNoFace, 25);
    dumpList('NOISY CAPTION BROKE AN INVARIANT', noisyFailures, 25);
    dumpList('NOT GLOSS NOTATION', labelLeaks, 25);
    dumpList('TOKEN WITH NO CAPTION WORD BEHIND IT', inventedSamples, 40);
    dumpList('CONTENT WORD LOST', contentLossSamples, 30);
    dumpList('PREVIEW SIGN DROPPED AT FINAL', straySamples, 20);
    dumpTop('PREVIEW STRAYS BY GLOSS', strays, 25);
    dumpTop('PREVIEW WORDS LEFT IN THEIR OWN SCRIPT', nativePreview, 25);
    dumpTop('LABELS A VIEWER CANNOT READ AS A WORD', unreadableLabels, 25);
    dumpTop('WORDS THE LEXICON SIGNS BUT THE GLOSS DROPPED', contentLoss, 30);
    dumpTop('UNTRACED TOKENS', invented, 25);
    dumpTop('UPPERCASED WORDS WITH NO SIGN BEHIND THEM', passthroughTop, 25);
    dumpTop('WORD REACHED A DIFFERENT SIGN', lexiconBorrowed, 40);

    final out = Platform.environment['CAPTION_GLOSS_AUDIT_OUT'];
    if (out != null) {
      File(out).writeAsStringSync(
        [
          ...negationLoss.map((s) => 'negation-lost\t$s'),
          ...futureLoss.map((s) => 'future-lost\t$s'),
          ...pastLoss.map((s) => 'past-lost\t$s'),
          ...whNotFinal.map((s) => 'wh-not-final\t$s'),
          ...labelLeaks.map((s) => 'bad-label\t$s'),
          ...inventedSamples.map((s) => 'untraced\t$s'),
          ...contentLossSamples.map((s) => 'content-lost\t$s'),
          ...straySamples.map((s) => 'preview-drift\t$s'),
          ...lexiconBorrowed.entries.map(
            (e) => 'lexicon-borrowed\t${e.key}\t${e.value}',
          ),
        ].join('\n'),
      );
    }

    expect(nonDeterministic, 0);
    expect(labelLeaks, isEmpty, reason: 'a gloss label must be gloss notation');
    for (final entry in perLang.entries) {
      expect(
        entry.value.empty,
        0,
        reason: '${entry.key} produced empty glosses',
      );
    }
    expect(
      negationLoss,
      isEmpty,
      reason: 'a dropped negation signs the opposite meaning',
    );
    expect(
      futureLoss,
      isEmpty,
      reason: 'a dropped WILL loses the future tense',
    );
    // Every content token must trace to a caption word, through the engine's
    // own lemmatisation or one of the rewrites documented in
    // `_engineWordRewrites`. Before the reason-clause fix this counter was 45:
    // every because/so statement was answered with an invented [rh-q] WHY, and
    // two were answered with AWFUL for a mere intensifier.
    final untracedTotal = perLang.values.fold(
      0,
      (total, lang) => total + lang.invented,
    );
    expect(
      untracedTotal,
      0,
      reason: 'a gloss token the caption never said is invented text',
    );
    // A Hindi, Tamil or Malayalam word has no fingerspellable letters, so a
    // preview that reaches the chip in its own script shows the viewer text with
    // no sign behind it. Those languages were only translated inside
    // whole-sentence phrase rules, which a mid-sentence prefix never matches:
    // 183 such tokens before the per-word lexicon was filled in.
    final nativeTotal = perLang.values.fold(
      0,
      (total, lang) => total + lang.previewNative,
    );
    expect(
      nativeTotal,
      0,
      reason: 'a caption word the live preview could not sign',
    );
    // 39 tokens across 11 labels before the builder learned to read SignBank
    // notation: TALL_2, E(CALM-DOWN), SHOP_2, ORDER_1, PROBLEM_2 and friends.
    final unreadableTotal =
        unreadableLabels.values.fold(0, (total, n) => total + n);
    expect(
      unreadableTotal,
      0,
      reason: 'a database key reached the chip instead of a word',
    );
    // Past is a grammar rule, not a spelling rule: a statement whose verb is
    // past must carry FINISH, a past time anchor or the -PAST marker. Questions
    // are exempt because the question face and the caption's own time word
    // carry the frame; the exemption is reported, not hidden.
    expect(
      pastLoss,
      isEmpty,
      reason: 'a past statement read as present',
    );
    // ASL is Time + Topic + Comment, and negation closes its clause. Both are
    // grammar, so a gloss can trace every word and still be unreadable.
    expect(
      timeNotFirst,
      isEmpty,
      reason: 'a caption that opened with time signed it later',
    );
    expect(
      negNotFinal,
      isEmpty,
      reason: 'negation did not close its clause',
    );
    // Noise changes the words, not the contract: a degraded caption still may
    // not produce an empty card, a raw key, a dropped negation or a sign the
    // caption never said.
    expect(
      noisyFailures,
      isEmpty,
      reason: 'an invariant held only for clean, punctuated captions',
    );
    // Preview parity is a regression guard, not a quality target: the preview
    // signs a prefix and the final pass may fold or reorder it, so some drift is
    // inherent. These are today's measured ceilings.
    double drift(String code) {
      final l = perLang[code];
      if (l == null || l.sentences == 0) return 0;
      return l.previewDrift * 100 / l.sentences;
    }

    expect(drift('ENG'), lessThanOrEqualTo(5.0));
    expect(drift('TA'), lessThanOrEqualTo(5.0));
    expect(drift('ML'), lessThanOrEqualTo(5.0));
    expect(drift('HI'), lessThanOrEqualTo(35.0));
  });
}

/// Devanagari, Tamil and Malayalam letter ranges.
final _nativeScript = RegExp(r'[\u0900-\u097F\u0B80-\u0BFF\u0D00-\u0D7F]');

final _numerals = const {
  'ONE': '1',
  'TWO': '2',
  'THREE': '3',
  'FOUR': '4',
  'FIVE': '5',
  'SIX': '6',
  'SEVEN': '7',
  'EIGHT': '8',
  'NINE': '9',
};

/// A subject pronoun may follow a clause-final negation in a question
/// ("WATCH NOT YOU?"), so it does not count as content the negation failed to
/// reach.
const _subjectPronouns = {
  'i',
  'me',
  'you',
  'he',
  'she',
  'it',
  'we',
  'us',
  'they',
  'them',
  'ix',
};

/// Every form the engine may look this caption word up under: the surface, the
/// suffix reductions `_lemmatize` performs, and the irregular bases in its verb
/// tables. The audit has to try the same list, because it runs on the caption
/// while the engine runs on the lemma: `guys` is signed BOY, `matches` is signed
/// MATCH and `left` is signed LEAVE. Calling any of those an invented or a lost
/// token would be the audit disagreeing with a normalisation it never
/// reproduced.
List<String> _lookupForms(String word) {
  final forms = <String?>[
    ..._stemForms(word),
    SignGrammarEngine.irregularPast[word],
    SignGrammarEngine.irregularPastParticiple[word],
  ].nonNulls.toSet();
  return forms
      .union(
        forms.expand((f) => _engineWordRewrites[f] ?? const <String>[]).toSet(),
      )
      .toList();
}

/// Whether a token id is assembled out of caption words rather than invented.
/// `elaborate-on-top` is the verb `elaborate` with a locative fused in, and
/// `forgetful` is `forget` with a suffix the engine strips before lookup.
bool _builtFromCaption(String idBase, Set<String> stems) {
  for (final part in idBase.split(RegExp(r'[-_]'))) {
    if (part.isEmpty) continue;
    for (final stem in stems) {
      if (part == stem) return true;
      if (part.length < 4 || stem.length < 4) continue;
      if (part.startsWith(stem) || stem.startsWith(part)) return true;
    }
  }
  return false;
}

/// The regular surface forms: plural, gerund and past endings the engine strips.
List<String> _stemForms(String word) {
  final forms = <String>{word};
  // `you're` is one caption word and two gloss words; the engine's contraction
  // table splits it, so the audit splits it the same way.
  if (word.contains("'") || word.contains('’')) {
    forms.addAll(word.split(RegExp(r"['’]")).where((x) => x.isNotEmpty));
  }
  for (final suffix in ['ies', 'ied']) {
    if (word.endsWith(suffix) && word.length > 4) {
      forms.add('${word.substring(0, word.length - 3)}y');
    }
  }
  if (word.endsWith('s') && word.length > 3) {
    forms.add(word.substring(0, word.length - 1));
    if (word.endsWith('es') && word.length > 4) {
      forms.add(word.substring(0, word.length - 2));
    }
  }
  if (word.endsWith('ing') && word.length > 4) {
    final base = word.substring(0, word.length - 3);
    forms.addAll([base, '${base}e', _undouble(base)]);
  }
  if (word.endsWith('ed') && word.length > 3) {
    final base = word.substring(0, word.length - 2);
    forms.addAll([
      base,
      '${base}e',
      word.substring(0, word.length - 1),
      _undouble(base),
    ]);
  }
  return forms.toList();
}

/// `winning` reduces to `winn` by suffix stripping alone; the engine collapses
/// the doubled consonant to `win`, so the audit has to as well.
String _undouble(String base) =>
    _doubledTail.hasMatch(base) ? base.substring(0, base.length - 1) : base;

final _doubledTail = RegExp(r'(.)\1$');

/// Conjunctions the engine answers with a different word: a `when` or `while`
/// clause is fronted and marked with DURING (sign_grammar_engine.dart,
/// `_applyDiscourseClauseOrder`). A rewrite the rules document is not an
/// invented sign, but it is worth reading — WHEN is its own sign in ASL.
const _engineWordRewrites = {
  'when': ['during'], // `_applyDiscourseClauseOrder` fronts the clause
  'while': ['during'], // `_applyDiscourseClauseOrder` fronts the clause
  'iced': ['cold-brew'], // `_applyAslRules`: `iced coffee` is one sign
  'minute': ['time'], // `_applyInDurationLead`: `a few minutes` is TIME + span
  'yeah': ['yes'], // contraction expansion table
  // `_compactDegreeClause` folds an intensifier into the degree sign it emits.
  'incredibly': ['very'],
  'quite': ['very'],
  'badly': ['severe'],
  'severely': ['severe'],
};

/// Pronoun cases the engine rewrites on purpose (them → THEY, he → IX).
const _pronounTargets = {
  'them': {'they'},
  'they': {'they'},
  'he': {'ix', 'he'},
  'she': {'ix', 'she'},
  'it': {'ix', 'it'},
  'i': {'me'},
  'us': {'we'},
  'we': {'we'},
  'my': {'my'},
  'mine': {'my'},
  'your': {'your'},
  'yours': {'your'},
  'their': {'their'},
};

/// Signs the engine adds that a caption does not spell out, because ASL and ISL
/// carry tense, polarity and reference with their own signs instead of with
/// auxiliaries: FINISH for a completed action, WILL for the future, NOT for a
/// headshake, IX/ME for a pronoun the rule engine normalised.
const _engineAdditions = {
  'FINISH',
  'WILL',
  'NOT',
  'NOT-CAN',
  'CANNOT',
  'NO',
  'NEVER',
  'MUST',
  'CAN',
  'IX',
  'IX-A',
  'IX-B',
  'IX-C',
  'IX-D',
  'ME',
  'MY',
  'YOUR',
  'WE',
  'US',
  'THEY',
  'THEM',
  'OUR',
  'THEIR',
  'THIS',
  'THAT',
  'TODAY',
  'YESTERDAY',
  'NOW',
  'LATER',
  'BECAUSE',
  'HAVE',
  'IF',
  'IX-PAST',
  'IX-FUTURE',
  'finish',
  'will',
  'not',
  'not-can',
  'ix',
  'me',
  'my',
  'we',
  'they',
  'our',
  'their',
  'this',
  'that',
  'because',
  'have',
  'if',
  'must',
  'can',
  'no',
  'now',
  'today',
  'yesterday',
};

SignLanguageSystem _systemOf(String code) =>
    SignLanguageSystem.forSpokenLanguage(code);

class _Lang {
  int sentences = 0;
  int tokens = 0;
  int empty = 0;
  int invented = 0;
  int previewDrift = 0;
  int previewNative = 0;
  final tiers = <String, int>{};
}
