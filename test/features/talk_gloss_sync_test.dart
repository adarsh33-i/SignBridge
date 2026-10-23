import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sign_bridge/features/home/presentation/widgets/sign_avatar_view.dart';
import 'package:sign_bridge/features/home/presentation/widgets/talk_session_content.dart';
import 'package:sign_bridge/services/home/home_ui_copy.dart';
import 'package:sign_bridge/services/translate/sign_language_system.dart';
import 'package:sign_bridge/services/translate/sign_token.dart';
import 'package:sign_bridge/services/translate/talk_listen_result.dart';

/// The chip and the hands are separate widgets that have to agree, and the
/// agreement is the feature: the word on screen is the word being signed at
/// that moment, not the whole caption.
void main() {
  final uiCopy = homeUiCopyFor('ENG');
  const hello = SignToken(
    id: 'hello',
    gloss: 'HELLO',
    system: SignLanguageSystem.asl,
  );
  const rain = SignToken(
    id: 'rain',
    gloss: 'RAIN',
    system: SignLanguageSystem.asl,
  );

  TalkListenResult caption() => TalkListenResult(
    transcript: 'Hello, rain',
    fullTranscript: 'Hello, rain.',
    signingCaption: 'Hello, rain.',
    signingWord: 'HELLO RAIN',
    signTokenId: 'hello',
    signSystem: SignLanguageSystem.asl,
    signSequence: const [hello, rain],
    heardDuration: '0:02',
  );

  Future<void> mountHeard(WidgetTester tester, {String? activeGlossWord}) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 420,
                height: 720,
                child: TalkHeardContent(
                  uiCopy: uiCopy,
                  result: caption(),
                  activeGlossWord: activeGlossWord,
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('the chip names the sign in progress, not the whole gloss', (
    tester,
  ) async {
    await mountHeard(tester, activeGlossWord: 'RAIN');

    expect(find.textContaining('RAIN ·'), findsOneWidget);
    expect(find.textContaining('HELLO RAIN'), findsNothing);
  });

  testWidgets('the chip falls back to the gloss string at rest', (
    tester,
  ) async {
    await mountHeard(tester);

    expect(find.textContaining('HELLO RAIN'), findsOneWidget);
  });

  testWidgets('SignAvatarView passes the gloss callback down to the rig', (
    tester,
  ) async {
    final reported = <String?>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: 320,
              child: SignAvatarView(
                signTokenId: 'hello',
                signSystem: SignLanguageSystem.asl,
                fallbackAsset: 'assets/home/talk_flow/illu_signing.png',
                signingWord: 'HELLO',
                signSequence: const [hello, rain],
                onGlossChanged: reported.add,
              ),
            ),
          ),
        ),
      ),
    );

    // Small steps: one large pump fires the ticker once and the run would
    // finish in a single reported frame.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(reported.first, 'HELLO');
    expect(reported, contains('RAIN'));
  });
}
