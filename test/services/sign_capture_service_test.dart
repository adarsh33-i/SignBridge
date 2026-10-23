import 'package:flutter_test/flutter_test.dart';
import 'package:sign_bridge/services/translate/local_sign_capture_service.dart';
import 'package:sign_bridge/services/translate/sign_capture_service.dart';
import 'package:sign_bridge/services/vision/gesture_classifier.dart';
import 'package:sign_bridge/services/vision/sign_gesture_session.dart';

import '../vision/synthetic_hand_frames.dart';

/// A hand waved at head height: the recognizer's HELLO.
SignGestureSession _helloSession() => syntheticSession([
  for (var i = 0; i < 24; i++)
    (
      centerX: 0.5 + 0.18 * (i % 8 < 4 ? (i % 8) / 2 - 1 : 1 - (i % 8 - 4) / 2),
      centerY: 0.2,
      open: true,
    ),
]);

void main() {
  group('answering from what the camera saw', () {
    test('a waved open hand at head height comes back as HELLO', () async {
      final service = LocalSignCaptureService();

      final result = await service.analyzeRecording(
        languageCode: 'ENG',
        recordingDuration: const Duration(milliseconds: 2400),
        liveSession: _helloSession(),
      );

      expect(result.glossSequence, ['HELLO']);
      expect(result.text, 'Hello');
    });

    test(
      'the answer is timed from the clip, not from a fixed sample',
      () async {
        final service = LocalSignCaptureService();

        final result = await service.analyzeRecording(
          languageCode: 'ENG',
          recordingDuration: const Duration(seconds: 3),
          liveSession: _helloSession(),
        );

        expect(result.duration, const Duration(seconds: 3));
      },
    );

    test('the result says which recognizer answered', () async {
      final service = LocalSignCaptureService();

      final result = await service.analyzeRecording(
        languageCode: 'ENG',
        liveSession: _helloSession(),
      );

      expect(result.modelUsed, isNotEmpty);
    });

    test('no clip is ever answered with the old sample sentence', () async {
      final service = LocalSignCaptureService();

      Future<String?> analyze(SignGestureSession? session) async {
        try {
          return (await service.analyzeRecording(
            languageCode: 'ENG',
            liveSession: session,
          )).text;
        } on Object {
          return null;
        }
      }

      expect(await analyze(_helloSession()), isNot(contains('Alex')));
      expect(await analyze(null), isNull);
      expect(await analyze(SignGestureSession()), isNull);
    });
  });

  group('refusing to invent an answer', () {
    test('a recording with no frames at all is not guessed at', () async {
      final service = LocalSignCaptureService();

      await expectLater(
        service.analyzeRecording(languageCode: 'ENG'),
        throwsA(
          isA<SignNotRecognizedException>().having(
            (e) => e.outcome,
            'outcome',
            GestureOutcome.nothingSeen,
          ),
        ),
      );

      await expectLater(
        service.analyzeRecording(
          languageCode: 'ENG',
          liveSession: SignGestureSession(),
        ),
        throwsA(
          isA<SignNotRecognizedException>().having(
            (e) => e.outcome,
            'outcome',
            GestureOutcome.nothingSeen,
          ),
        ),
      );
    });

    test('a hand that stayed still is reported as still, not as a sign', () {
      final service = LocalSignCaptureService();
      final session = syntheticSession([
        for (var i = 0; i < 20; i++) (centerX: 0.5, centerY: 0.5, open: false),
      ]);

      expect(
        service.analyzeRecording(languageCode: 'ENG', liveSession: session),
        throwsA(
          isA<SignNotRecognizedException>().having(
            (error) => error.outcome,
            'outcome',
            GestureOutcome.heldStill,
          ),
        ),
      );
    });

    test('nothing in frame is reported as nothing seen', () {
      final service = LocalSignCaptureService();
      final session = syntheticSession([
        for (var i = 0; i < 20; i++) (centerX: 5, centerY: 5, open: false),
      ]);

      expect(
        service.analyzeRecording(languageCode: 'ENG', liveSession: session),
        throwsA(
          isA<SignNotRecognizedException>().having(
            (error) => error.outcome,
            'outcome',
            GestureOutcome.nothingSeen,
          ),
        ),
      );
    });

    test('a failed recognition carries what the rules measured', () {
      final session = syntheticSession([
        for (var i = 0; i < 20; i++) (centerX: 0.5, centerY: 0.5, open: false),
      ]);

      expect(
        LocalSignCaptureService().analyzeRecording(
          languageCode: 'ENG',
          liveSession: session,
        ),
        throwsA(
          isA<SignNotRecognizedException>().having(
            (error) => error.detail,
            'detail',
            contains('runs='),
          ),
        ),
      );
    });
  });

  group('the seam offers no way to answer without looking', () {
    test('a bare session has seen nothing and sampled nothing', () {
      final session = SignGestureSession();

      expect(session.sawFrames, isFalse);
      expect(session.track.visibleFrameCount, 0);
      expect(session.verdict().outcome, GestureOutcome.nothingSeen);
    });

    test('every frame it is given counts as seen', () {
      final session = syntheticSession([
        for (var i = 0; i < 6; i++) (centerX: 0.5, centerY: 0.5, open: true),
      ]);

      expect(session.sawFrames, isTrue);
      expect(session.sampledCount, 6);
      expect(session.unreadableCount, 0);
    });
  });
}
