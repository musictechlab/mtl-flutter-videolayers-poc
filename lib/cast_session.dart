import 'dart:async';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'host_link.dart';

// NOTE: For PoC we use camera video via getUserMedia so this compiles on iOS.
// Later, replace with a ReplayKit-based native capture and add that track.

class CastSession {
  RTCPeerConnection? _pc;
  MediaStream? _stream;
  bool get isActive => _pc != null;

  final HostLink hostLink;
  CastSession(this.hostLink);

  Future<void> start() async {
    if (_pc != null) return;

    final config = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    };

    _pc = await createPeerConnection(config, {'mandatory': {}, 'optional': []});

    // Forward local ICE candidates to host over WS
    _pc!.onIceCandidate = (RTCIceCandidate c) {
      hostLink.sendIce({
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };

    // Listen for signaling from HostLink
    hostLink.onSignal = (m) async {
      switch (m['type']) {
        case 'SDP_ANSWER':
          await _pc?.setRemoteDescription(
            RTCSessionDescription(m['sdp'] as String, 'answer'),
          );
          break;
        case 'ICE':
          final c = RTCIceCandidate(
            m['candidate'] as String?,
            m['sdpMid'] as String?,
            m['sdpMLineIndex'] as int?,
          );
          await _pc?.addCandidate(c);
          break;
      }
    };

    // === PoC: use camera so it builds ===
    _stream = await navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': {'facingMode': 'environment'},
    });

    for (final track in _stream!.getTracks()) {
      await _pc!.addTrack(track, _stream!);
    }

    final offer = await _pc!.createOffer({'offerToReceiveVideo': 0});
    await _pc!.setLocalDescription(offer);
    hostLink.sendSdpOffer(offer.sdp!);
  }

  Future<void> stop() async {
    try {
      // Stop local tracks
      _stream?.getTracks().forEach((t) => t.stop());
    } catch (_) {}
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    _stream = null;
    hostLink.onSignal = null;
  }
}
