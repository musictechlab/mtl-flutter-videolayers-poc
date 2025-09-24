import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class HostLink {
  WebSocketChannel? _ch;
  String? host;
  int? port;
  String? token;

  /// WebRTC signaling tap-in (set by CastSession)
  void Function(Map<String, dynamic>)? onSignal;

  bool get isConnected => _ch != null;

  Future<void> connectFromPairUri(String pairUri) async {
    debugPrint('connectFromPairUri: $pairUri');
    final uri = Uri.parse(pairUri);

    String? h;
    int? p;
    String? t;

    if ((uri.scheme == 'ambistream') && (uri.host == 'pair')) {
      h = uri.queryParameters['host'];
      p = int.tryParse(uri.queryParameters['port'] ?? '');
      t = uri.queryParameters['token'];
    } else if (uri.scheme == 'ws' || uri.scheme == 'wss') {
      h = uri.host.isNotEmpty ? uri.host : null;
      p = uri.hasPort ? uri.port : (uri.scheme == 'wss' ? 443 : 80);
      t = uri.queryParameters['token'];
    } else {
      throw 'Invalid QR: unsupported scheme "${uri.scheme}"';
    }

    if (h == null || p == null || t == null) {
      throw 'Invalid QR: missing host/port/token';
    }

    await close();

    final wsUrl = Uri(
      scheme: (uri.scheme == 'wss') ? 'wss' : 'ws',
      host: h,
      port: p,
      path: '/',
      queryParameters: {'token': t},
    );

    _ch = WebSocketChannel.connect(wsUrl);

    _send({
      'type': 'HELLO',
      'token': t,
      'device': {'type': 'ios', 'name': 'Mobile Remote'},
    });

    _ch!.stream.listen(
      _handleIncoming,
      onDone: () => _ch = null,
      onError: (_) => _ch = null,
    );
  }

  // ---- WebRTC signaling helpers ----
  void sendSdpOffer(String sdp) => _send({'type': 'SDP_OFFER', 'sdp': sdp});
  void sendSdpAnswer(String sdp) => _send({'type': 'SDP_ANSWER', 'sdp': sdp});
  void sendIce(Map<String, dynamic> cand) => _send({'type': 'ICE', ...cand});

  // ---- Existing control messages ----
  void sendPlay(int mediaMs, {double rate = 1.0}) {
    if (!isConnected) return;
    final anchorWallMs = DateTime.now().millisecondsSinceEpoch + 150;
    _send({
      'type': 'PLAY',
      'rate': rate,
      'mediaMs': mediaMs,
      'anchorWallMs': anchorWallMs,
    });
  }

  void sendPauseAt(int mediaMs) {
    if (!isConnected) return;
    final anchorWallMs = DateTime.now().millisecondsSinceEpoch;
    _send({'type': 'PAUSE', 'mediaMs': mediaMs, 'anchorWallMs': anchorWallMs});
  }

  void sendSeek(int mediaMs) {
    if (!isConnected) return;
    final anchorWallMs = DateTime.now().millisecondsSinceEpoch + 120;
    _send({'type': 'SEEK', 'mediaMs': mediaMs, 'anchorWallMs': anchorWallMs});
  }

  void sendOpacity(double value) {
    if (!isConnected) return;
    _send({'type': 'SET_OPACITY', 'value': value});
  }

  void sendLoad({
    required String bgUrl,
    required String fgUrl,
    String? extraAudioUrl,
    required double opacity,
  }) {
    if (!isConnected) return;
    _send({
      'type': 'LOAD',
      'id': 'poc-1',
      'bgUrl': bgUrl,
      'fgUrl': fgUrl,
      'extraAudioUrl': extraAudioUrl,
      'opacity': opacity,
    });
  }

  Future<void> close() async {
    try {
      await _ch?.sink.close(1000);
    } catch (_) {}
    _ch = null;
    onSignal = null;
  }

  void _send(Map<String, dynamic> m) {
    try {
      _ch?.sink.add(jsonEncode(m));
    } catch (_) {}
  }

  void _handleIncoming(dynamic raw) {
    try {
      final m = jsonDecode(raw as String) as Map<String, dynamic>;
      switch (m['type'] as String?) {
        case 'SDP_OFFER':
        case 'SDP_ANSWER':
        case 'ICE':
          onSignal?.call(m);
          return;
        default:
          return;
      }
    } catch (_) {
      // ignore malformed
    }
  }

  String getLink() {
    return 'ws://$host:$port?token=$token';
  }
}

/// Global instance if you want singleton semantics
final hostLink = HostLink();
