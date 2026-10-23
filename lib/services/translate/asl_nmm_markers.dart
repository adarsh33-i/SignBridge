import 'sign_language_system.dart';
import 'sign_token.dart';

/// Non-manual markers (NMM) per ASL Gloss Engine Specification Module 6.
abstract final class AslNmmMarkers {
  static const whQ = 'nmm:wh-q';
  static const ynQ = 'nmm:y-n-q';
  static const rhQ = 'nmm:rh-q';
  static const headshake = 'nmm:headshake';
  static const mm = 'nmm:mm';
  static const cha = 'nmm:cha';
  static const th = 'nmm:th';
  static const cs = 'nmm:cs';
  static const roleShift = 'nmm:role-shift';

  static const allMarkers = {
    whQ,
    ynQ,
    rhQ,
    headshake,
    mm,
    cha,
    th,
    cs,
    roleShift,
  };

  static const _glossLabels = {
    whQ: '[wh-q]',
    ynQ: '[y/n-q]',
    rhQ: '[rh-q]',
    headshake: '[headshake]',
    mm: '[mm]',
    cha: '[cha]',
    th: '[th]',
    cs: '[cs]',
    roleShift: '[role-shift]',
  };

  static bool isMarker(String word) => word.startsWith('nmm:');

  /// Ids the avatar library keys its face animations on. This mapping is the
  /// whole contract: `SignLibrary` switches on these exact strings, and
  /// deriving them from the marker spelling instead (e.g. by replacing the
  /// colon) silently ships question markers the library never matches, so
  /// production fingerspelled "[WH-Q]" instead of raising an eyebrow.
  static const _ids = {
    whQ: 'nmm_whQ',
    ynQ: 'nmm_ynQ',
    rhQ: 'nmm_rhQ',
    headshake: 'nmm_headshake',
    mm: 'nmm_mm',
    cha: 'nmm_cha',
    th: 'nmm_th',
    cs: 'nmm_cs',
    roleShift: 'nmm_roleShift',
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
