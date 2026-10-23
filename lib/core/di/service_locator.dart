import '../../services/home/home_service.dart';
import '../../services/home/local_home_service.dart';
import '../../services/gloss/gloss_service.dart';
import '../../services/gloss/local_gloss_service.dart';
import '../../services/phrases/local_phrase_speech_service.dart';
import '../../services/phrases/local_phrases_service.dart';
import '../../services/phrases/phrases_service.dart';
import '../../services/settings/settings_service.dart';
import '../../services/settings/local_settings_service.dart';
import '../../services/sos/sos_service.dart';
import '../../services/sos/local_sos_service.dart';
import '../../services/splash/splash_service.dart';
import '../../services/splash/local_splash_service.dart';
import '../../services/translate/local_sign_capture_service.dart';
import '../../services/translate/local_translate_service.dart';
import '../../services/translate/sign_capture_service.dart';
import '../../services/translate/translate_service.dart';

/// Central registry for independent microservice adapters.
final class ServiceLocator {
  ServiceLocator._({
    required this.splash,
    required this.home,
    required this.translate,
    required this.signCapture,
    required this.gloss,
    required this.phrases,
    required this.phraseSpeech,
    required this.sos,
    required this.settings,
  });

  static ServiceLocator? _instance;
  static ServiceLocator get instance => _instance!;

  final SplashService splash;
  final HomeService home;
  final TranslateService translate;
  final SignCaptureService signCapture;
  final GlossService gloss;
  final PhrasesService phrases;
  final PhraseSpeechService phraseSpeech;
  final SosService sos;
  final SettingsService settings;

  static void bootstrap({
    TranslateService? translate,
    SignCaptureService? signCapture,
    GlossService? gloss,
    PhraseSpeechService? phraseSpeech,
    SosService? sos,
  }) {
    final translateService = translate ?? LocalTranslateService();
    final speechService =
        phraseSpeech ??
        LocalPhraseSpeechService(
          releaseAudioSession: translateService.cancelListening,
        );
    _instance = ServiceLocator._(
      splash: LocalSplashService(),
      home: LocalHomeService(),
      translate: translateService,
      signCapture: signCapture ?? LocalSignCaptureService(),
      gloss: gloss ?? LocalGlossService(),
      phrases: LocalPhrasesService(),
      phraseSpeech: speechService,
      sos: sos ?? LocalSosService(phraseSpeech: speechService),
      settings: LocalSettingsService(),
    );
  }

}
