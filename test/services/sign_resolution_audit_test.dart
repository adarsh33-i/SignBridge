import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sign_bridge/services/avatar/rig/sign_library.dart';
import 'package:sign_bridge/services/translate/asl_core_lexicon.dart';
import 'package:sign_bridge/services/translate/asl_sign_lexicon.dart';
import 'package:sign_bridge/services/translate/english_lexicon.dart';
import 'package:sign_bridge/services/translate/sign_language_catalog.dart';

/// Walks every sentence fixture through the gloss engine and the avatar
/// library, and classifies every token the avatar is ever asked to sign.
///
/// The question this answers is not "does the token render something" — the
/// fingerspell fallback guarantees that — but "does it render the SIGN". A
/// word the lexicon documents a sign for, played back as its letters, is a
/// coverage gap; a word with no sign is fingerspelled on purpose.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await EnglishLexicon.load();
    await AslSignLexicon.load();
  });

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

  /// Ids the library answers with a real sign, so a gap check can skip them.
  final authoredIds = SignLibrary.debugCore.keys.toSet();

  /// Whether the lexicon documents a sign for this id: the ASL-LEX table the
  /// builder resolves against, or the curated curriculum inventory.
  bool documentedSign(String id) {
    final base = id.replaceAll(RegExp(r'_\d+$'), '');
    if (authoredIds.contains(base)) return false;
    if (AslSignLexicon.contains(base)) return true;
    final gloss = base.toUpperCase().replaceAll('_', '-');
    return AslCoreLexicon.corpusGlosses.values.contains(gloss) ||
        AslCoreLexicon.corpusGlosses.keys.contains(base);
  }

  final tiers = <String, int>{};
  final tiersByLang = <String, Map<String, int>>{};
  final dead = <String, int>{};
  final gap = <String, int>{};
  final legitSpell = <String, int>{};
  final authoredSeen = <String>{};
  final perLang = <String, ({int tokens, int sentences})>{};

  void count(Map<String, int> map, String key) =>
      map[key] = (map[key] ?? 0) + 1;

  void ingest(String sentence, String code) {
    final tokens = SignLanguageCatalog.sequenceFor(sentence, code);
    final seen = perLang[code] ?? (tokens: 0, sentences: 0);
    perLang[code] =
        (tokens: seen.tokens + tokens.length, sentences: seen.sentences + 1);
    final langTiers = tiersByLang.putIfAbsent(code, () => {});
    for (final token in tokens) {
      final animation = SignLibrary.forToken(token);
      final String tier;
      if (animation == null) {
        tier = 'dead';
        count(dead, token.id);
      } else if (animation.id.startsWith('spell_')) {
        if (documentedSign(token.id)) {
          tier = 'spelled-gap';
          count(gap, token.id);
        } else {
          tier = 'spelled-ok';
          count(legitSpell, token.id);
        }
      } else if (animation.id.startsWith('nmm_')) {
        tier = 'marker';
      } else {
        tier = animation.id == token.id ? 'authored' : 'alias';
        authoredSeen.add(animation.id);
      }
      count(tiers, tier);
      count(langTiers, tier);
    }
  }

  /// Sentences with the language code the gloss engine should read them in.
  final corpus = <({String sentence, String code})>[];
  for (final path in englishFixtures) {
    final file = File(path);
    if (!file.existsSync()) continue;
    for (final line in file.readAsLinesSync()) {
      final s = line.trim();
      if (s.isEmpty || s.startsWith('#')) continue;
      corpus.add((sentence: s, code: 'ENG'));
    }
  }

  test('full-corpus sign resolution audit', () {
    // Ingested here, not at file scope: the ASL-LEX table is loaded
    // asynchronously in setUpAll, and a gap check that runs before it sees an
    // empty lexicon and reports every spelled word as legitimate.
    final isl = File(islFixture);
    expect(isl.existsSync(), isTrue, reason: 'ISL fixture missing');
    for (final line in isl.readAsLinesSync()) {
      final s = line.trim();
      if (s.isEmpty || s.startsWith('#')) continue;
      final parts = s.split('|');
      expect(parts.length, greaterThanOrEqualTo(2), reason: s);
      corpus.add((sentence: parts[1], code: parts[0]));
    }
    expect(AslSignLexicon.loadedEntryCount, greaterThan(1000),
        reason: 'ASL-LEX table did not load');
    for (final entry in corpus) {
      ingest(entry.sentence, entry.code);
    }

    final total = tiers.values.fold(0, (a, b) => a + b);
    // ignore: avoid_print
    print('=== SIGN RESOLUTION AUDIT ===');
    for (final entry in perLang.entries) {
      final lt = tiersByLang[entry.key]!;
      final signed = (lt['authored'] ?? 0) +
          (lt['alias'] ?? 0) +
          (lt['marker'] ?? 0);
      // ignore: avoid_print
      print('${entry.key}: ${entry.value.sentences} sentences, '
          '${entry.value.tokens} tokens, '
          'signed ${(signed * 100 / entry.value.tokens).toStringAsFixed(1)}% '
          '(${lt['authored'] ?? 0}+${lt['alias'] ?? 0}+${lt['marker'] ?? 0}) | '
          'gap ${lt['spelled-gap'] ?? 0} | spelled-ok ${lt['spelled-ok'] ?? 0} '
          '| dead ${lt['dead'] ?? 0}');
    }
    // ignore: avoid_print
    print('--- combined tiers over $total tokens ---');
    for (final entry in tiers.entries) {
      // ignore: avoid_print
      print('  ${entry.key}: ${entry.value} '
          '(${(entry.value * 100 / total).toStringAsFixed(2)}%)');
    }

    void dump(String heading, Map<String, int> map, int limit) {
      if (map.isEmpty) return;
      // ignore: avoid_print
      print('--- $heading (${map.length} distinct, top $limit) ---');
      final sorted = map.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      for (final entry in sorted.take(limit)) {
        // ignore: avoid_print
        print('  ${entry.key}: ${entry.value}');
      }
    }

    dump('DEAD — renders nothing', dead, 40);
    dump('SPELLED GAP — lexicon documents a sign, avatar spells it', gap, 60);
    final orphans = SignLibrary.debugCore.keys.toSet()..removeAll(authoredSeen);
    // ignore: avoid_print
    print('--- AUTHORED SIGNS THE CORPUS NEVER EMITS (${orphans.length}) ---');
    // ignore: avoid_print
    print('  ${orphans.toList()..sort()}');

    final gapTokens = tiers['spelled-gap'] ?? 0;
    // Leverage: how much of the gap the most frequent ids account for. This is
    // what decides whether authoring a bounded set of signs is worth it.
    final gapSorted = gap.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final n in [25, 50, 100, 200]) {
      final covered = gapSorted
          .take(n)
          .fold(0, (int a, e) => a + e.value);
      // ignore: avoid_print
      print('top $n gap ids cover $covered/$gapTokens gap tokens '
          '(${(covered * 100 / gapTokens).toStringAsFixed(1)}%), '
          'which is ${(covered * 100 / total).toStringAsFixed(1)}% of all tokens');
    }
    // ignore: avoid_print
    print('AUDIT GATES: dead=${dead.length} gapTokens=$gapTokens '
        '(${(gapTokens * 100 / total).toStringAsFixed(1)}% of all tokens)');

    // Env-gated, like test/tools/rig_audit_export_test.dart. The printed list
    // is capped at the top 60; a fit pipeline needs every id to know which
    // gaps the landmark corpus can actually close.
    //
    //   SIGN_AUDIT_OUT=build/audit flutter test test/services/sign_resolution_audit_test.dart
    final outDir = Platform.environment['SIGN_AUDIT_OUT'];
    if (outDir != null && outDir.isNotEmpty) {
      final file = File('$outDir/sign_gap.tsv')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '${gapSorted.map((e) => '${e.key}\t${e.value}').join('\n')}\n',
        );
      // ignore: avoid_print
      print('wrote ${gapSorted.length} gap ids to ${file.path}');
    }

    expect(dead, isEmpty, reason: '${dead.length} token ids render nothing');
  });
}
