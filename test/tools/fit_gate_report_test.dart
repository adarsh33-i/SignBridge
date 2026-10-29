// ignore_for_file: avoid_print — this file's only output is the report itself.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'landmark_fitter.dart';

/// Reports what the fitter makes of real signer clips, and gates each one.
///
/// This is the pilot instrument, not an assertion: it reads every track in a
/// directory, fits it, and prints the numbers behind the decision — how many
/// frames each slot was seen for, which slots were not believed as hands, what
/// each keyframe reprojects, and which gate a rejected clip failed. A fitted sign
/// either passes `FitVerdict` or it does not, and a run of this report is what
/// says whether a threshold is set in the right place rather than where the last
/// clip happened to land.
///
/// Run explicitly against exported tracks:
///
///   training/video/.venv/bin/python training/video/export_fit_tracks.py \
///       --keys asl/hello asl/mother --out training/video/data/fit
///   FIT_REPORT_DIR=training/video/data/fit \
///       flutter test test/tools/fit_gate_report_test.dart
///
/// The top-25 gap-word pilot lives in `training/video/data/pilot` and is what the
/// gate numbers in `docs/sign_avatar_rig.md` were read from. Both directories are
/// gitignored, so nothing here may be asserted against — the report is a tool for
/// looking at footage, and `test/avatar/landmark_fit_test.dart` is what pins the
/// fitter's behaviour.
///
/// Normal runs skip it, because it reads the corpus rather than asserting anything.
void main() {
  final dir = Platform.environment['FIT_REPORT_DIR'];
  if (dir == null || dir.isEmpty) {
    test('fit gate report needs a track directory', () {
      expect(Platform.environment['FIT_REPORT_DIR'], anyOf(isNull, isEmpty));
    });
    return;
  }

  test('report fitted clips', () {
    final files =
        Directory(dir)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (files.isEmpty) {
      fail('no tracks in $dir — export them with export_fit_tracks.py first');
    }
    var accepted = 0;
    final rejectTally = <String, int>{};
    for (final file in files) {
      final track = LandmarkTrack.load(file.path);
      final fit = fitTrack(track);
      if (fit == null) {
        print(
          '${track.key}: NO FIT — no slot reached $minDriverFrames frames '
          '(${[for (final h in track.hands) "${h.slot}:${h.frames.length}"].join(",")})',
        );
        _tally(rejectTally, 'no fit');
        continue;
      }
      final verdict = fit.verdict;
      if (verdict.accepted) accepted++;
      for (final gate in verdict.gates) {
        _tally(rejectTally, gate);
      }
      print(
        '${track.key} k=${fit.keys.length} '
        'accepted=${verdict.accepted} '
        'place=${fit.placementError.toStringAsFixed(4)} '
        'shape=${fit.shapeError.toStringAsFixed(3)} '
        'pip=${fit.pipError.toStringAsFixed(1)} '
        'aim=${fit.aimError.toStringAsFixed(1)} '
        'slots=${[for (final h in track.hands) "${h.slot}:${h.frames.length}"].join(",")}',
      );
      for (final key in fit.keys) {
        print(
          '   ${(key.startMs / 1000).toStringAsFixed(1)}s hold=${(key.holdMs / 1000).toStringAsFixed(1)}s '
          '${key.frames}f place=${key.placementError.toStringAsFixed(4)} '
          'shape=${key.shapeError.toStringAsFixed(3)} pip=${key.pipError.toStringAsFixed(1)} '
          'aim=${key.aimError.toStringAsFixed(1)} '
          'clipPip=${key.observedPip.toStringAsFixed(1)} '
          'aspect=${key.aspect.toStringAsFixed(2)}',
        );
      }
      for (final line in [...verdict.reasons.map((r) => 'REJECT $r'), ...verdict.notes]) {
        print('   $line');
      }
    }
    print(
      '\n$accepted/${files.length} clips accepted by the gate'
      '${rejectTally.isEmpty ? "" : ", reasons: ${_sorted(rejectTally)}"}'
      '\nrig floor: a drawable palm spans ${rigMinAspect.toStringAsFixed(2)} '
      'knuckle-to-palm and the tightest hand folds to '
      '${minDrawablePip.toStringAsFixed(1)} degrees mean PIP; gates are '
      'placement $maxPlacementError rig units, '
      'fold $maxPipError degrees, aim $maxAimError degrees, '
      '$minKeyFrames frames per key. Shape is reported, not gated: above '
      '$shapeNoteFloor palms on a clip that passes the rest it is the rig\'s finger '
      'lengths against the signer\'s.\n',
    );
  });
}

void _tally(Map<String, int> tally, String key) =>
    tally[key] = (tally[key] ?? 0) + 1;

String _sorted(Map<String, int> tally) {
  final entries = tally.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return entries.map((e) => '${e.key} x${e.value}').join(", ");
}
