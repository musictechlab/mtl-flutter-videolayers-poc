// lib/main.dart — single-file demo: QR pairing + HTTP signaling + WebRTC (camera+mic)

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:video_player/video_player.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LayersApp());
}

class LayersApp extends StatelessWidget {
  const LayersApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MTL Flutter Video Layers POC (WebRTC single-file)',
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

  // Optional callback if you later wire up server->client signaling.
  void Function(Map<String, dynamic>)? onSignal;

  // Convenience getters for UI
  bool get isPaired => host != null && port != null && token != null;
  bool get isComplete => isPaired; // legacy alias
  String getLink() => isPaired ? 'http://$host:$port' : '(unpaired)';
  String get debugDescription =>
      isPaired ? '${getLink()} (mode: ${mode.name})' : '(unpaired)';

  /// Parse the QR from the host and store host/port/token/mode.
  Future<void> connectFromPairUri(String pairUri) async {
    final uri = Uri.parse(pairUri);

    String? h;
    int? p;
    String? t;
    HostMode m = HostMode.webrtc;

    if (uri.scheme == 'ambistream' && uri.host == 'pair') {
      h = uri.queryParameters['host'];
      t = uri.queryParameters['token'];

      // port might be omitted in QR; default to 80 (or whatever your host serves).
      final portStr = uri.queryParameters['port'];
      p = (portStr != null && portStr.isNotEmpty) ? int.tryParse(portStr) : 80;

      final modeStr = (uri.queryParameters['mode'] ?? '').toLowerCase();
      if (modeStr == 'ws' || modeStr == 'websocket') {
        m = HostMode.ws;
      } else {
        m = HostMode.webrtc;
      }
    } else if (uri.scheme == 'ws' || uri.scheme == 'wss') {
      // Back-compat: just extract host/port/token (WebSocket QR from older host)
      h = uri.host.isNotEmpty ? uri.host : null;
      p = uri.hasPort ? uri.port : (uri.scheme == 'wss' ? 443 : 80);
      t = uri.queryParameters['token'];
      m = HostMode.ws;
    } else {
      throw 'Unsupported QR scheme: ${uri.scheme}';
    }

    if (h == null || p == null || t == null) {
      throw 'Missing host/port/token in pairing URI';
    }

    host = h;
    port = p;
    token = t;
    mode = m;
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
        .timeout(const Duration(seconds: 8));

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
        .timeout(const Duration(seconds: 8));

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

class CastSession {
  RTCPeerConnection? _pc;
  MediaStream? _stream; // temp: camera+mic
  bool get isActive => _pc != null;

  final HostLink hostLink;
  CastSession(this.hostLink);

  Future<void> start() async {
    if (_pc != null) return;

    // ---- PeerConnection config (STUN only for now) ----
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

    // Forward local ICE to host over HTTP
    _pc!.onIceCandidate = (RTCIceCandidate c) {
      if (c.candidate != null) {
        debugPrint('Trickle ICE (len ${c.candidate!.length})');
        hostLink
            .sendIce({
              'candidate': c.candidate,
              'sdpMid': c.sdpMid,
              'sdpMLineIndex': c.sdpMLineIndex,
            })
            .catchError((e) => debugPrint('sendIce error: $e'));
      }
    };

    _pc!.onIceConnectionState = (state) {
      debugPrint('ICE state: $state');
    };
    _pc!.onConnectionState = (state) {
      debugPrint('PC state: $state');
    };

    // ---- TEMP CAPTURE (camera+mic) ----
    // Replace this with ReplayKit screen capture later.
    _stream = await navigator.mediaDevices.getUserMedia({
      'video': {
        'facingMode': 'environment', // or 'user'
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
        'frameRate': {'ideal': 30},
      },
      'audio': true,
    });

    for (final track in _stream!.getTracks()) {
      await _pc!.addTrack(track, _stream!);
    }

    // ---- Offer / Answer via Host HTTP signaling ----
    final offer = await _pc!.createOffer({
      'offerToReceiveVideo': 1,
      'offerToReceiveAudio': 1,
    });
    await _pc!.setLocalDescription(offer);
    debugPrint('Sending offer (len ${offer.sdp?.length ?? 0})');

    final answerSdp = await hostLink.sendSdpOffer(offer.sdp!);
    debugPrint('Received answer (len ${answerSdp?.length ?? 0})');

    if (answerSdp == null || answerSdp.isEmpty) {
      throw 'Host did not return an SDP answer';
    }
    await _pc!.setRemoteDescription(RTCSessionDescription(answerSdp, 'answer'));

    // If you later add host->client trickle, route it here:
    hostLink.onSignal = (m) async {
      if (m['type'] == 'ICE') {
        final c = RTCIceCandidate(
          m['candidate'] as String?,
          m['sdpMid'] as String?,
          (m['sdpMLineIndex'] as num?)?.toInt(),
        );
        await _pc?.addCandidate(c);
      }
    };
  }

  Future<void> stop() async {
    try {
      await _pc?.close();
    } catch (_) {}
    try {
      _stream?.getTracks().forEach((t) => t.stop());
      await _stream?.dispose();
    } catch (_) {}
    _pc = null;
    _stream = null;
    hostLink.onSignal = null;
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
                child: const Text(
                  'Point at the host’s QR code',
                  style: TextStyle(fontSize: 16),
                ),
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
  // --- MEDIA SOURCES (local demo playback only) ---
  static const baseUrl =
      'https://ambistream.musictechlab.io/media/videos/AI_Video_Showcase.mp4';
  static const overlayUrl =
      'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4';
  static const extraAudioUrl =
      'https://onlinetestcase.com/wp-content/uploads/2023/06/1-MB-MP3.mp3';

  static const srtNetworkUrl = '';
  static const srtAssetPath = 'assets/subs/sample.srt';

  // --- local players (for on-phone preview) ---
  late final VideoPlayerController _baseVideo;
  late final VideoPlayerController _overlayVideo;
  final AudioPlayer _extraAudio = AudioPlayer();

  // Host / Casting
  final HostLink _hostLink = HostLink();
  late final CastSession _cast;

  // Layer visibility / state
  bool _showBase = true;
  bool _showOverlay = true;
  bool _showImage = false;
  bool _useExtraAudio = false;
  bool _showSubtitles = true;

  // Layer params
  double _baseVolume = 1.0;
  double _overlayOpacity = 0.7;
  double _overlayVolume = 0.0; // start muted
  double _extraAudioVolume = 1.0;
  double _subtitleFont = 22;

  // Runtime
  bool _ready = false;
  String? _error;

  // Subtitles
  List<_SrtCue> _cues = [];
  String _currentSub = '';
  Timer? _subTicker;

  // Sync helper
  Timer? _resyncTimer;

  // Timeline / scrubbing
  bool _isScrubbing = false;
  Duration _scrubTarget = Duration.zero;

  // Panel expansion state
  final _expanded = <String, bool>{
    'base': false,
    'overlay': false,
    'image': false,
    'audio': false,
    'subs': false,
  };

  @override
  void initState() {
    super.initState();
    _cast = CastSession(_hostLink);
    _baseVideo = VideoPlayerController.networkUrl(Uri.parse(baseUrl));
    _overlayVideo = VideoPlayerController.networkUrl(Uri.parse(overlayUrl));
    _init();
  }

  Future<void> _init() async {
    setState(() {
      _ready = false;
      _error = null;
    });

    try {
      // Let just_audio mix with video_player
      final session = await AudioSession.instance;
      await session.configure(
        AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playback,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.mixWithOthers,
          avAudioSessionMode: AVAudioSessionMode.defaultMode,
          androidAudioAttributes: const AndroidAudioAttributes(
            contentType: AndroidAudioContentType.music,
            usage: AndroidAudioUsage.media,
          ),
          androidWillPauseWhenDucked: false,
        ),
      );
      await session.setActive(true);

      // Init videos
      await _baseVideo.initialize();
      await _overlayVideo.initialize();
      await _baseVideo.setLooping(true);
      await _overlayVideo.setLooping(true);
      await _baseVideo.setVolume(_baseVolume);
      await _overlayVideo.setVolume(_overlayVolume);

      // Init extra audio
      await _extraAudio.setUrl(extraAudioUrl);
      await _extraAudio.setLoopMode(LoopMode.one);
      await _extraAudio.setVolume(_extraAudioVolume);

      // Subtitles
      await _loadSubtitles();
      _startSubtitleTicker();

      // Align and start videos
      await _overlayVideo.seekTo(_baseVideo.value.position);
      await _baseVideo.play();
      await _overlayVideo.play();

      if (_useExtraAudio) {
        await _extraAudio.seek(_baseVideo.value.position);
        await _extraAudio.play();
      }

      _wireErrorListeners();

      _resyncTimer = Timer.periodic(const Duration(milliseconds: 750), (
        _,
      ) async {
        if (!_useExtraAudio) return;
        if (!_baseVideo.value.isInitialized || !_baseVideo.value.isPlaying)
          return;
        final vp = _baseVideo.value.position;
        final ap = _extraAudio.position;
        if ((vp - ap).inMilliseconds.abs() > 250) {
          await _extraAudio.seek(vp);
        }
      });

      if (!mounted) return;
      setState(() => _ready = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Init error: $e');
    }
  }

  Future<void> _loadSubtitles() async {
    try {
      String raw;
      if (srtNetworkUrl.isNotEmpty) {
        final resp = await http.get(Uri.parse(srtNetworkUrl));
        if (resp.statusCode != 200) throw 'HTTP ${resp.statusCode}';
        raw = resp.body;
      } else {
        raw = await rootBundle.loadString(srtAssetPath);
      }
      _cues = _parseSrt(raw);
    } catch (e) {
      _cues = [];
      debugPrint('SRT load failed: $e');
    }
  }

  void _startSubtitleTicker() {
    _subTicker?.cancel();
    _subTicker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!_showSubtitles || !_baseVideo.value.isInitialized) return;
      final pos = _baseVideo.value.position;
      final text = _lookupSub(pos, _cues);
      if (text != _currentSub && mounted) {
        setState(() => _currentSub = text);
      }
    });
  }

  String _lookupSub(Duration t, List<_SrtCue> cues) {
    for (final c in cues) {
      if (t >= c.start && t <= c.end) return c.text;
    }
    return '';
  }

  void _wireErrorListeners() {
    _baseVideo.addListener(() {
      final err = _baseVideo.value.errorDescription;
      if (err != null && mounted) setState(() => _error = 'Base error: $err');
    });
    _overlayVideo.addListener(() {
      final err = _overlayVideo.value.errorDescription;
      if (err != null && mounted)
        setState(() => _error = 'Overlay error: $err');
    });
  }

  @override
  void dispose() {
    _subTicker?.cancel();
    _resyncTimer?.cancel();
    _baseVideo.dispose();
    _overlayVideo.dispose();
    _extraAudio.dispose();
    super.dispose();
  }

  Future<void> _togglePlayPause() async {
    final isPlaying = _baseVideo.value.isPlaying;
    if (isPlaying) {
      await _baseVideo.pause();
      await _overlayVideo.pause();
      if (_useExtraAudio) await _extraAudio.pause();
    } else {
      final pos = _baseVideo.value.position;
      await _overlayVideo.seekTo(pos);
      if (_useExtraAudio) await _extraAudio.seek(pos);
      await _baseVideo.play();
      await _overlayVideo.play();
      if (_useExtraAudio) await _extraAudio.play();
    }
    setState(() {});
  }

  Future<void> _toggleExtraAudio(bool v) async {
    _useExtraAudio = v;
    if (_ready && _baseVideo.value.isPlaying && _useExtraAudio) {
      await _extraAudio.seek(_baseVideo.value.position);
      await _extraAudio.play();
    } else {
      await _extraAudio.pause();
    }
    setState(() {});
  }

  // Unified seek for all layers
  Future<void> _seekAll(Duration to) async {
    final wasPlaying = _baseVideo.value.isPlaying;
    await _baseVideo.pause();
    await _overlayVideo.pause();
    if (_useExtraAudio) await _extraAudio.pause();

    await _baseVideo.seekTo(to);
    await _overlayVideo.seekTo(to);
    if (_useExtraAudio) await _extraAudio.seek(to);

    if (wasPlaying) {
      await _baseVideo.play();
      await _overlayVideo.play();
      if (_useExtraAudio) await _extraAudio.play();
    }
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Future<void> _scanAndConnectHost() async {
    final scanned = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const ScanHostScreen()));
    if (scanned == null) return;

    try {
      await _hostLink.connectFromPairUri(scanned);
      debugPrint('Paired: ${_hostLink.debugDescription}');

      // For WebRTC mode → start casting
      if (_hostLink.mode == HostMode.webrtc) {
        await _cast.start();
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connected: ${_hostLink.debugDescription}')),
      );
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Connect failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Layered Playback')),
        body: Center(child: Text(_error!, textAlign: TextAlign.center)),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Layered Playback'),
        actions: [
          IconButton(
            tooltip: _hostLink.isComplete
                ? 'Connected'
                : 'Scan host to connect',
            onPressed: _scanAndConnectHost,
            icon: Icon(
              _hostLink.isComplete ? Icons.link : Icons.qr_code_scanner,
            ),
          ),
          IconButton(
            tooltip: _baseVideo.value.isPlaying ? 'Pause' : 'Play',
            onPressed: _togglePlayPause,
            icon: Icon(
              _baseVideo.value.isPlaying ? Icons.pause : Icons.play_arrow,
            ),
          ),
        ],
      ),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // 1) Video with exact height (no leftover space)
                LayoutBuilder(
                  builder: (context, constraints) {
                    final ar = _baseVideo.value.aspectRatio; // width / height
                    final maxWidth = constraints.maxWidth;
                    final idealHeight = maxWidth / ar; // keep aspect
                    final maxHeight =
                        constraints.maxHeight * 0.45; // cap at ~45% of screen
                    final videoHeight = idealHeight > maxHeight
                        ? maxHeight
                        : idealHeight;

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: videoHeight,
                          width: double.infinity,
                          child: Stack(
                            children: [
                              if (_showBase)
                                Positioned.fill(child: VideoPlayer(_baseVideo)),
                              if (_showOverlay)
                                Positioned.fill(
                                  child: Opacity(
                                    opacity: _overlayOpacity,
                                    child: VideoPlayer(_overlayVideo),
                                  ),
                                ),
                              if (_showSubtitles && _currentSub.isNotEmpty)
                                Positioned(
                                  left: 12,
                                  right: 12,
                                  bottom: 12,
                                  child: _SubtitleBubble(
                                    text: _currentSub,
                                    fontSize: _subtitleFont,
                                  ),
                                ),
                              if (_showImage)
                                Positioned(
                                  right: 24,
                                  bottom: 24,
                                  width: 200,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      border: Border.all(color: Colors.white24),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Image.asset(
                                      'assets/media/sample_image.jpg',
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),

                        // 2) Timeline directly under the video (no gap)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: ValueListenableBuilder<VideoPlayerValue>(
                            valueListenable: _baseVideo,
                            builder: (context, value, _) {
                              final dur = value.duration;
                              final valid = dur != null && dur > Duration.zero;
                              final pos = value.position;
                              final cur = _isScrubbing ? _scrubTarget : pos;
                              final maxMs = valid
                                  ? dur!.inMilliseconds.toDouble()
                                  : 1.0;
                              final curMs = cur.inMilliseconds
                                  .clamp(0, maxMs)
                                  .toDouble();

                              return Column(
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        _fmt(
                                          Duration(milliseconds: curMs.round()),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Slider(
                                          value: curMs,
                                          min: 0.0,
                                          max: maxMs,
                                          onChangeStart: (_) {
                                            setState(() {
                                              _isScrubbing = true;
                                              _scrubTarget = pos;
                                            });
                                          },
                                          onChanged: (v) {
                                            setState(() {
                                              _scrubTarget = Duration(
                                                milliseconds: v.round(),
                                              );
                                            });
                                          },
                                          onChangeEnd: (v) async {
                                            final to = Duration(
                                              milliseconds: v.round(),
                                            );
                                            setState(() {
                                              _isScrubbing = false;
                                              _scrubTarget = to;
                                            });
                                            await _seekAll(to);
                                          },
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Text(valid ? _fmt(dur!) : '--:--'),
                                    ],
                                  ),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      IconButton(
                                        tooltip: 'Back 10s',
                                        onPressed: valid
                                            ? () async {
                                                final p =
                                                    _baseVideo.value.position -
                                                    const Duration(seconds: 10);
                                                await _seekAll(
                                                  p < Duration.zero
                                                      ? Duration.zero
                                                      : p,
                                                );
                                              }
                                            : null,
                                        icon: const Icon(Icons.replay_10),
                                      ),
                                      IconButton(
                                        tooltip: 'Forward 10s',
                                        onPressed: valid
                                            ? () async {
                                                final d =
                                                    _baseVideo.value.duration;
                                                if (d == null) return;
                                                final p =
                                                    _baseVideo.value.position +
                                                    const Duration(seconds: 10);
                                                await _seekAll(p > d ? d : p);
                                              }
                                            : null,
                                        icon: const Icon(Icons.forward_10),
                                      ),
                                    ],
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    );
                  },
                ),

                const SizedBox(height: 8),

                // 3) Panels take the rest
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    children: [
                      _layerPanel(
                        context,
                        keyStr: 'base',
                        icon: Icons.video_settings_outlined,
                        title: 'Base Layer',
                        enabled: _showBase,
                        onToggle: (v) => setState(() => _showBase = v),
                        child: _volumeRow(
                          label: 'Base volume',
                          value: _baseVolume,
                          onChange: (v) async {
                            setState(() => _baseVolume = v);
                            await _baseVideo.setVolume(v);
                          },
                        ),
                      ),
                      _layerPanel(
                        context,
                        keyStr: 'overlay',
                        icon: Icons.layers,
                        title: 'Overlay Layer',
                        enabled: _showOverlay,
                        onToggle: (v) => setState(() => _showOverlay = v),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                const Padding(
                                  padding: EdgeInsets.only(left: 16),
                                  child: Text('Opacity'),
                                ),
                                Expanded(
                                  child: Slider(
                                    value: _overlayOpacity,
                                    min: 0.0,
                                    max: 1.0,
                                    onChanged: (v) {
                                      setState(() => _overlayOpacity = v);
                                    },
                                  ),
                                ),
                              ],
                            ),
                            _volumeRow(
                              label: 'Overlay volume',
                              value: _overlayVolume,
                              onChange: (v) async {
                                setState(() => _overlayVolume = v);
                                await _overlayVideo.setVolume(v);
                              },
                            ),
                          ],
                        ),
                      ),
                      _layerPanel(
                        context,
                        keyStr: 'image',
                        icon: Icons.image_outlined,
                        title: 'Image Layer',
                        enabled: _showImage,
                        onToggle: (v) => setState(() => _showImage = v),
                        child: const Padding(
                          padding: EdgeInsets.only(left: 16, right: 16, top: 4),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Currently pinned bottom-right (200px).',
                              style: TextStyle(color: Colors.white70),
                            ),
                          ),
                        ),
                      ),
                      _layerPanel(
                        context,
                        keyStr: 'audio',
                        icon: Icons.graphic_eq,
                        title: 'Extra Audio Layer',
                        enabled: _useExtraAudio,
                        onToggle: (v) => _toggleExtraAudio(v),
                        child: _volumeRow(
                          label: 'Extra audio volume',
                          value: _extraAudioVolume,
                          onChange: (v) async {
                            setState(() => _extraAudioVolume = v);
                            await _extraAudio.setVolume(v);
                          },
                        ),
                      ),
                      _layerPanel(
                        context,
                        keyStr: 'subs',
                        icon: Icons.subtitles,
                        title: 'Subtitles Layer',
                        enabled: _showSubtitles,
                        onToggle: (v) => setState(() {
                          _showSubtitles = v;
                          if (v) {
                            _startSubtitleTicker();
                          } else {
                            _currentSub = '';
                          }
                        }),
                        child: Row(
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(left: 16),
                              child: Text('Font size'),
                            ),
                            Expanded(
                              child: Slider(
                                value: _subtitleFont,
                                min: 14,
                                max: 36,
                                onChanged: (v) =>
                                    setState(() => _subtitleFont = v),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  // ---------- Panel builder with header toggle ----------
  Widget _layerPanel(
    BuildContext context, {
    required String keyStr,
    required IconData icon,
    required String title,
    required bool enabled,
    required ValueChanged<bool> onToggle,
    required Widget child,
  }) {
    final isExpanded = _expanded[keyStr] ?? false;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            onTap: () => setState(() => _expanded[keyStr] = !isExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(icon),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  Switch(value: enabled, onChanged: onToggle),
                  const SizedBox(width: 6),
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 200),
                    turns: isExpanded ? 0.5 : 0.0,
                    child: const Icon(Icons.expand_more),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: child,
            ),
            crossFadeState: isExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }

  Widget _volumeRow({
    required String label,
    required double value,
    required Future<void> Function(double) onChange,
  }) {
    return Row(
      children: [
        Padding(padding: const EdgeInsets.only(left: 16), child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            min: 0.0,
            max: 1.0,
            onChanged: (v) => onChange(v),
          ),
        ),
      ],
    );
  }
}

/* -------------------------------------------------------------------------- */
/*                                  SRT utils                                 */
/* -------------------------------------------------------------------------- */

class _SrtCue {
  final Duration start;
  final Duration end;
  final String text;
  _SrtCue(this.start, this.end, this.text);
}

List<_SrtCue> _parseSrt(String raw) {
  final lines = raw.replaceAll('\r\n', '\n').split('\n');
  final cues = <_SrtCue>[];
  int i = 0;
  while (i < lines.length) {
    if (lines[i].trim().isEmpty) {
      i++;
      continue;
    }
    if (RegExp(r'^\d+$').hasMatch(lines[i].trim())) i++; // optional index
    if (i >= lines.length) break;

    final timeLine = lines[i++].trim();
    final parts = timeLine.split('-->');
    if (parts.length != 2) continue;
    final start = _parseSrtTime(parts[0].trim());
    final end = _parseSrtTime(parts[1].trim());

    final buf = <String>[];
    while (i < lines.length && lines[i].trim().isNotEmpty) {
      buf.add(lines[i++]);
    }
    final text = buf.join('\n').trim();
    cues.add(_SrtCue(start, end, text));

    while (i < lines.length && lines[i].trim().isEmpty) i++; // skip blank
  }
  return cues;
}

Duration _parseSrtTime(String s) {
  // format: HH:MM:SS,mmm (or .mmm)
  final m = RegExp(r'^(\d\d):(\d\d):(\d\d)[,\.](\d{1,3})$').firstMatch(s);
  if (m == null) return Duration.zero;
  final h = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  final sec = int.parse(m.group(3)!);
  final ms = int.parse(m.group(4)!.padRight(3, '0'));
  return Duration(hours: h, minutes: min, seconds: sec, milliseconds: ms);
}

class _SubtitleBubble extends StatelessWidget {
  final String text;
  final double fontSize;
  const _SubtitleBubble({required this.text, required this.fontSize});
  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: fontSize,
        height: 1.25,
        color: Colors.white,
        shadows: const [
          Shadow(blurRadius: 4, color: Colors.black87, offset: Offset(0, 0)),
          Shadow(blurRadius: 8, color: Colors.black54, offset: Offset(0, 0)),
        ],
      ),
    );
  }
}
