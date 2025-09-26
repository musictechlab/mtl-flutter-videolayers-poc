// lib/main.dart — QR pairing + HTTP signaling WebRTC + play-one-video after connect
// Requires: flutter_webrtc, http, mobile_scanner, video_player

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:video_player/video_player.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LayersApp());
}

class LayersApp extends StatelessWidget {
  const LayersApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Layered Playback (WebRTC)',
      theme: ThemeData.dark(useMaterial3: true),
      home: const LayersHome(),
      debugShowCheckedModeBanner: false,
    );
  }
}

/* -------------------------------------------------------------------------- */
/*                             Host pairing helpers                            */
/* -------------------------------------------------------------------------- */

enum HostMode { webrtc, ws }

/// Helper for pairing with the Host and doing WebRTC signaling over HTTP.
class HostLink {
  String? host;
  int? port;
  String? token;
  HostMode mode = HostMode.webrtc;

  bool get isPaired => host != null && port != null && token != null;
  String getLink() => isPaired ? 'http://$host:$port' : '(unpaired)';
  String get debugDescription =>
      isPaired ? '${getLink()} (mode: ${mode.name})' : '(unpaired)';

  /// QR example:
  /// ambistream://pair?host=Marios-Laptop.local&port=53140&token=XYZ&mode=webrtc
  Future<void> connectFromPairUri(String pairUri) async {
    final uri = Uri.parse(pairUri);
    final h = uri.queryParameters['host'];
    final t = uri.queryParameters['token'];
    final mStr = uri.queryParameters['mode'] ?? 'webrtc';
    final pStr = uri.queryParameters['port'];

    if (h == null || t == null) {
      throw 'Missing host or token in QR';
    }
    host = h;
    port = pStr != null ? int.tryParse(pStr) : (uri.hasPort ? uri.port : 80);
    if (port == null) throw 'Invalid port';
    token = t;
    mode = mStr == 'ws' ? HostMode.ws : HostMode.webrtc;
  }

  /// POST /webrtc/offer  { token, sdp }  ->  { sdp }
  Future<String?> sendSdpOffer(String offerSdp) async {
    _ensurePaired();
    final url = Uri(
      scheme: 'http',
      host: host,
      port: port,
      path: '/webrtc/offer',
    );

    final resp = await http
        .post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'token': token, 'sdp': offerSdp}),
        )
        .timeout(const Duration(seconds: 12));

    if (resp.statusCode != 200) {
      debugPrint('Offer failed: HTTP ${resp.statusCode} body=${resp.body}');
      throw 'Offer failed: HTTP ${resp.statusCode}';
    }

    final m = jsonDecode(resp.body) as Map<String, dynamic>;
    return m['sdp'] as String?;
  }

  /// POST /webrtc/ice  { token, candidate, sdpMid, sdpMLineIndex }
  Future<void> sendIce(Map<String, dynamic> cand) async {
    _ensurePaired();
    final url = Uri(
      scheme: 'http',
      host: host,
      port: port,
      path: '/webrtc/ice',
    );

    final body = {
      'token': token,
      'candidate': cand['candidate'],
      'sdpMid': cand['sdpMid'],
      'sdpMLineIndex': cand['sdpMLineIndex'],
    };

    final resp = await http
        .post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 12));

    if (resp.statusCode != 200) {
      debugPrint('ICE post failed: HTTP ${resp.statusCode} body=${resp.body}');
      throw 'ICE post failed: HTTP ${resp.statusCode}';
    }
  }

  void _ensurePaired() {
    if (!isPaired) {
      throw 'Missing host/port/token – scan the QR first';
    }
  }
}

/* -------------------------------------------------------------------------- */
/*                                Cast session                                */
/* -------------------------------------------------------------------------- */

/// Handles the WebRTC peer connection to the Host and opens a control data channel.
/// We use the data channel to command the host to play a given video URL.
class CastSession {
  RTCPeerConnection? _pc;
  RTCDataChannel? _ctrl;
  final HostLink hostLink;

  // Expose readiness
  final _connectedCtrl = StreamController<bool>.broadcast();
  final _pcStateCtrl = StreamController<RTCPeerConnectionState>.broadcast();

  Stream<bool> get onControlReady => _connectedCtrl.stream;
  Stream<RTCPeerConnectionState> get onPcState => _pcStateCtrl.stream;

  bool get isDataChannelOpen =>
      _ctrl?.state == RTCDataChannelState.RTCDataChannelOpen;

  CastSession(this.hostLink);

  bool get isActive => _pc != null;

  Future<void> start() async {
    if (_pc != null) return;

    final config = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
    };

    _pc = await createPeerConnection(config, {
      'mandatory': {},
      'optional': [
        {'DtlsSrtpKeyAgreement': true},
      ],
    });

    _pc!.onIceCandidate = (RTCIceCandidate c) {
      if (c.candidate != null) {
        hostLink
            .sendIce({
              'candidate': c.candidate,
              'sdpMid': c.sdpMid,
              'sdpMLineIndex': c.sdpMLineIndex,
            })
            .catchError((e) => debugPrint('sendIce error: $e'));
      }
    };

    _pc!.onConnectionState = (state) {
      _pcStateCtrl.add(state);
      debugPrint('PC state: $state');
    };

    // Create control data channel
    _ctrl = await _pc!.createDataChannel(
      'control',
      RTCDataChannelInit()..ordered = true,
    );
    _ctrl!.onDataChannelState = (state) {
      final ok = state == RTCDataChannelState.RTCDataChannelOpen;
      _connectedCtrl.add(ok);
      debugPrint('DataChannel(control) state: $state');
    };

    // Offer / Answer
    final offer = await _pc!.createOffer({
      'offerToReceiveVideo': 0,
      'offerToReceiveAudio': 0,
    });
    await _pc!.setLocalDescription(offer);

    final answerSdp = await hostLink.sendSdpOffer(offer.sdp!);
    if (answerSdp == null || answerSdp.isEmpty) {
      throw 'Host returned empty SDP answer';
    }

    try {
      await _pc!.setRemoteDescription(
        RTCSessionDescription(answerSdp, 'answer'),
      );
    } catch (e) {
      debugPrint(
        'Bad SDP answer head: ${answerSdp.substring(0, answerSdp.length.clamp(0, 160))}',
      );
      rethrow;
    }
  }

  Future<void> stop() async {
    try {
      await _ctrl?.close();
    } catch (_) {}
    try {
      await _pc?.close();
    } catch (_) {}
    _ctrl = null;
    _pc = null;
  }

  /// Send a "PLAY" command with a video URL to the host.
  Future<void> sendPlayUrl(String url) async {
    print('sendPlayUrl: $url');
    if (!isDataChannelOpen) throw 'Control channel not open';
    final msg = jsonEncode({'type': 'PLAY', 'url': url});
    await _ctrl!.send(RTCDataChannelMessage(msg));
  }

  Future<void> sendPause() async {
    if (!isDataChannelOpen) return;
    await _ctrl!.send(RTCDataChannelMessage(jsonEncode({'type': 'PAUSE'})));
  }
}

/* -------------------------------------------------------------------------- */
/*                                QR scanner                                  */
/* -------------------------------------------------------------------------- */

class ScanHostScreen extends StatefulWidget {
  const ScanHostScreen({super.key});
  @override
  State<ScanHostScreen> createState() => _ScanHostScreenState();
}

class _ScanHostScreenState extends State<ScanHostScreen> {
  bool _handled = false;
  final _controller = MobileScannerController(facing: CameraFacing.back);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Host QR')),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) async {
              if (_handled) return;
              final codes = capture.barcodes;
              final raw = codes.isNotEmpty ? codes.first.rawValue : null;
              if (raw == null) return;
              _handled = true;
              Navigator.pop(context, raw);
            },
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('Point at the host’s QR code'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

/* -------------------------------------------------------------------------- */
/*                               Main demo UI                                 */
/* -------------------------------------------------------------------------- */

class LayersHome extends StatefulWidget {
  const LayersHome({super.key});
  @override
  State<LayersHome> createState() => _LayersHomeState();
}

class _LayersHomeState extends State<LayersHome> {
  // Choose a single video to play when connected:
  static const demoVideos = <String>[
    'https://ambistream.musictechlab.io/media/videos/AI_Video_Showcase.mp4',
    //   'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4',
    //   'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
  ];
  String _selectedUrl = demoVideos.first;

  final HostLink _hostLink = HostLink();
  late final CastSession _cast;

  VideoPlayerController? _player;
  bool _connecting = false;
  bool _dcReady = false;
  bool _pcReady = false; // connected or completed
  String? _error;

  bool get _isReadyToPlay {
    // Enable when either DC open OR PC connected.
    if (_dcReady || _pcReady) return true;
    // Fallback: allow press when paired (lets you test even if state events are missed)
    return _hostLink.isPaired;
  }

  @override
  void initState() {
    super.initState();
    _cast = CastSession(_hostLink);
    _cast.onControlReady.listen((ok) {
      setState(() => _dcReady = ok);
    });
    _cast.onPcState.listen((s) {
      final ok = s == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
      setState(() => _pcReady = ok);
    });
  }

  @override
  void dispose() {
    _player?.dispose();
    _cast.stop();
    super.dispose();
  }

  Future<void> _scanAndConnectHost() async {
    final scanned = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const ScanHostScreen()));
    if (scanned == null) return;

    setState(() {
      _error = null;
      _connecting = true;
      _dcReady = false;
      _pcReady = false;
    });

    try {
      await _hostLink.connectFromPairUri(scanned);
      await _cast.start();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connected: ${_hostLink.debugDescription}')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Connect failed: $e');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _playSelected() async {
    // Send to host
    try {
      await _cast.sendPlayUrl(_selectedUrl);
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to send PLAY: $e')));
    }

    // Local preview (optional)
    await _player?.dispose();
    _player = VideoPlayerController.networkUrl(Uri.parse(_selectedUrl));
    await _player!.initialize();
    await _player!.play();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = _player;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Layered Playback'),
        actions: [
          IconButton(
            tooltip: _hostLink.isPaired ? 'Connected' : 'Scan host to connect',
            onPressed: _connecting ? null : _scanAndConnectHost,
            icon: Icon(_hostLink.isPaired ? Icons.link : Icons.qr_code_scanner),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),

          // Status row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Text('WebRTC:'),
                const SizedBox(width: 8),
                Icon(
                  _dcReady || _pcReady
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  _hostLink.isPaired ? _hostLink.getLink() : '(not connected)',
                ),
              ],
            ),
          ),

          // Video selector
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Select video to play on Host'),
                const SizedBox(height: 6),
                DropdownButton<String>(
                  value: _selectedUrl,
                  isExpanded: true,
                  items: [
                    for (final u in demoVideos)
                      DropdownMenuItem(value: u, child: Text(u)),
                  ],
                  onChanged: (v) => setState(() => _selectedUrl = v!),
                ),
                const SizedBox(height: 10),
                // << moved here: big play button under the list >>
                FilledButton.icon(
                  onPressed: (!_connecting && _isReadyToPlay)
                      ? _playSelected
                      : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play on Host'),
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),

          // Local preview area
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: p != null && p.value.isInitialized
                  ? AspectRatio(
                      aspectRatio: p.value.aspectRatio,
                      child: VideoPlayer(p),
                    )
                  : Center(
                      child: Text(
                        _isReadyToPlay
                            ? 'Pick a video and press “Play on Host”.'
                            : 'Scan the Host QR to connect via WebRTC.',
                        textAlign: TextAlign.center,
                      ),
                    ),
            ),
          ),
        ],
      ),
      floatingActionButton: (p != null && p.value.isInitialized)
          ? FloatingActionButton.extended(
              onPressed: () async {
                if (p.value.isPlaying) {
                  await p.pause();
                  await _cast.sendPause();
                } else {
                  await p.play();
                }
                setState(() {});
              },
              icon: Icon(p.value.isPlaying ? Icons.pause : Icons.play_arrow),
              label: Text(p.value.isPlaying ? 'Pause' : 'Play'),
            )
          : null,
    );
  }
}
