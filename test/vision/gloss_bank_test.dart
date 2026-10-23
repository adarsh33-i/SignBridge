/// The retrieval bank on its own, with hand-built vectors.
///
/// Real accuracy is a property of the trained model and is measured by
/// `training/video/verify_video_match.py` over thousands of held-out windows.
/// What this file pins is the mechanism the phone runs: best window per clip,
/// the margin the accept gate reads, and refusal to answer at all when that
/// margin is not there.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sign_bridge/services/vision/gloss_bank.dart';

const _dimension = 4;

/// int8 100 reads back as a cosine of 1.0, so a stored value of 100 along one
/// axis is that basis vector and a dot product against it is the component.
const _scale = 0.01;

/// Two clips, three windows. `hello` owns windows 0 and 1 and answers along
/// either axis, so a bank that scored each window against its own row instead of
/// collapsing to the best window per clip would pick the wrong direction here.
GlossBank _bank({required double acceptMargin, Uint16List? clipOfWindow}) {
  final vectors = Int8List.fromList([
    100, 0, 0, 0, // window 0, clip 0
    0, 100, 0, 0, // window 1, clip 0
    50, 50, 0, 0, // window 2, clip 1
  ]);
  final owner = clipOfWindow ?? Uint16List.fromList([0, 0, 1]);
  final manifest = {
    'embed_dim': _dimension,
    'bank': {
      'windows': 3,
      'int8_scale': _scale,
      'accept_margin': acceptMargin,
    },
    'clips': ['asl/hello.mp4', 'asl/thank_you.mp4'],
  };
  return GlossBank.fromBytes(
    vectors: ByteData.sublistView(vectors),
    clipIndex: ByteData.sublistView(owner),
    manifest: jsonDecode(jsonEncode(manifest)) as Map<String, dynamic>,
  );
}

void main() {
  // Straight at window 1, which belongs to clip 0 but is not its first window.
  final query = Float32List.fromList([0.0, 1.0, 0.0, 0.0]);

  test('a clip answers with its best window, not its first', () {
    final match = _bank(acceptMargin: 0.5).lookup(query);
    expect(match, isNotNull);
    expect(match!.clip, 'asl/hello.mp4');
    // 1.0 is window 1's score; window 0 of the same clip scores 0 against this
    // query, and the bank has to report the winner.
    expect(match.score, closeTo(1.0, 1e-9));
  });

  test('the margin is the gap over the runner-up clip', () {
    final match = _bank(acceptMargin: 0.5).lookup(query)!;
    expect(match.runnerUpClip, 'asl/thank_you.mp4');
    // hello scores 1.0, thank_you's one window scores 0.5.
    expect(match.margin, closeTo(0.5, 1e-9));
  });

  test('a query that sits between two clips is declined instead of guessed', () {
    // Equidistant from thank_you's window and both of hello's: at half the
    // diagonal all three read the same cosine, so the margin is exactly 0.
    final tied = Float32List.fromList([0.7, 0.7, 0.0, 0.0]);
    expect(_bank(acceptMargin: 0.01).lookup(tied)!.accepted, isFalse);
    expect(_bank(acceptMargin: 0.0).lookup(tied)!.accepted, isTrue);
    // The same gate that declines the tie accepts the clear answer above.
    expect(_bank(acceptMargin: 0.01).lookup(query)!.accepted, isTrue);
  });

  test('the clip key becomes the gloss id the lexicon and avatar use', () {
    expect(_bank(acceptMargin: 0.5).lookup(query)!.gloss, 'hello');
  });

  test('an embedding of the wrong width is refused rather than misread', () {
    final bank = _bank(acceptMargin: 0.5);
    expect(() => bank.lookup(Float32List(3)), throwsArgumentError);
  });

  test('a bank whose bytes disagree with the manifest is refused', () {
    final manifest = jsonDecode(jsonEncode({
      'embed_dim': _dimension,
      'bank': {'windows': 9, 'int8_scale': _scale, 'accept_margin': 0.01},
      'clips': ['asl/hello.mp4'],
    })) as Map<String, dynamic>;
    expect(
      () => GlossBank.fromBytes(
        vectors: ByteData.sublistView(Int8List(12)),
        clipIndex: ByteData.sublistView(Uint16List(9)),
        manifest: manifest,
      ),
      throwsFormatException,
    );
  });

  test('a window that points past the end of the clip list is refused', () {
    expect(
      () => _bank(acceptMargin: 0.01, clipOfWindow: Uint16List.fromList([0, 0, 2])),
      throwsFormatException,
    );
  });
}
