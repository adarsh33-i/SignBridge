import 'sign_language_system.dart';
import 'sign_token.dart';

/// Non-manual markers for ISL (aligned with ASL Module 6 set).
abstract final class IslNmmMarkers {
  static const whQ = 'nmm:wh-q';
  static const ynQ = 'nmm:y-n-q';
  static const rhQ = 'nmm:rh-q';
  static const headshake = 'nmm:headshake';
  static const mm = 'nmm:mm';
  static const cha = 'nmm:cha';
  static const th = 'nmm:th';
  static const cs = 'nmm:cs';

  static const _glossLabels = {
    whQ: '[wh-q]',
    ynQ: '[y/n-q]',
    rhQ: '[rh-q]',
    headshake: '[headshake]',
    mm: '[mm]',
    cha: '[cha]',
    th: '[th]',
    cs: '[cs]',
  };

  static bool isMarker(String word) => word.startsWith('nmm:');

  /// Same id contract as `AslNmmMarkers._ids` — the avatar library switches
  /// on these exact strings. See that class for why this is a fixed map.
  static const _ids = {
    whQ: 'nmm_whQ',
    ynQ: 'nmm_ynQ',
    rhQ: 'nmm_rhQ',
    headshake: 'nmm_headshake',
    mm: 'nmm_mm',
    cha: 'nmm_cha',
    th: 'nmm_th',
    cs: 'nmm_cs',
  };

  static SignToken token(String markerId, SignLanguageSystem system) {
    final gloss =
        _glossLabels[markerId] ?? '[${markerId.replaceFirst('nmm:', '')}]';
    return SignToken(
      id: _ids[markerId] ?? markerId.replaceAll(':', '_'),
      gloss: gloss,
      system: system,
    );
  }
}
