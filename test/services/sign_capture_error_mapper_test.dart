import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sign_bridge/services/home/home_ui_copy.dart';
import 'package:sign_bridge/services/translate/sign_capture_error_mapper.dart';
import 'package:sign_bridge/services/translate/sign_capture_service.dart';
import 'package:sign_bridge/services/vision/gesture_classifier.dart';

void main() {
  const copy = HomeUiCopy(
    emptyStateMessage: '',
    tapToListen: '',
    tapToSign: '',
    tapToTranslate: '',
    tapToRecordSign: '',
    tapToStop: '',
    sendCaptionLabel: '',
    flipCameraLabel: '',
    clearCaptionLabel: '',
    recordingSignsLabel: '',
    analyzingSignsLabel: '',
    spokenLabel: '',
    signsCapturedLabel: '',
    replayLabel: '',
    cameraPermissionRequiredLabel: '',
    signCaptureFailedLabel: 'generic-failed',
    signNoHandLabel: 'no-hand',
    signHandWasStillLabel: 'hand-still',
    signCouldNotTellLabel: 'could-not-tell',
    listeningLabel: '',
    signingPrefix: '',
    signingListeningWord: '',
    heardLabel: '',
    clearHistoryLabel: '',
    noSpeechDetectedLabel: '',
    micPermissionRequiredLabel: '',
    listenStartFailedLabel: '',
    talkTabLabel: '',
    phrasesTabLabel: '',
    settingsTitle: '',
    emergencySection: '',
    callEmergency: '',
    sos: '',
    callEmergencyConfirmTitle: '',
    callEmergencyConfirmBody: '',
    sosConfirmTitle: '',
    sosConfirmBody: '',
    emergencyCancelLabel: '',
    emergencyConfirmLabel: '',
    emergencyCallFailedLabel: '',
    sosCountdownTitle: '',
    sosCountdownBody: '',
    sosCountdownCancelLabel: '',
    emergencyPhonePermissionRequiredLabel: '',
    signRecordingTooShortLabel: '',
    signRecordingTooLargeLabel: 'too-large',
    aboutSection: '',
    appLabel: '',
    versionLabel: '',
    footerCopyright: '',
    languageChangeConfirmTitle: '',
    languageChangeConfirmLabel: '',
    languageChangeConfirmListeningBody: '',
    languageChangeConfirmRecordingBody: '',
    languageChangeBlockedAnalyzingLabel: '',
    languageChangeBlockedEmergencyLabel: '',
    languageChangedSnackbar: '',
  );
  group('what the recognizer could not do', () {
    test('no hand in the frame is told as no hand', () {
      expect(
        SignCaptureErrorMapper.userMessage(
          const SignNotRecognizedException(GestureOutcome.nothingSeen),
          copy,
        ),
        'no-hand',
      );
    });

    test('a hand that stayed still is told as still', () {
      expect(
        SignCaptureErrorMapper.userMessage(
          const SignNotRecognizedException(GestureOutcome.heldStill),
          copy,
        ),
        'hand-still',
      );
    });

    test('motion the rules cannot separate is told as unclear', () {
      expect(
        SignCaptureErrorMapper.userMessage(
          const SignNotRecognizedException(GestureOutcome.unclear),
          copy,
        ),
        'could-not-tell',
      );
    });

    test('a clip too short to read is not reported as a sign', () {
      expect(
        SignCaptureErrorMapper.userMessage(
          const SignNotRecognizedException(GestureOutcome.tooShort),
          copy,
        ),
        'could-not-tell',
      );
    });

    test('a clip that watched no frames is reported as no hand', () {
      expect(
        SignCaptureErrorMapper.userMessage(
          const SignNotRecognizedException(GestureOutcome.nothingSeen),
          copy,
        ),
        'no-hand',
      );
    });
  });

  group('the snackbar stays up long enough to read', () {
    test('every recognition failure gets the longer window', () {
      for (final error in <Object>[
        const SignNotRecognizedException(GestureOutcome.nothingSeen),
        const SignNotRecognizedException(GestureOutcome.heldStill),
        const SignNotRecognizedException(GestureOutcome.unclear),
      ]) {
        expect(
          SignCaptureErrorMapper.snackbarDuration(error),
          const Duration(seconds: 6),
          reason: '$error',
        );
      }
    });

    test('an unrelated failure is brief', () {
      expect(
        SignCaptureErrorMapper.snackbarDuration(
          const SocketException('camera stream closed'),
        ),
        const Duration(seconds: 4),
      );
    });
  });

  group('no answer is read out of response text', () {
    test('an old worker rate limit is only a generic failure', () {
      // The clip used to be uploaded to a hosted worker, and its HTTP status
      // decided this message. Nothing uploads now, so nothing may parse.
      expect(
        SignCaptureErrorMapper.userMessage(
          const HttpException('Sign worker 429: rate limit exceeded'),
          copy,
        ),
        'generic-failed',
      );
    });

    test('an old Gemini model error is only a generic failure', () {
      expect(
        SignCaptureErrorMapper.userMessage(
          const HttpException(
            'Sign worker 502: {"detail":"models/gemini-2 not found"}',
          ),
          copy,
        ),
        'generic-failed',
      );
    });

    test('a timeout is only a generic failure', () {
      expect(
        SignCaptureErrorMapper.userMessage(TimeoutException('waited'), copy),
        'generic-failed',
      );
    });
  });
}
