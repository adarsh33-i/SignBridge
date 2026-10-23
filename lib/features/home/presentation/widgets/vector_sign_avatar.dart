import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../../services/avatar/rig/avatar_painter.dart';
import '../../../../services/avatar/rig/idle_layer.dart';
import '../../../../services/avatar/rig/sign_timeline.dart';
import 'package:sign_bridge/services/translate/sign_token.dart';

/// The 2D signing character, driven by the gloss sequence.
///
/// Each token resolves to an authored animation, a non-manual face cue, or a
/// fingerspelled word, and [SignTimeline] stitches them into one clock that
/// already ends by returning the hands to rest. The player runs that clock once
/// and stops with it, so a caption that has finished signing leaves the avatar
/// at rest instead of re-signing forever.
///
/// One ticker is the time source for both the sign run and [IdleLayer]. That is
/// deliberate: deriving the idle clock from the loop position made a short
/// caption blink once per repetition.
class VectorSignAvatar extends StatefulWidget {
  const VectorSignAvatar({
    super.key,
    required this.sequence,
    this.speed = 1,
    this.painterPalette = const AvatarPalette(),
    this.onGlossChanged,
  });

  final List<SignToken> sequence;
  final double speed;
  final AvatarPalette painterPalette;

  /// Reports the gloss the hands are on, and null once the caption has settled.
  ///
  /// Fires only when the answer changes, so a whole sentence is a handful of
  /// calls rather than one per frame.
  final ValueChanged<String?>? onGlossChanged;

  @override
  State<VectorSignAvatar> createState() => _VectorSignAvatarState();
}

class _VectorSignAvatarState extends State<VectorSignAvatar>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  SignTimeline _timeline = SignTimeline.of(const []);

  /// Milliseconds of the timeline already played. Accumulated rather than
  /// derived from the wall clock so an appended gloss resumes where the caption
  /// stopped instead of jumping past the new sign.
  int _playedMs = 0;
  Duration? _lastTick;
  Duration _now = Duration.zero;
  String? _reportedGloss;

  @override
  void initState() {
    super.initState();
    _timeline = SignTimeline.of(widget.sequence);
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didUpdateWidget(VectorSignAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The parent hands over a freshly built list on every rebuild, so identity
    // says "new caption" for a caption that has not changed.
    final sameGlosses = _sameSequence(oldWidget.sequence, widget.sequence);
    if (sameGlosses && oldWidget.speed == widget.speed) return;

    final next = SignTimeline.of(widget.sequence);
    // A live caption grows word by word. When the new list merely extends the
    // old one the clock carries over, so the hands travel on to the word that
    // just arrived instead of re-signing everything already shown.
    final extendsPrevious =
        !sameGlosses &&
        widget.sequence.length > oldWidget.sequence.length &&
        _isPrefixOf(oldWidget.sequence, widget.sequence);
    setState(() {
      _timeline = next;
      if (!extendsPrevious) _playedMs = 0;
      if (_playedMs > next.totalMs) _playedMs = next.totalMs;
    });
    // The next tick reports the new gloss. Reporting here would notify the
    // parent from inside its own build, and a setState during build throws.
  }

  void _onTick(Duration elapsed) {
    final last = _lastTick;
    _lastTick = elapsed;
    _now = elapsed;
    final total = _timeline.totalMs;
    if (last != null && _playedMs < total) {
      final speed = widget.speed <= 0 ? 1 : widget.speed;
      final next = _playedMs + (elapsed - last).inMilliseconds * speed;
      _playedMs = next > total ? total : next.round();
    }
    _report();
    setState(() {});
  }

  void _report() {
    final gloss = _timeline.glossAt(_playedMs);
    if (gloss == _reportedGloss) return;
    _reportedGloss = gloss;
    widget.onGlossChanged?.call(gloss);
  }

  static bool _sameSequence(List<SignToken> a, List<SignToken> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id ||
          a[i].gloss != b[i].gloss ||
          a[i].system != b[i].system) {
        return false;
      }
    }
    return true;
  }

  static bool _isPrefixOf(List<SignToken> prefix, List<SignToken> full) {
    for (var i = 0; i < prefix.length; i++) {
      if (prefix[i].id != full[i].id || prefix[i].gloss != full[i].gloss) {
        return false;
      }
    }
    return true;
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: AvatarPainter(
        pose: IdleLayer.apply(
          _timeline.poseAt(_playedMs),
          _now.inMilliseconds,
        ),
        palette: widget.painterPalette,
      ),
    );
  }
}
