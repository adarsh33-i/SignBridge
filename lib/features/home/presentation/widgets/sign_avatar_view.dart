import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sign_bridge/services/avatar/sign_playback_config.dart';
import 'package:sign_bridge/services/translate/sign_language_system.dart';
import 'package:sign_bridge/services/translate/sign_token.dart';

import 'asl_sign_overlay.dart';
import 'sign_video_avatar_view.dart';
import 'vector_sign_avatar.dart';

/// Renders the signing avatar with Hugging Face signer videos when available.
class SignAvatarView extends StatelessWidget {
  const SignAvatarView({
    super.key,
    required this.signTokenId,
    required this.signSystem,
    required this.fallbackAsset,
    required this.signingWord,
    this.signSequence = const [],
    this.signPulse = 0,
    this.showNative = true,
    this.onGlossChanged,
  });

  final String signTokenId;
  final SignLanguageSystem signSystem;
  final String fallbackAsset;
  final String signingWord;
  final List<SignToken> signSequence;
  final int signPulse;
  final bool showNative;

  /// Forwarded to the rig so the gloss chip can follow the hands.
  final ValueChanged<String?>? onGlossChanged;

  static bool get _isFlutterTest =>
      Platform.environment.containsKey('FLUTTER_TEST');

  bool get _useSignerVideo {
    if (SignPlaybackConfig.imagesOnly) {
      return false;
    }
    if (!showNative || kIsWeb || _isFlutterTest) {
      return false;
    }
    if (!(Platform.isAndroid || Platform.isIOS)) {
      return false;
    }
    return signTokenId != SignTokenIds.thinking;
  }

  bool get _showOverlay {
    if (SignPlaybackConfig.imagesOnly) {
      return false;
    }
    if (_useSignerVideo || !showNative || kIsWeb || _isFlutterTest) {
      return false;
    }
    return signTokenId != SignTokenIds.thinking;
  }

  Widget _buildFallback() {
    final sequence = _sequenceOrSingleToken;
    if (sequence.isNotEmpty) {
      // The rig draws the movement itself, so it replaces the illustration
      // whenever there is something to sign.
      return VectorSignAvatar(
        sequence: sequence,
        onGlossChanged: onGlossChanged,
      );
    }
    return Stack(
      fit: StackFit.expand,
      alignment: Alignment.bottomCenter,
      children: [
        Image.asset(
          fallbackAsset,
          fit: BoxFit.contain,
          alignment: Alignment.bottomCenter,
        ),
        if (_showOverlay)
          AslSignOverlay(
            key: ValueKey('$signTokenId-$signPulse'),
            signTokenId: signTokenId,
            gloss: signingWord,
            pulse: signPulse,
          ),
      ],
    );
  }

  List<SignToken> get _sequenceOrSingleToken {
    if (signSequence.isNotEmpty) return signSequence;
    if (signTokenId == SignTokenIds.thinking || signTokenId.isEmpty) {
      return const [];
    }
    return [
      SignToken(id: signTokenId, gloss: signingWord, system: signSystem),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (_useSignerVideo) {
      return SignVideoAvatarView(
        signSystem: signSystem,
        signSequence: signSequence,
        pulse: signPulse,
        fallback: _buildFallback(),
      );
    }

    return _buildFallback();
  }
}

/// Stable sign ids shared with native avatar pose tables.
abstract final class SignTokenIds {
  static const thinking = 'thinking';
}
