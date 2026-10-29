import 'package:flutter_test/flutter_test.dart';
import 'package:sign_bridge/services/translate/asl_sign_lexicon.dart';
import 'package:sign_bridge/services/translate/english_lexicon.dart';
import 'package:sign_bridge/services/translate/sign_gloss_mapper.dart';
import 'package:sign_bridge/services/translate/sign_language_system.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await EnglishLexicon.load();
    await AslSignLexicon.load();
  });

  test('English maps to ASL gloss sequence', () {
    final sequence = SignGlossMapper.signSequence(
      'Hello, how are you today?',
      'ENG',
    );
    expect(sequence.map((t) => t.gloss).toList(), [
      'TODAY',
      'HELLO',
      'YOU',
      'HOW',
      '[wh-q]',
    ]);
    expect(sequence.first.system, SignLanguageSystem.asl);
  });

  test('ASL rules move time first and question words last', () {
    final sequence = SignGlossMapper.signSequence(
      'What are you doing today?',
      'ENG',
    );
    expect(sequence.map((t) => t.gloss).toList(), [
      'TODAY',
      'YOU',
      'DO',
      'WHAT',
      '[wh-q]',
    ]);
  });

  test('ISL rules use subject-object-verb order', () {
    final sequence = SignGlossMapper.signSequence('I am going home', 'HI');
    expect(sequence.map((t) => t.gloss).toList(), ['ME', 'HOME', 'GO']);
    expect(sequence.first.system, SignLanguageSystem.isl);
  });

  test('Hindi maps to ISL gloss sequence', () {
    final sequence = SignGlossMapper.signSequence('नमस्ते, कैसे हैं', 'HI');
    expect(sequence.first.system, SignLanguageSystem.isl);
    expect(sequence.first.gloss, 'HELLO');
    expect(sequence.map((t) => t.gloss), contains('HOW'));
  });

  test('known words are glossed not fingerspelled', () {
    final sequence = SignGlossMapper.signSequence('This is really good', 'ENG');
    expect(sequence.map((t) => t.gloss).toList(), ['THIS', 'REAL', 'GOOD']);
  });

  test('common adjectives use the sign that names them', () {
    // ORANGE_EYES is a sibling sign a little more frequent than AMAZING and
    // lists "amazing" among its dominant translations; frequency alone used to
    // hand it the word, so the AMAZING sign was never shown for its own name.
    final sequence = SignGlossMapper.signSequence('amazing', 'ENG');
    expect(sequence.map((t) => t.gloss).toList(), ['AMAZING']);
    expect(sequence.map((t) => t.id).toList(), ['amazing']);
  });

  test('the ASL-LEX table prefers a word\'s own sign over a rival', () {
    // Each of these was answered by another sign's English-equivalent list,
    // which wins on frequency alone: TRAFFIC for cars, BRIDESMAID for flowers,
    // STAMP_1 for state. `tears` is in the plural exception list because
    // inheriting TEAR would sign a drop from an eye; it keeps CRY.
    const expected = {
      'amazing': 'AMAZING',
      'cars': 'CAR',
      'flowers': 'FLOWER',
      'matches': 'MATCH',
      'state': 'STATE',
      'tears': 'CRY',
      'what': 'WHAT',
    };
    for (final entry in expected.entries) {
      expect(
        AslSignLexicon.lookup(entry.key)?.gloss,
        entry.value,
        reason: entry.key,
      );
    }

    // A sign whose SignBank gloss is still unassigned makes no claim at all,
    // so the word is not left pointing at NEED-ID-GLOSS.
    for (final word in ['skate', 'skates', 'ice-skating']) {
      expect(
        AslSignLexicon.lookup(word)?.gloss,
        isNot('NEED-ID-GLOSS'),
        reason: word,
      );
    }
  });

  test('asl sign lexicon loads thousands of certified entries', () {
    expect(AslSignLexicon.loadedEntryCount, greaterThan(6000));
  });

  test('english dictionary loads hundreds of thousands of words', () {
    expect(EnglishLexicon.loadedWordCount, greaterThan(200000));
  });

  test('ASL moves frequency first then object before verb', () {
    final sequence = SignGlossMapper.signSequence('Check it once', 'ENG');
    expect(sequence.map((t) => t.gloss).toList(), ['ONCE', 'IX', 'CHECK']);
  });

  test('place names gloss on chip', () {
    expect(
      SignGlossMapper.signSequence(
        'I live in Mumbai',
        'ENG',
      ).map((t) => t.gloss).toList(),
      contains('MUMBAI'),
    );
    expect(
      SignGlossMapper.signSequence(
        'I live in Bengaluru',
        'ENG',
      ).map((t) => t.gloss).toList(),
      contains('BENGALURU'),
    );
  });

  test('ASL unknown word uses fallback gloss instead of hiding', () {
    final sequence = SignGlossMapper.signSequence('ME eat xyzxyz', 'ENG');
    expect(sequence, isNotEmpty);
    expect(sequence.map((t) => t.gloss).join(' '), contains('EAT'));
  });

  test('Check it shows IX CHECK while streaming two words', () {
    final sequence = SignGlossMapper.signSequence('Check it', 'ENG');
    expect(sequence.map((t) => t.gloss).toList(), ['IX', 'CHECK']);
  });

  test('ASL topic-comment orders object before subject and verb', () {
    final sequence = SignGlossMapper.signSequence('I like candy', 'ENG');
    expect(sequence.map((t) => t.gloss).toList(), ['SWEET', 'ME', 'LIKE']);
  });

  test('ASL uses FINISH for past only when no time anchor', () {
    final withoutTime = SignGlossMapper.signSequence('I ran', 'ENG');
    expect(withoutTime.map((t) => t.gloss).toList(), [
      'ME',
      'RUN',
      'FINISH',
      'ME',
    ]);

    final withTime = SignGlossMapper.signSequence('I ran yesterday', 'ENG');
    expect(withTime.map((t) => t.gloss).toList(), ['YESTERDAY', 'ME', 'RUN']);
  });

  // Past marking is three-way: FINISH, a past time anchor, or the question
  // face. These pin the cases that used to read as present.
  test('past auxiliaries did and had mark the clause past', () {
    List<String> gloss(String sentence) => SignGlossMapper.signSequence(
      sentence,
      'ENG',
    ).map((t) => t.gloss).toList();

    expect(gloss('I did not go to the party'), contains('FINISH'));
    expect(gloss('I had to leave early'), contains('FINISH'));
    expect(gloss('They sorted the columns'), contains('FINISH'));
  });

  test('a neutral time word does not replace FINISH', () {
    final gloss = SignGlossMapper.signSequence(
      'I bought a ticket this weekend',
      'ENG',
    ).map((t) => t.gloss).toList();
    expect(gloss, contains('FINISH'));
  });

  test('a copula plus adverb plus adjective is not a past verb', () {
    final gloss = SignGlossMapper.signSequence(
      'I am quite bewildered by the news',
      'ENG',
    ).map((t) => t.gloss).toList();
    expect(gloss, isNot(contains('FINISH')));
  });

  test('a future clause does not turn its participles past', () {
    final gloss = SignGlossMapper.signSequence(
      'Security officers will closely scrutinize all luggage items left inside '
      'the station',
      'ENG',
    ).map((t) => t.gloss).toList();
    expect(gloss, contains('WILL'));
    expect(gloss, isNot(contains('FINISH')));
  });

  test('a past verb before the future auxiliary still marks past', () {
    final gloss = SignGlossMapper.signSequence(
      'My computer screen went blank and now it will not turn on',
      'ENG',
    ).map((t) => t.gloss).toList();
    expect(gloss, contains('FINISH'));
    expect(gloss, contains('WILL'));
  });

  test('an intransitive past verb followed by a preposition stays finite', () {
    final gloss = SignGlossMapper.signSequence(
      'The two ships arrived at the same coordinate',
      'ENG',
    ).map((t) => t.gloss).toList();
    expect(gloss, contains('FINISH'));
  });

  test('a caption that opens with time signs that time first', () {
    final gloss = SignGlossMapper.signSequence(
      'Every Saturday morning I clean my whole house',
      'ENG',
    ).map((t) => t.gloss).toList();
    expect(gloss.take(3).toList(), ['EVERY', 'SATURDAY', 'MORNING']);
  });

  test('a wh-word inside a statement does not add a question face', () {
    final gloss = SignGlossMapper.signSequence(
      'The actor who later won the award thanked the crew',
      'ENG',
    ).map((t) => t.gloss).toList();
    expect(gloss, isNot(contains('[wh-q]')));
    expect(gloss, contains('FINISH'));
  });

  test('ASL negation is post-fix NOT with headshake', () {
    final sequence = SignGlossMapper.signSequence("I don't like pizza", 'ENG');
    expect(sequence.map((t) => t.gloss).toList(), [
      'PIZZA',
      'ME',
      'LIKE',
      'NOT',
      '[headshake]',
    ]);
  });

  test('ASL topic-comment for simple noun verb', () {
    final sequence = SignGlossMapper.signSequence('The dog is running', 'ENG');
    expect(sequence.map((t) => t.gloss).toList(), ['DOG', 'RUN']);
  });

  test('ASL name introduction uses standard MY NAME order', () {
    final sequence = SignGlossMapper.signSequence('My name is Rajendra', 'ENG');
    expect(sequence.map((t) => t.gloss).toList(), [
      'MY',
      'NAME',
      'FS-R',
      'FS-A',
      'FS-J',
      'FS-E',
      'FS-N',
      'FS-D',
      'FS-R',
      'FS-A',
    ]);
  });

  test('ASL hello name introduction keeps greeting first', () {
    final sequence = SignGlossMapper.signSequence(
      'Hello my name is Rajendra',
      'ENG',
    );
    expect(sequence.map((t) => t.gloss).toList(), [
      'HELLO',
      'MY',
      'NAME',
      'FS-R',
      'FS-A',
      'FS-J',
      'FS-E',
      'FS-N',
      'FS-D',
      'FS-R',
      'FS-A',
    ]);
  });

  test('ASL I am name uses ME gloss and word gloss for casual intro', () {
    final sequence = SignGlossMapper.signSequence('I am Rajendra', 'ENG');
    expect(sequence.map((t) => t.gloss).toList(), ['ME', 'RAJENDRA']);
  });

  test('ASL your name is uses YOUR NAME order and fingerspells name', () {
    final sequence = SignGlossMapper.signSequence('Your name is shanu', 'ENG');
    expect(sequence.map((t) => t.gloss).toList(), [
      'YOUR',
      'NAME',
      'FS-S',
      'FS-H',
      'FS-A',
      'FS-N',
      'FS-U',
    ]);
  });

  test('ASL what is your name uses YOUR NAME WHAT', () {
    final sequence = SignGlossMapper.signSequence('What is your name', 'ENG');
    expect(sequence.map((t) => t.gloss).toList(), ['YOUR', 'NAME', 'WHAT']);
  });

  test('ASL identity noun drops is and keeps demonstrative order', () {
    expect(
      SignGlossMapper.signSequence(
        'It is cat',
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['IX', 'CAT'],
    );
    expect(
      SignGlossMapper.signSequence(
        'That is dog',
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['THAT', 'DOG'],
    );
    expect(
      SignGlossMapper.signSequence(
        'This is my house',
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['THIS', 'MY', 'HOUSE'],
    );
  });

  test('ASL yes-no questions use YOU verb order without DO', () {
    expect(
      SignGlossMapper.signSequence(
        'Do you understand',
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['[y/n-q]', 'YOU', 'UNDERSTAND', 'YOU'],
    );
    expect(
      SignGlossMapper.signSequence(
        'Do you understand me',
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['[y/n-q]', 'YOU', 'UNDERSTAND', 'ME', 'YOU'],
    );
    expect(
      SignGlossMapper.signSequence(
        'Are you coming',
        'ENG',
      ).map((t) => t.gloss).toList(),
      // "coming" used to reach ARRIVE: ASL-LEX lists "come" among the English
      // equivalents of the ARRIVE sign, and that row out-frequency-signs COME.
      // A word now answers with the sign named after it.
      ['[y/n-q]', 'YOU', 'COME', 'YOU'],
    );
  });

  test('ASL negative imperative uses post-fix NOT', () {
    expect(
      SignGlossMapper.signSequence(
        "don't tell this",
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['TELL', 'THIS', 'NOT', '[headshake]'],
    );
  });

  test('ASL fingerspells unknown English words letter by letter', () {
    final sequence = SignGlossMapper.signSequence('you flabbergasted', 'ENG');
    expect(sequence.map((t) => t.gloss).toList(), ['YOU', 'BLOW-MIND']);
  });

  test('ASL what happened phrases use WH-final and HAPPEN gloss', () {
    expect(
      SignGlossMapper.signSequence(
        'what happened',
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['HAPPEN', 'WHAT'],
    );
    expect(
      SignGlossMapper.signSequence(
        'what is happening',
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['HAPPEN', 'WHAT'],
    );
    expect(
      SignGlossMapper.signSequence(
        'what happened to you',
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['YOU', 'HAPPEN', 'WHAT'],
    );
    expect(
      SignGlossMapper.signSequence(
        'tell me what happened',
        'ENG',
      ).map((t) => t.gloss).toList(),
      // HAPPENED is past and the clause is not a question, so FINISH stays.
      ['ME', 'TELL', 'WHAT', 'HAPPEN', 'FINISH'],
    );
    expect(
      SignGlossMapper.signSequence(
        'I am telling you what happened',
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['ME', 'TELL-YOU', 'WHAT', 'HAPPEN', 'FINISH'],
    );
  });

  test('ASL greeting phrases use standard gloss order', () {
    expect(
      SignGlossMapper.signSequence(
        'Nice to meet you',
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['NICE', 'MEET', 'YOU'],
    );
    expect(
      SignGlossMapper.signSequence(
        'Nice meeting you',
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['NICE', 'MEET', 'YOU'],
    );
    expect(
      SignGlossMapper.signSequence('Hello', 'ENG').map((t) => t.gloss).toList(),
      ['HELLO'],
    );
    expect(
      SignGlossMapper.signSequence('Hi', 'ENG').map((t) => t.gloss).toList(),
      ['HELLO'],
    );
    expect(
      SignGlossMapper.signSequence(
        'Good morning',
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['GOOD', 'MORNING'],
    );
    expect(
      SignGlossMapper.signSequence(
        'Goodbye',
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['GOODBYE'],
    );
    expect(
      SignGlossMapper.signSequence(
        'Good to see you',
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['GOOD', 'SEE', 'YOU'],
    );
    expect(
      SignGlossMapper.signSequence(
        'How are you',
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['HOW', 'YOU'],
    );
    expect(
      SignGlossMapper.signSequence(
        'Welcome',
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['WELCOME'],
    );
    expect(
      SignGlossMapper.signSequence(
        'See you later',
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['SEE', 'YOU', 'LATER'],
    );
  });

  test('ASL daily-life phrases for holiday and scheduling', () {
    expect(
      SignGlossMapper.signSequence(
        'today is a holiday for me',
        'ENG',
      ).map((t) => t.gloss).toList(),
      // HOLIDAY, not VACATION: the word answers with its own sign now that a
      // sign's name outranks another sign's list of English equivalents.
      ['TODAY', 'HOLIDAY', 'ME'],
    );
    expect(
      SignGlossMapper.signSequence(
        'I have not decided yet',
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['YET', 'ME', 'DECIDE', 'NOT', '[headshake]'],
    );
    expect(
      SignGlossMapper.signSequence(
        'dont disturb im studing',
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['BOTHER', 'ME', 'STUDY', 'NOT', '[headshake]'],
    );
    expect(
      SignGlossMapper.signSequence(
        "don't disturb I'm studying",
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['BOTHER', 'ME', 'STUDY', 'NOT', '[headshake]'],
    );
    expect(
      SignGlossMapper.signSequence(
        'doctor will come to the shop after 9:30',
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['WILL', 'DOCTOR', 'SHOP', '9:30', 'COME'],
    );
    expect(
      SignGlossMapper.signSequence(
        "don't disturb",
        'ENG',
      ).map((t) => t.gloss).toList(),
      ['BOTHER', 'NOT', '[headshake]'],
    );
  });

  test('ASL lexical finish verb does not conflict with aspect FINISH', () {
    expect(
      SignGlossMapper.signSequence(
        'We must work hard to accelerate our reading progress to finish the syllabus this semester.',
        'ENG',
      ).isNotEmpty,
      isTrue,
    );
  });

  test('ASL try not maintain with conditional if clause keeps time first', () {
    expect(
      SignGlossMapper.signSequence(
        'Try not to maintain a pessimistic attitude if it rains on the first day of your summer vacation.',
        'ENG',
      ).isNotEmpty,
      isTrue,
    );
  });

  test('ASL possessive strips apostrophe s before gloss lookup', () {
    final glosses = SignGlossMapper.signSequence(
      "The sick cat's daily progress improved.",
      'ENG',
    ).map((t) => t.gloss).toList();
    expect(glosses, contains('CAT'));
    expect(glosses.where((g) => g.length == 1 && g == 'C'), isEmpty);
  });

  test(
    'ASL puts a negated if-clause inside the condition, not at clause end',
    () {
      final glosses = SignGlossMapper.signSequence(
        'The doctor will change your treatment plan if the fever does not drop.',
        'ENG',
      ).map((t) => t.gloss).toList();
      expect(glosses, contains('NOT'));
      // The condition is fronted, so NOT must sit before the main clause verb: a
      // clause-final NOT would negate *the doctor will change* instead.
      expect(glosses.indexOf('NOT'), lessThan(glosses.indexOf('CHANGE')));
      expect(glosses.indexOf('NOT'), greaterThan(glosses.indexOf('FEVER')));
    },
  );

  test('ASL keeps main-clause negation when an if-clause follows it', () {
    final glosses = SignGlossMapper.signSequence(
      'Do not hesitate to read film reviews online if you are struggling to '
          'understand the complex ending.',
      'ENG',
    ).map((t) => t.gloss).toList();
    expect(glosses, contains('NOT'));
    expect(glosses.lastWhere((g) => !g.startsWith('[')), 'NOT');
  });

  test(
    'ASL signs both negations when each half of an if sentence is negated',
    () {
      final glosses = SignGlossMapper.signSequence(
        'Try not to maintain a pessimistic attitude if a casual dating match '
            'does not lead to a relationship.',
        'ENG',
      ).map((t) => t.gloss).toList();
      expect(glosses.where((g) => g == 'NOT').length, 2);
    },
  );

  test('ASL signs a because statement with a reason, not a question', () {
    final glosses = SignGlossMapper.signSequence(
      'I am stuck in heavy traffic on the highway right now, so I will arrive '
          'about twenty minutes late.',
      'ENG',
    ).map((t) => t.gloss).toList();
    // The speaker gave a reason. [rh-q] WHY asks a question the caption never
    // asked, and ME LATE alone deleted ARRIVE, TWENTY and MINUTES.
    expect(glosses, isNot(contains('[rh-q]')));
    expect(glosses, isNot(contains('WHY')));
    expect(glosses, contains('SO'));
    expect(glosses, containsAll(['ARRIVE', '20', 'MINUTE', 'LATE']));
  });

  test('ASL keeps both halves of a because clause', () {
    final glosses = SignGlossMapper.signSequence(
      'I want a cold coffee because the weather is incredibly hot today.',
      'ENG',
    ).map((t) => t.gloss).toList();
    expect(glosses, isNot(contains('[rh-q]')));
    expect(glosses, isNot(contains('WHY')));
    expect(glosses, containsAll(['COFFEE', 'WANT', 'WEATHER', 'HOT', 'VERY']));
    expect(glosses, isNot(contains('AWFUL')));
  });

  test('ASL reads so before an adjective as an intensifier, not a junction', () {
    final glosses = SignGlossMapper.signSequence(
      'I received an A grade on my research paper, and I am so happy and '
          'relieved.',
      'ENG',
    ).map((t) => t.gloss).toList();
    expect(glosses, isNot(contains('[rh-q]')));
    expect(glosses, isNot(contains('WHY')));
    expect(glosses, containsAll(['SO', 'HAPPY', 'RELIEVED']));
  });

  test('the live preview waits for a word it can sign', () {
    // A finished caption never comes back blank, so the rules answer an
    // all-function-word caption with its own words. Mid-sentence that answer is
    // a word the final pass drops, so the live run skips it until content
    // arrives.
    expect(SignGlossMapper.hasLiveSigns('The', 'ENG'), isFalse);
    expect(SignGlossMapper.hasLiveSigns('A the', 'ENG'), isFalse);
    expect(SignGlossMapper.hasLiveSigns('The weather', 'ENG'), isTrue);
    expect(SignGlossMapper.signSequence('The', 'ENG'), isNotEmpty);
  });

  test('ISL signs Hindi words a phrase sentence used to hide', () {
    // These words were only reachable through a whole-sentence phrase rule, so
    // a caption that is not one of those lines — or a prefix of one — came back
    // as Devanagari with no sign behind it.
    expect(
      SignGlossMapper.signSequence('मुझे एक कप', 'HI').map((t) => t.gloss).toList(),
      ['ME', 'CUP'],
    );
    expect(
      SignGlossMapper.signSequence('नल से पानी टपक', 'HI')
          .map((t) => t.gloss)
          .toList(),
      containsAll(['WATER', 'DRIP']),
    );
    expect(
      SignGlossMapper.signSequence('आधार कार्ड की फोटोकॉपी चाहिए', 'HI')
          .map((t) => t.gloss)
          .toList(),
      containsAll(['AADHAAR', 'CARD', 'XEROX']),
    );
  });

  test('ISL reads Devanagari digits as numbers', () {
    final glosses = SignGlossMapper.signSequence(
      'कल मीटिंग सुबह १०',
      'HI',
    ).map((t) => t.gloss).toList();
    expect(glosses, containsAll(['MEETING', '10']));
  });
}
