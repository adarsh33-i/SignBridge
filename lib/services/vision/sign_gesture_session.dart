import 'package:camera/camera.dart';

import 'camera_frame_reader.dart';
import 'gesture_classifier.dart';
import 'gesture_track.dart';
import 'hand_frame.dart';

/// Collects hand frames while a sign clip is being recorded, so the finished
/// clip can be read from motion it actually saw.
///
/// Recognition cannot happen after the fact from an MP4 — nothing in Dart
/// decodes video frames — so the frames are watched live during recording and
/// reduced to one [HandFrame] each.
final class SignGestureSession {
  SignGestureSession({this.maxFrames = 400});

  /// Frames kept per clip. At the sample rate the camera delivers, this covers
  /// well past the 30 second clip limit.
  final int maxFrames;

  final List<HandFrame> _frames = [];

  /// Frames offered to this session, reduced to a hand or not. The recorder
  /// samples the camera stream ten times a second, so this is a count of
  /// samples, not of camera frames.
  int receivedCount = 0;

  /// Samples that arrived but could not be read, or arrived past [maxFrames].
  int unreadableCount = 0;

  bool get sawFrames => receivedCount > 0;

  int get sampledCount => _frames.length;

  GestureTrack get track => GestureTrack(frames: List.unmodifiable(_frames));

  /// Forgets the previous clip. Without this, a second recording in the same
  /// conversation is judged on the first one's frames.
  void reset() {
    _frames.clear();
    receivedCount = 0;
    unreadableCount = 0;
  }

  void addFrame(CameraImage image, {DateTime? at}) {
    final grid = CameraFrameReader.toGrid(image);
    if (grid == null) {
      receivedCount++;
      unreadableCount++;
      return;
    }
    addGrid(grid, at: at ?? DateTime.now());
  }

  void addGrid(FrameGrid grid, {required DateTime at}) {
    receivedCount++;
    if (_frames.length >= maxFrames) {
      unreadableCount++;
      return;
    }
    _frames.add(HandFrame.scan(grid.toSkinMask(), at));
  }

  GestureVerdict verdict() {
    if (!sawFrames) {
      return const GestureVerdict(
        outcome: GestureOutcome.nothingSeen,
        detail: 'no camera frames reached the recognizer',
      );
    }
    if (_frames.isEmpty) {
      return const GestureVerdict(
        outcome: GestureOutcome.unclear,
        detail: 'every frame was unreadable',
      );
    }
    return GestureClassifier.classify(track);
  }
}
