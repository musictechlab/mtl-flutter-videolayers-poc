import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class MixedPlayerController {
  MixedPlayerController._(this._channel);
  final MethodChannel _channel;

  Future<void> load({
    required String baseUrl,
    required String overlayUrl,
    String? extraAudioUrl,
    double overlayOpacity = 0.7,
  }) async {
    await _channel.invokeMethod('load', {
      'baseUrl': baseUrl,
      'overlayUrl': overlayUrl,
      'extraAudioUrl': extraAudioUrl,
      'overlayOpacity': overlayOpacity,
    });
  }

  Future<void> play() => _channel.invokeMethod('play');
  Future<void> pause() => _channel.invokeMethod('pause');
  Future<void> seek(Duration to) =>
      _channel.invokeMethod('seek', {'ms': to.inMilliseconds});
  Future<void> setOpacity(double v) =>
      _channel.invokeMethod('setOpacity', {'value': v.clamp(0.0, 1.0)});
  Future<void> dispose() => _channel.invokeMethod('dispose');
}

typedef MixedPlayerCreated = void Function(MixedPlayerController);

class MixedPlayerView extends StatelessWidget {
  const MixedPlayerView({super.key, required this.onCreated});
  final MixedPlayerCreated onCreated;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS) return const SizedBox.shrink();

    return UiKitView(
      viewType: 'mtl.mixedplayer',
      onPlatformViewCreated: (id) {
        final channel = MethodChannel('mtl.mixedplayer/$id');
        onCreated(MixedPlayerController._(channel));
      },
      creationParams: const <String, dynamic>{},
      creationParamsCodec: const StandardMessageCodec(),
    );
  }
}