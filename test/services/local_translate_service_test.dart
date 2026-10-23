import 'package:flutter_test/flutter_test.dart';
import 'package:sign_bridge/services/translate/local_translate_service.dart';
import 'package:sign_bridge/services/translate/translate_service.dart';

void main() {
  group('LocalTranslateService', () {
    test(
      'stopListening returns empty result when no speech captured',
      () async {
        final service = LocalTranslateService(forceMockListening: true);
        await service.startListening('ENG');
        final result = await service.stopListening('ENG');

        expect(result.hasTranscript, isFalse);
        expect(result.fullTranscript, isEmpty);
        expect(result.signSequence, isEmpty);
        expect(result.signSystem, SignLanguageSystem.asl);
      },
    );

    test('mock captions only grow until stop', () async {
      final service = LocalTranslateService(forceMockListening: true);
      await service.prepareListening('ENG');

      final updates = <TalkListenUpdate>[];
      final sub = service.listenUpdates().listen(updates.add);
      await service.activateListening();

      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await sub.cancel();

      expect(updates.length, greaterThan(2));
      var previousLength = 0;
      for (final update in updates) {
        expect(
          update.fullTranscript.length,
          greaterThanOrEqualTo(previousLength),
        );
        previousLength = update.fullTranscript.length;
      }
      expect(updates.last.fullTranscript, contains('Hello'));
    });

    test('subscribe before activate receives partial captions', () async {
      final service = LocalTranslateService(forceMockListening: true);
      await service.prepareListening('ENG');

      final updates = <TalkListenUpdate>[];
      final sub = service.listenUpdates().listen(updates.add);
      await service.activateListening();

      await Future<void>.delayed(const Duration(milliseconds: 600));
      await sub.cancel();

      expect(updates.any((u) => u.fullTranscript.isNotEmpty), isTrue);
    });

    test('mock session emits final update with ASL gloss sequence', () async {
      final service = LocalTranslateService(forceMockListening: true);
      await service.startListening('ENG');

      TalkListenUpdate? finalUpdate;
      final sub = service.listenUpdates().listen((update) {
        if (update.isFinal) {
          finalUpdate = update;
        }
      });

      await Future<void>.delayed(const Duration(seconds: 4));
      await sub.cancel();

      expect(finalUpdate, isNotNull);
      final update = finalUpdate!;
      expect(update.fullTranscript, contains('Hello'));
      expect(update.signSystem, SignLanguageSystem.asl);
      expect(update.signSequence.map((t) => t.gloss), isNotEmpty);
    });

    test('partial updates carry the whole phrase as an append-only sequence',
        () async {
      // Live dictation used to hand the avatar the previous partial's
      // sequence — empty for the entire session — so the rig fell back to
      // signing the single active word over and over: one hand, one sign,
      // while the caption grew. The mock transcript also reorders (TODAY
      // fronts as soon as it is heard), so the live sequence must keep what
      // was already shown and append only the words that are new.
      final service = LocalTranslateService(forceMockListening: true);
      await service.prepareListening('ENG');

      final updates = <TalkListenUpdate>[];
      final sub = service.listenUpdates().listen(updates.add);
      await service.activateListening();
      await Future<void>.delayed(const Duration(milliseconds: 3000));
      await sub.cancel();

      final partials = updates.where((u) => !u.isFinal).toList();
      expect(partials.length, greaterThan(2));
      expect(
        partials.last.signSequence,
        isNotEmpty,
        reason: 'dictation must sign the phrase, not a single token',
      );
      var previous = <String>[];
      for (final update in partials) {
        final ids = update.signSequence.map((t) => t.id).toList();
        expect(
          ids.take(previous.length),
          previous,
          reason: 'a partial must never rewind or reorder what was shown',
        );
        previous = ids;
      }
      expect(
        partials.last.signSequence.length,
        greaterThan(1),
        reason: 'by the end of the mock phrase the avatar has words to sign',
      );
    });

    test('mock session emits audio level updates while listening', () async {
      final service = LocalTranslateService(forceMockListening: true);
      await service.startListening('ENG');

      final levels = <double>[];
      final sub = service.audioLevelUpdates().listen(levels.add);

      await Future<void>.delayed(const Duration(milliseconds: 600));
      await sub.cancel();

      expect(levels, isNotEmpty);
      expect(levels.any((level) => level > 0.1), isTrue);
    });

    test('mock audio levels rise while words stream in', () async {
      final service = LocalTranslateService(forceMockListening: true);
      await service.prepareListening('ENG');

      final levels = <double>[];
      final levelSub = service.audioLevelUpdates().listen(levels.add);
      await service.activateListening();

      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await levelSub.cancel();

      expect(levels.length, greaterThan(4));
      final peak = levels.reduce((a, b) => a > b ? a : b);
      final quiet = levels.take(3).reduce((a, b) => a < b ? a : b);
      expect(peak, greaterThan(quiet + 0.15));
    });

    test('cancelListening clears an active mock session', () async {
      final service = LocalTranslateService(forceMockListening: true);
      await service.startListening('ENG');
      await service.cancelListening();
      final result = await service.stopListening('ENG');

      expect(result.hasTranscript, isFalse);
    });
  });
}
