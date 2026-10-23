import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:sign_bridge/services/avatar/rig/avatar_painter.dart';
import 'package:sign_bridge/services/avatar/rig/fingerspell_shapes.dart';
import 'package:sign_bridge/services/avatar/rig/sign_pose.dart';

/// The hand is painted as one merged silhouette, so the only thing that tells
/// the eye there are four fingers is a thread-thin line inked where two of them
/// cross. Those lines are computed from the drawn digit paths, not from the
/// authored curls, and this pins both halves of that decision: an open hand gets
/// one thread per finger pair, a closed hand gets none, and nothing a hand does
/// can put a line across the palm. The thumb is the fifth digit and is re-inked
/// over the union so it stays readable when it tucks across the palm.
HandShape _h(
  List<double> curls, {
  double spread = 0,
  double thumb = 0,
}) =>
    HandShape(
      index: curls[0],
      middle: curls[1],
      ring: curls[2],
      pinky: curls[3],
      thumb: thumb,
      spread: spread,
    );

/// The palm's top edge in hand-local space: `AvatarPainter._unitPalm * 0.86`.
/// Local y runs from the wrist outward, so anything at or below this line is
/// palm, and a thread there reads as a bar drawn across the hand.
const _knuckleLine = 0.067;

List<ui.Path> _seams(HandShape hand) => AvatarPainter.fingerSeams(hand, 1.0);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('what the hand is allowed to show', () {
    test('an open hand separates all four fingers', () {
      // Three threads, not two: the ring/pinky pair contacts for the shortest
      // run of any open pair and was the one the old length cut kept dropping.
      expect(_seams(HandShape.flat), hasLength(3));
      expect(_seams(HandShape.relax), hasLength(3));
      expect(_seams(_h([0.5, 0.5, 0.5, 0.5], thumb: 0.45)), hasLength(3));
      expect(_seams(_h([0.05, 0.05, 0.05, 0.05], thumb: 0.2)), hasLength(3));
    });

    test('a closed hand shows none', () {
      expect(_seams(HandShape.fist), isEmpty);
      expect(_seams(HandShape.point), isEmpty);
      expect(_seams(HandShape.pinch), isEmpty);
      expect(_seams(_h([0.45, 1.0, 1.0, 1.0])), isEmpty);
      // A hand that folds to 0.95 is the tightest closed one measured, so if
      // any closed pair comes back it will come back here first.
      expect(_seams(_h([0.95, 0.95, 0.95, 0.95], thumb: 0.2)), isEmpty);
    });

    test('a half-closed hand keeps the threads its fold leaves', () {
      // `buy` peaks at [0.31, 0.68, 0.68, 0.68]. Before the fold was capped,
      // the three 0.68 fingers hairpinned their tips back under their own
      // knuckles and no pair of them shared ink, so this hand genuinely earned
      // nothing. Now they retract instead, and all three pairs clear the cut —
      // index/middle 0.052, middle/ring 0.060, ring/pinky 0.049 — so the hand
      // reads as four bent digits.
      expect(_seams(_h([0.31, 0.68, 0.68, 0.68], thumb: 0.5)), hasLength(3));
      expect(_seams(HandShape.bent), hasLength(3));
      expect(_seams(HandShape.claw), hasLength(3));
    });

    test('the cut sits in a band nothing enters', () {
      // The gate is one length, so the only honest test of it is the shape of
      // the population either side. Walking a hand whose four fingers curl
      // together, every pair of a hand open to curl 0.70 contacts for 0.0485
      // or more and every pair of a hand closed to 0.95 or more for at most
      // 0.0342. The cut sits in that empty band; `fingerContact` reports the
      // ungated lengths precisely so this can be measured rather than asserted
      // blind.
      const cut = 0.0170 * 2.4;
      var openWorst = double.infinity, closedBest = 0.0;
      for (var i = 0; i <= 14; i++) {
        final c = i / 20; // curl 0.00 .. 0.70
        for (final l in AvatarPainter.fingerContact(_h([c, c, c, c]), 1.0)) {
          openWorst = l < openWorst ? l : openWorst;
        }
      }
      for (final c in [0.95, 1.0]) {
        for (final l in AvatarPainter.fingerContact(_h([c, c, c, c]), 1.0)) {
          closedBest = l > closedBest ? l : closedBest;
        }
      }
      expect(openWorst, greaterThan(cut * 1.15),
          reason: 'the loosest open pair is too close to the cut');
      expect(closedBest, lessThan(cut * 0.9),
          reason: 'the tightest closed pair is too close to the cut');
    });

    test('a fanned letter is separated by daylight, not by ink', () {
      for (final letter in ['k', 'v', 'w']) {
        expect(
          _seams(FingerspellShapes.letters[letter]!),
          isEmpty,
          reason: 'the $letter hand pushes its digits past contact on purpose',
        );
      }
    });

    test('a mixed hand keeps the threads its fingers actually earn', () {
      // Each of these has at least one upright finger beside a folded one, so
      // no pair of them agrees on curl. The old comparison of authored curls
      // could only guess at these; the drawn paths settle it.
      expect(_seams(_h([0.00, 0.00, 0.45, 0.45], thumb: 0.4)), hasLength(3));
      expect(_seams(_h([0.00, 0.54, 0.54, 0.54], thumb: 0.6)), hasLength(3));
      expect(_seams(_h([0.50, 0.50, 0.50, 0.00], thumb: 0.5)), hasLength(2));
      expect(_seams(_h([0.23, 0.60, 0.60, 0.60], thumb: 0.5)), hasLength(3));
      expect(_seams(_h([0.00, 0.00, 1.00, 1.00], thumb: 0.5)), hasLength(1));
      expect(_seams(_h([0.00, 1.00, 1.00, 0.00], thumb: 0.5)), isEmpty);
    });
  });

  group('what a thread can never look like', () {
    test('no thread runs onto the palm, for any hand', () {
      // A curled finger folds back over its own palm, so the midline between
      // its tip and an upright neighbour's tip can run down into the palm and
      // stay inside both digits the whole way — which paints a bar across the
      // middle of the hand. Nothing in the painter names that line; the walk
      // only stops where the two digits stop overlapping, so this pins the
      // consequence instead. It walks every four-curl combination rather than
      // the handful the library happens to author, because the authored ones
      // have never been the interesting cases.
      const steps = [0.0, 0.25, 0.5, 0.75, 1.0];
      var checked = 0;
      for (final a in steps) {
        for (final b in steps) {
          for (final c in steps) {
            for (final d in steps) {
              for (final seam in _seams(_h([a, b, c, d], thumb: 0.5))) {
                checked++;
                expect(
                  seam.getBounds().top,
                  greaterThanOrEqualTo(_knuckleLine),
                  reason: 'a thread for curls [$a, $b, $c, $d] sits on the palm',
                );
              }
            }
          }
        }
      }
      expect(checked, greaterThan(0), reason: 'the sweep found no seam at all');
    });

    test('the left hand mirrors the right', () {
      for (final hand in [
        HandShape.flat,
        HandShape.fist,
        _h([0.00, 0.00, 0.45, 0.45], thumb: 0.4),
        _h([0.5, 0.5, 0.5, 0.0], thumb: 0.5),
      ]) {
        expect(
          AvatarPainter.fingerSeams(hand, -1.0),
          hasLength(_seams(hand).length),
        );
      }
    });

    test('a thread is a thread, not a slab', () {
      // Each seam runs along one boundary between two digits, so it has to be
      // long and thin: a wide bound means the walk has left the seam and cut
      // across a finger.
      for (final seam in _seams(HandShape.flat)) {
        final bound = seam.getBounds();
        expect(bound.shortestSide, lessThan(0.010));
        expect(bound.longestSide, greaterThan(0.014));
      }
    });
  });

  group('a shape that closes on the thumb has to reach it', () {
    // The seams above only compare finger *neighbours*, so nothing in them can
    // see the thumb. Pinch, and the O, F and Q letters, are all defined by the
    // index tip meeting the thumb pad — and every one of them shipped as an open
    // C, because a curl that reads as "half closed" in the data is nowhere near
    // the thumb in the drawing. Two centre-lines touch when their distance falls
    // under the sum of their half-widths: the index draws at 0.0170/2 * 0.98 and
    // the thumb tip at 0.0086, giving 0.0169.
    //
    // Measured across the shapes that matter, the two populations are clean: the
    // closed ones (pinch 0.0098, o 0.0120, f 0.0126, q 0.0116, fist 0.0051) all
    // sit under 0.013, and the ones that must keep a hole (bent 0.0250,
    // claw 0.0331, c 0.0415, flat 0.1181) start at 0.025. The two cuts below
    // sit either side of that empty band, so a shape can only cross by genuinely
    // changing, not by nudging a curl.
    const closing = 0.0130;
    const staysOpen = 0.0220;

    double gap(HandShape hand) {
      final bones = AvatarPainter.digitBones(hand, 1.0);
      return (bones[0][2] - bones[4][2]).distance;
    }

    test('the closed shapes close', () {
      for (final entry in {
        'pinch': HandShape.pinch,
        'o': HandShape.o,
        'f': FingerspellShapes.letters['f']!,
        'q': FingerspellShapes.letters['q']!,
      }.entries) {
        expect(gap(entry.value), lessThan(closing),
            reason: '${entry.key} draws as an open C, not a closed hand');
      }
    });

    test('the open shapes stay open', () {
      // The other half of the pin: C, claw and bent are all *meant* to keep a
      // hole, and a curl bump wide enough to close pinch would close these too.
      for (final entry in {
        'c': FingerspellShapes.letters['c']!,
        'claw': HandShape.claw,
        'bent': HandShape.bent,
      }.entries) {
        expect(gap(entry.value), greaterThan(staysOpen),
            reason: '${entry.key} has lost the opening that names it');
      }
    });

    test('closing the pinch costs it no threads', () {
      // The index and the three fingers behind it are all folded, so nothing
      // pair-wise is left to draw. O curls all four together; the two inner
      // pairs still clear the cut, so it is asserted as two.
      expect(_seams(HandShape.pinch), isEmpty);
      expect(_seams(HandShape.o), hasLength(2));
      // F stands three fingers up beside a folded index, so those three still
      // owe each other their edges.
      expect(_seams(FingerspellShapes.letters['f']!), hasLength(2));
    });
  });
}
