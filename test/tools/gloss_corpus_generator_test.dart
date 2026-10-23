import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sign_bridge/services/translate/asl_sign_lexicon.dart';
import 'package:sign_bridge/services/translate/english_lexicon.dart';
import 'package:sign_bridge/services/translate/sign_gloss_mapper.dart';
import 'package:sign_bridge/services/translate/spoken_text_prep.dart';

/// Corpus generator for the caption→gloss student model.
///
/// Run explicitly:
///   GLOSS_CORPUS_OUT=training/data flutter test test/tools/gloss_corpus_generator_test.dart
///
/// Normal `flutter test` runs skip this file (no output dir set).
///
/// Input `x` is the prepared English token string the app feeds the grammar
/// stage; target `y` is the rule engine's gloss sequence. Each row carries a
/// `system` field (asl / isl) so one model serves both grammars.
void main() {
  final outDir = Platform.environment['GLOSS_CORPUS_OUT'];
  if (outDir == null || outDir.isEmpty) {
    // A file that declares no tests is reported as a failure by `flutter test`,
    // so the ordinary run says what it skipped instead of saying nothing.
    test('corpus generation needs an output directory', () {
      expect(Platform.environment['GLOSS_CORPUS_OUT'], anyOf(isNull, isEmpty));
    });
    return;
  }

  TestWidgetsFlutterBinding.ensureInitialized();

  test('generate gloss corpus', () async {
    await EnglishLexicon.load();
    await AslSignLexicon.load();

    final pairs = <String, Map<String, String>>{};
    final nativeScript = RegExp(
      r'[\u0900-\u097F\u0B80-\u0BFF\u0D00-\u0D7F]',
    );

    void addPair(
      String caption,
      String languageCode,
      String system,
      String source, {
      Map<String, Map<String, String>>? sink,
    }) {
      final prepared = SpokenTextPrep.normalizeForGloss(
        caption,
        languageCode,
      ).trim();
      if (prepared.isEmpty || nativeScript.hasMatch(prepared)) {
        return;
      }
      final glosses = SignGlossMapper.signSequence(caption, languageCode)
          .map((t) => t.gloss)
          .where((g) => g.isNotEmpty)
          .toList();
      if (glosses.isEmpty) {
        return;
      }
      // Reject fingerspelling noise (e.g. spurious T W O W E E K S runs).
      var run = 0;
      var spelledOut = false;
      for (final gloss in glosses) {
        run = gloss.length == 1 ? run + 1 : 0;
        if (run >= 3) {
          spelledOut = true;
          break;
        }
      }
      if (spelledOut) {
        return;
      }
      final key = '$system|$prepared';
      (sink ?? pairs).putIfAbsent(
        key,
        () => {'x': prepared, 'y': glosses.join(' '), 'system': system, 'source': source},
      );
    }

    final english = <String>{};
    final fixtures = Directory('test/fixtures');
    if (fixtures.existsSync()) {
      for (final entity in fixtures.listSync()) {
        if (entity is! File || !entity.path.endsWith('_sentences.txt')) {
          continue;
        }
        for (final line in entity.readAsLinesSync()) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || trimmed.startsWith('#')) {
            continue;
          }
          english.add(trimmed);
        }
      }
    }
    final fixtureEnglish = Set<String>.from(english);

    final islSets = File('test/fixtures/isl_conversational_sets.txt');
    if (islSets.existsSync()) {
      for (final line in islSets.readAsLinesSync()) {
        final parts = line.split('|');
        if (parts.length < 2) {
          continue;
        }
        final lang = parts[0].trim();
        if (lang != 'HI' && lang != 'TA' && lang != 'ML') {
          continue;
        }
        addPair(parts[1].trim(), lang, 'isl', 'isl_conversational');
      }
    }

    final rng = Random(20261019);
    T pick<T>(List<T> xs) => xs[rng.nextInt(xs.length)];

    const subjects = [
      'I', 'you', 'we', 'they', 'he', 'she',
      'my mother', 'my father', 'my sister', 'my brother', 'my friend',
      'my teacher', 'the teacher', 'the doctor', 'the student',
      'my son', 'my daughter', 'my wife', 'my husband', 'the nurse',
      'my neighbor', 'the manager', 'my boss',
    ];
    const people = [
      'mother', 'father', 'sister', 'brother', 'friend', 'teacher',
      'son', 'daughter', 'wife', 'husband', 'neighbor', 'boss',
    ];
    const verbs = [
      'want', 'need', 'like', 'have', 'eat', 'drink', 'buy', 'go', 'come',
      'help', 'find', 'call', 'meet', 'open', 'close', 'finish', 'learn',
      'work', 'play', 'read', 'write', 'wash', 'cook', 'sleep', 'wait',
      'pay', 'drive', 'walk', 'run', 'study', 'watch', 'listen', 'tell',
      'ask', 'give', 'take', 'bring', 'send', 'show', 'try', 'start',
      'stop', 'sit', 'stand', 'know', 'see', 'say', 'make', 'get', 'feel',
      'visit', 'clean', 'carry', 'change', 'choose', 'use', 'check',
      'remember', 'forget', 'understand', 'practice', 'prepare', 'leave',
    ];
    const objects = [
      'water', 'food', 'medicine', 'book', 'phone', 'money', 'ticket',
      'bus', 'train', 'car', 'house', 'key', 'bag', 'chair', 'table',
      'coffee', 'tea', 'milk', 'fruit', 'vegetables', 'clothes', 'shoes',
      'towel', 'soap', 'mask', 'battery', 'charger', 'umbrella', 'map',
      'letter', 'email', 'form', 'pen', 'paper', 'notebook', 'computer',
      'camera', 'rice', 'bread', 'egg', 'sugar', 'salt', 'oil', 'cake',
      'soup', 'juice', 'apple', 'banana', 'potato', 'onion', 'tomato',
      'report', 'document', 'invoice', 'reservation', 'appointment',
      'prescription', 'password', 'address',
    ];
    const places = [
      'home', 'school', 'hospital', 'office', 'station', 'airport',
      'market', 'shop', 'bank', 'temple', 'park', 'restaurant',
      'pharmacy', 'library', 'gym', 'hotel', 'clinic', 'college',
      'theater', 'village', 'city',
    ];
    const times = [
      'today', 'tomorrow', 'yesterday', 'now', 'later', 'this morning',
      'this evening', 'tonight', 'next week', 'last week', 'every day',
      'next month', 'last month', 'next year', 'last year', 'two weeks',
      'three days', 'one hour', 'five minutes', 'this afternoon',
    ];
    const adjectives = [
      'good', 'bad', 'hot', 'cold', 'new', 'old', 'big', 'small', 'easy',
      'difficult', 'fast', 'slow', 'expensive', 'cheap', 'happy', 'sad',
      'tired', 'hungry', 'thirsty', 'sick', 'busy', 'free', 'ready',
      'late', 'early', 'important', 'beautiful', 'clean', 'dirty',
      'quiet', 'loud', 'strong', 'weak', 'safe', 'dangerous',
    ];
    const numbers = ['2', '3', '4', '5', '6', '7', '8', '9', '10', 'two', 'three', 'four', 'five'];
    const units = ['days', 'weeks', 'months', 'years', 'hours', 'minutes', 'dollars'];
    const auxVerbs = ['do', 'does', 'did', 'can', 'will', 'are'];
    const names = [
      'Priya', 'Rahul', 'Anita', 'Arjun', 'Meera', 'Kiran', 'Sara', 'David',
      'Aisha', 'Ravi', 'Neha', 'Vikram', 'Anjali', 'Suresh', 'Lakshmi',
      'Mohan', 'Divya', 'Rohit',
    ];
    const progressiveVerbs = [
      'go', 'eat', 'drink', 'wait', 'read', 'write', 'cook', 'sleep', 'work',
      'study', 'play', 'walk', 'run', 'drive', 'watch', 'clean', 'wash',
      'carry', 'learn', 'practice', 'listen', 'sit', 'stand', 'travel',
      'look', 'help', 'talk', 'buy', 'call', 'visit',
    ];
    const symptoms = [
      'headache', 'fever', 'cough', 'cold', 'pain', 'allergy',
    ];
    const bodyParts = ['head', 'stomach', 'leg', 'back', 'tooth', 'ear'];
    const documents = [
      'passport', 'license', 'form', 'receipt', 'bill', 'prescription',
      'appointment', 'ticket', 'report',
    ];
    const meals = ['breakfast', 'lunch', 'dinner', 'snack'];
    const transport = ['taxi', 'auto', 'bus', 'train', 'flight', 'bicycle'];
    const routine = ['wake', 'dress', 'brush', 'shower', 'eat', 'sleep'];
    const actions = [
      'order', 'cancel', 'confirm', 'sign', 'fill', 'borrow', 'lend',
      'return', 'arrive', 'push', 'pull', 'enter', 'cross', 'park',
      'turn', 'move',
    ];
    const states = [
      'closed', 'full', 'empty', 'correct', 'wrong', 'different', 'same',
      'available', 'possible',
    ];

    String beFor(String subject) {
      final lower = subject.toLowerCase();
      if (lower == 'i') {
        return 'am';
      }
      if (lower.startsWith('you') ||
          lower.startsWith('we') ||
          lower.startsWith('they')) {
        return 'are';
      }
      return 'is';
    }

    bool isPluralSubject(String subject) {
      final lower = subject.toLowerCase();
      return lower == 'i' ||
          lower == 'you' ||
          lower == 'we' ||
          lower == 'they';
    }

    String haveFor(String subject) => isPluralSubject(subject) ? 'have' : 'has';

    String doFor(String subject) => isPluralSubject(subject) ? 'do' : 'does';

    String progressiveOf(String verb) {
      if (verb.endsWith('ie')) {
        return '${verb.substring(0, verb.length - 2)}ying';
      }
      if (verb.endsWith('e') && verb != 'see') {
        return '${verb.substring(0, verb.length - 1)}ing';
      }
      if (verb == 'run') return 'running';
      if (verb == 'sit') return 'sitting';
      if (verb == 'stop') return 'stopping';
      if (verb == 'get') return 'getting';
      if (verb == 'begin') return 'beginning';
      return '${verb}ing';
    }

    // Everyday captions real users speak; greetings and progressive/copula
    // surfaces are absent from the generated templates.
    const conversational = [
      'Hello.', 'Hi.', 'Good morning.', 'Good afternoon.', 'Good evening.',
      'How are you?', 'Hello, how are you?', 'Hello, how are you today?',
      'Hi, how are you?', 'How are you doing?', 'What are you doing?',
      'I am doing well.', 'I am fine.', 'I am not fine.', 'Nice to meet you.',
      'What is your name?', 'My name is Priya.', 'Where are you from?',
      'I am from India.', 'How old are you?', 'I am 20 years old.',
      'Thank you.', 'Thank you very much.', 'You are welcome.',
      'Please help me.', 'Excuse me.', 'I am sorry.', 'See you later.',
      'See you tomorrow.', 'Have a nice day.', 'Take care.', 'Good luck.',
      'Happy birthday.', 'Congratulations.', 'How was your day?',
      'My day was good.', 'Are you okay?', 'I am okay.',
      'I do not understand you.', 'I cannot hear you.', 'I cannot speak.',
      'I am deaf and mute.', 'Do you know sign language?',
      'I need a translator.',
      'I need help.', 'I need water.', 'I need food.', 'I am hungry.',
      'I am thirsty.', 'I am tired.', 'I am sick.', 'I need a doctor.',
      'I need medicine.', 'I need to go home.', 'I need to use the bathroom.',
      'Where is the bathroom?', 'Where is the hospital?',
      'Where is the pharmacy?', 'Where is the station?',
      'Where is my phone?', 'I lost my phone.', 'I lost my wallet.',
      'I lost my bag.', 'I do not understand.', 'Please repeat that.',
      'Please speak slowly.', 'Please write it down.', 'I am deaf.',
      'I use sign language.', 'Do you speak English?', 'Do you speak Hindi?',
      'Can you help me?', 'Can you call my family?', 'Call the doctor.',
      'Call the police.', 'Call an ambulance.', 'Help me please.',
      'I am looking for my friend.', 'My friend is waiting for me.',
      'What time is it?', 'What is this?', 'What is that?',
      'What do you want?', 'What do you need?', 'Why are you sad?',
      'Who is he?', 'Who is she?', 'How much is this?',
      'How much does this cost?', 'Do you have water?',
      'Do you have medicine?', 'Do you have a charger?',
      'I want to buy this.', 'Do you accept cards?', 'I want coffee.',
      'I want tea.', 'I want water.', 'I want food.', 'I want to go home.',
      'I want to rest.', 'I need to rest.', 'I have a headache.',
      'I have a fever.', 'I have a stomach ache.', 'My head hurts.',
      'My stomach hurts.', 'The food is good.', 'The food is cold.',
      'The water is hot.', 'The water is cold.', 'The shop is closed.',
      'The bus is late.', 'The train is coming.', 'It is raining.',
      'It is very hot today.', 'It is very cold today.',
      'I am going home.', 'I am going to work.', 'I am going to school.',
      'I am going to the hospital.', 'I am going to the market.',
      'She is cooking dinner.', 'He is reading a book.',
      'They are waiting for the bus.', 'We are eating lunch.',
      'My mother is cooking.', 'My father is working.',
      'My sister is studying.', 'My brother is sleeping.',
      'My mother is sick.', 'My father is a teacher.',
      'My sister is a student.', 'My friend is a doctor.',
      'I have two children.', 'I have one brother.', 'I live in a city.',
      'I work at a hospital.', 'I work at a school.',
      'I study at a college.', 'I am a student.', 'I am a teacher.',
      'I am a driver.', 'I am a nurse.', 'This is my mother.',
      'This is my father.', 'This is my friend.', 'He is my brother.',
      'She is my sister.', 'My phone is dead.', 'I need a charger.',
      'My battery is low.', 'Where can I charge my phone?',
      'Can I use your phone?', 'I am late.', 'I am ready.', 'I am busy.',
      'I am free.', 'I am happy.', 'I am sad.', 'I am angry.',
      'I am scared.', 'Do not worry.', 'Everything is fine.',
      'Be careful.', 'Wait for me.', 'Come with me.', 'Go with him.',
      'Follow me.', 'Stop here.', 'Turn left.', 'Turn right.',
      'Go straight.', 'It is near.', 'It is far.',
      'How far is the station?', 'How long does it take?',
      'Ten minutes.', 'Thank you for your help.',
      'I am looking for work.', 'I need a job.', 'I need money.',
      'How much is the ticket?', 'One ticket please.',
      'Where is the bus stop?', 'What time does the bus leave?',
      'The train is late.', 'I miss my train.', 'I need a taxi.',
      'Please take me to the airport.', 'My address is here.',
      'Can you show me the way?', 'Is this the right way?',
      'Is this seat free?', 'May I sit here?', 'This seat is taken.',
      'Please open the door.', 'Please close the door.',
      'Please sit down.', 'Please wait here.', 'Please come in.',
      'Please help me find my bag.', 'I am sorry I am late.',
      'It is okay.', 'No problem.', 'I do not know.', 'I forgot.',
      'I remember.', 'I understand.', 'That is correct.', 'That is wrong.',
      'Can you say that again?', 'Can you show me?',
      'I need more time.', 'Please give me a minute.', 'Let us go.',
      'Let us eat.', 'Let us start.', 'Let us go home.',
      'I need to buy medicine for my mother.', 'I need to buy food.',
      'I need to call the doctor.', 'I need to go to the hospital.',
      'I want to buy a ticket.', 'I want to buy new shoes.',
      'I need to rest for two days.', 'I went to Delhi three days ago.',
      'I will go to Delhi tomorrow.', 'I am going to Delhi tomorrow.',
    ];

    const irregularPast = <String, String>{
      'eat': 'ate', 'drink': 'drank', 'buy': 'bought', 'go': 'went',
      'come': 'came', 'find': 'found', 'meet': 'met', 'tell': 'told',
      'give': 'gave', 'take': 'took', 'bring': 'brought', 'send': 'sent',
      'see': 'saw', 'say': 'said', 'make': 'made', 'get': 'got',
      'know': 'knew', 'write': 'wrote', 'drive': 'drove', 'sleep': 'slept',
      'pay': 'paid', 'sit': 'sat', 'stand': 'stood', 'feel': 'felt',
      'leave': 'left', 'read': 'read', 'run': 'ran', 'have': 'had',
      'do': 'did', 'forget': 'forgot', 'understand': 'understood',
    };

    String pastOf(String verb) {
      final irregular = irregularPast[verb];
      if (irregular != null) {
        return irregular;
      }
      if (verb.endsWith('e')) {
        return '${verb}d';
      }
      if (verb.endsWith('y')) {
        return '${verb.substring(0, verb.length - 1)}ied';
      }
      return '${verb}ed';
    }

    final synthetic = <String>{};
    const targetCount = 34000;
    var guard = 0;
    while (synthetic.length < targetCount && guard < targetCount * 20) {
      guard++;
      final s = pick(subjects);
      final p = pick(people);
      final v = pick(verbs);
      final o = pick(objects);
      final place = pick(places);
      final t = pick(times);
      final adj = pick(adjectives);
      final num = pick(numbers);
      final unit = pick(units);
      final aux = pick(auxVerbs);
      final pv = pick(progressiveVerbs);
      final name = pick(names);
      final routineVerb = pick(routine);
      final action = pick(actions);
      final bodyPart = pick(bodyParts);
      final symptom = pick(symptoms);
      final doc = pick(documents);
      final meal = pick(meals);
      final ride = pick(transport);
      final state = pick(states);

      final String sentence;
      switch (rng.nextInt(91)) {
        case 0:
          sentence = '$s $v $o $t.';
        case 1:
          sentence = '$t $s $v $o.';
        case 2:
          sentence = '$s $v $o.';
        case 3:
          sentence = '$s $v $place $t.';
        case 4:
          sentence = '$s do not $v $o.';
        case 5:
          sentence = '$s do not $v $o $t.';
        case 6:
          sentence = '$s want to $v $o.';
        case 7:
          sentence = '$s need to $v $o.';
        case 8:
          sentence = '$s can $v $o.';
        case 9:
          sentence = '$s cannot $v $o.';
        case 10:
          sentence = 'what do $s $v?';
        case 11:
          sentence = 'where $s $v $t?';
        case 12:
          sentence = 'when $s $v $o?';
        case 13:
          sentence = '$aux $s $v $o?';
        case 14:
          sentence = 'who $v $o?';
        case 15:
          sentence = 'why $s $v?';
        case 16:
          sentence = 'how many $o?';
        case 17:
          sentence = 'please $v the $o.';
        case 18:
          sentence = 'my $p wants $o.';
        case 19:
          sentence = '$s $v $o for my $p.';
        case 20:
          sentence = 'the $o is $adj.';
        case 21:
          sentence = 'my $o is $adj.';
        case 22:
          sentence = '$s ${pastOf(v)} $o $t.';
        case 23:
          sentence = 'I want $adj $o.';
        case 24:
          sentence = '$s $v for $num $unit.';
        case 25:
          sentence = '$s $v $num $unit ago.';
        case 26:
          sentence = 'is the $o $adj?';
        case 27:
          sentence = 'are you $adj?';
        case 28:
          sentence = 'where is my $o?';
        case 29:
          sentence = '$s ${pastOf(v)} $place $t.';
        case 30:
          sentence = '$s ${beFor(s)} ${progressiveOf(pv)} $o.';
        case 31:
          sentence = '$s ${beFor(s)} ${progressiveOf(pv)} $place $t.';
        case 32:
          sentence = '$s ${beFor(s)} $adj.';
        case 33:
          sentence = 'my $p ${beFor('my $p')} $adj.';
        case 34:
          sentence = '$t $s will $v $o.';
        case 35:
          sentence = 'will $s $v $o $t?';
        case 36:
          sentence = 'what is your name?';
        case 37:
          sentence = 'my name is $name.';
        case 38:
          sentence = 'where is the $place?';
        case 39:
          sentence = 'what time is it?';
        case 40:
          sentence = 'how much is the $o?';
        case 41:
          sentence = 'who is $p?';
        case 42:
          sentence = 'please $v the $o.';
        case 43:
          sentence = 'please $v $o for me.';
        case 44:
          sentence = 'do not $v the $o.';
        case 45:
          sentence = 'can you $v the $o?';
        case 46:
          sentence = 'could you $v $o?';
        case 47:
          sentence = 'should I $v the $o?';
        case 48:
          sentence = 'may I $v?';
        case 49:
          sentence = 'I am looking for the $place.';
        case 50:
          sentence = 'I want to go to the $place.';
        case 51:
          sentence = '$s ${beFor(s)} at the $place.';
        case 52:
          sentence = 'do you have $o?';
        case 53:
          sentence = 'I need $o.';
        case 54:
          sentence = '$s ${beFor(s)} ${progressiveOf(routineVerb)} $t.';
        case 55:
          sentence = 'I $routineVerb $t.';
        case 56:
          sentence = 'did you $routineVerb $t?';
        case 57:
          sentence = 'I need to $routineVerb early.';
        case 58:
          sentence = 'my $bodyPart hurts.';
        case 59:
          sentence = 'my $bodyPart ${beFor('my $bodyPart')} $adj $t.';
        case 60:
          sentence = 'I have a $symptom.';
        case 61:
          sentence = '$s ${haveFor(s)} $symptom $t.';
        case 62:
          sentence = 'I need medicine for my $bodyPart.';
        case 63:
          sentence = 'please take me to the $place.';
        case 64:
          sentence = 'please bring $o to my $p.';
        case 65:
          sentence = 'I lost my $doc.';
        case 66:
          sentence = 'where is my $doc?';
        case 67:
          sentence = 'I need my $doc $t.';
        case 68:
          sentence = 'please sign the $doc.';
        case 69:
          sentence = 'please fill the $doc.';
        case 70:
          sentence = 'I want $meal $t.';
        case 71:
          sentence = 'what did you eat for $meal?';
        case 72:
          sentence = 'we ${pastOf('eat')} $meal at the $place.';
        case 73:
          sentence = 'I will take the $ride to the $place.';
        case 74:
          sentence = 'when does the $ride leave?';
        case 75:
          sentence = 'how much is the $ride?';
        case 76:
          sentence = 'the $ride is $adj $t.';
        case 77:
          sentence = 'please $action the $o.';
        case 78:
          sentence = '$s will $action the $o $t.';
        case 79:
          sentence = 'can you $action the $o for me?';
        case 80:
          sentence = 'the $o is $state.';
        case 81:
          sentence = 'my $doc is $state.';
        case 82:
          sentence = 'is the $ride $state?';
        case 83:
          sentence = '$s ${doFor(s)} not $v the $o $t.';
        case 84:
          sentence = 'please do not $v the $o.';
        case 85:
          sentence = 'where can I $v $o?';
        case 86:
          sentence = 'when will $s $v $o?';
        case 87:
          sentence = 'the $o costs $num dollars.';
        case 88:
          sentence = 'I paid $num dollars for the $o.';
        case 89:
          sentence = 'my $p is $num years old.';
        case 90:
          sentence = '$s $v the $o every day.';
        default:
          sentence = '$s $v $o.';
      }
      synthetic.add(sentence);
    }

    // Held-out structures never used by the training templates, so OOD exact
    // match measures composition rather than memorised sentence shapes.
    final oodSynthetic = <String>{};
    const oodTarget = 720;
    var oodGuard = 0;
    while (oodSynthetic.length < oodTarget &&
        oodGuard < oodTarget * 40) {
      oodGuard++;
      final s = pick(subjects);
      final p = pick(people);
      final v = pick(verbs);
      final o = pick(objects);
      final place = pick(places);
      final t = pick(times);
      final adj = pick(adjectives);
      final unit = pick(units);

      final String sentence;
      switch (rng.nextInt(14)) {
        case 0:
          sentence = '$s ${pastOf(v)} the $o because $s ${beFor(s)} $adj.';
        case 1:
          sentence = '$s $v $o and then $s $v $place $t.';
        case 2:
          sentence = 'if $s ${beFor(s)} $adj, $s can $v $o.';
        case 3:
          sentence = 'because $s ${beFor(s)} $adj, $s cannot $v $o.';
        case 4:
          sentence = '${s == 'I' ? 'my friend' : s} told me to $v the $o $t.';
        case 5:
          sentence = 'I think $s ${beFor(s)} $adj $t.';
        case 6:
          sentence = '$s ${pastOf(v)} $o before $s ${pastOf(v)} $place.';
        case 7:
          sentence = 'after $s ${pastOf(v)} $o, $s will $v $place.';
        case 8:
          sentence = '${s == 'I' ? 'my friend' : s} asked me to $v the $o $t.';
        case 9:
          sentence = 'there is $o at the $place $t.';
        case 10:
          sentence = 'my $p $v $o but my $p $v $o.';
        case 11:
          sentence = '$s ${doFor(s)} not $v $o because $s ${beFor(s)} $adj.';
        case 12:
          sentence = 'how many $unit ${doFor(s)} $s $v?';
        case 13:
          sentence = '$s ${beFor(s)} the $p who $v $o $t.';
        default:
          sentence = '$s $v $o.';
      }
      if (!synthetic.contains(sentence) && !english.contains(sentence)) {
        oodSynthetic.add(sentence);
      }
    }

    final conversationalSet = conversational.toSet();
    for (final sentence in {...english, ...conversational, ...synthetic}) {
      final source = fixtureEnglish.contains(sentence)
          ? 'fixture'
          : conversationalSet.contains(sentence)
              ? 'conversational'
              : 'synthetic';
      addPair(sentence, 'ENG', 'asl', source);
      addPair(sentence, 'HI', 'isl', source);
    }

    final oodPairs = <String, Map<String, String>>{};
    for (final sentence in oodSynthetic) {
      addPair(sentence, 'ENG', 'asl', 'ood', sink: oodPairs);
      addPair(sentence, 'HI', 'isl', 'ood', sink: oodPairs);
    }

    final rows = pairs.values.toList()..sort((a, b) {
        final bySystem = a['system']!.compareTo(b['system']!);
        return bySystem != 0 ? bySystem : a['x']!.compareTo(b['x']!);
      });
    final oodRows = oodPairs.values.toList()..sort((a, b) {
        final bySystem = a['system']!.compareTo(b['system']!);
        return bySystem != 0 ? bySystem : a['x']!.compareTo(b['x']!);
      });
    final captions = rows.map((r) => r['x']!).toSet().toList()
      ..shuffle(Random(20261019));
    // Prepared forms of curated phrases differ from their raw captions (e.g.
    // article dropping), so match on the prepared caption to keep them in train.
    final curatedPrepared = {
      for (final row in rows)
        if (row['source'] == 'conversational' ||
            row['source'] == 'isl_conversational')
          row['x']!,
    };
    final splitOfCaption = <String, int>{};
    for (var i = 0; i < captions.length; i++) {
      // Curated everyday phrases stay in train so greetings are never held out.
      splitOfCaption[captions[i]] =
          curatedPrepared.contains(captions[i]) ? -1 : i % 20;
    }

    final train = <Map<String, String>>[];
    final val = <Map<String, String>>[];
    final testSplit = <Map<String, String>>[];
    for (final row in rows) {
      final bucket = splitOfCaption[row['x']!]!;
      if (bucket == 0) {
        val.add(row);
      } else if (bucket == 1) {
        testSplit.add(row);
      } else {
        train.add(row);
      }
    }

    final dir = Directory(outDir)..createSync(recursive: true);
    Future<void> writeSplit(
      String name,
      List<Map<String, String>> split,
    ) async {
      final sink = File('${dir.path}/$name.jsonl').openWrite();
      for (final row in split) {
        sink.writeln(jsonEncode(row));
      }
      await sink.flush();
      await sink.close();
    }

    await writeSplit('train', train);
    await writeSplit('val', val);
    await writeSplit('test', testSplit);
    await writeSplit('ood', oodRows);

    final bySystem = <String, int>{};
    final bySource = <String, int>{};
    for (final row in rows) {
      bySystem[row['system']!] = (bySystem[row['system']!] ?? 0) + 1;
      bySource[row['source']!] = (bySource[row['source']!] ?? 0) + 1;
    }
    stdout.writeln('rows=${rows.length} train=${train.length} '
        'val=${val.length} test=${testSplit.length} ood=${oodRows.length}');
    stdout.writeln('systems=$bySystem sources=$bySource');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
