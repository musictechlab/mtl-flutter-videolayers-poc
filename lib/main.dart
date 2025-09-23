import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'cast_session.dart';
import 'host_link.dart';
import 'airplay_route_picker.dart';

// import 'mixed_player_view.dart'

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LayersApp());
}

class LayersApp extends StatelessWidget {
  const LayersApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MTL Flutter Video Layers POC',
      theme: ThemeData.dark(useMaterial3: true),
      home: const LayersHome(),
      debugShowCheckedModeBanner: false,
    );
  }
}

final hostLink = HostLink();

// ---------- QR scanner screen ----------
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

class LayersHome extends StatefulWidget {
  const LayersHome({super.key});
  @override
  State<LayersHome> createState() => _LayersHomeState();
}

class _LayersHomeState extends State<LayersHome> {
  // --- MEDIA SOURCES ---
  static const baseUrl =
      'https://ambistream.musictechlab.io/media/videos/AI_Video_Showcase.mp4';
  static const overlayUrl =
      'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4';
  static const extraAudioUrl =
      'https://onlinetestcase.com/wp-content/uploads/2023/06/1-MB-MP3.mp3';

  // Subtitles: set one (leave the other empty)
  static const srtNetworkUrl = ''; // e.g. 'https://.../captions.srt'
  static const srtAssetPath = 'assets/subs/sample.srt';

  // --- controllers ---
  late final VideoPlayerController _baseVideo;
  late final VideoPlayerController _overlayVideo;
  late final CastSession _cast; // add this

  final AudioPlayer _extraAudio = AudioPlayer();

  // --- layer visibility / state ---
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

  // --- subtitles ---
  List<_SrtCue> _cues = [];
  String _currentSub = '';
  Timer? _subTicker;

  // --- sync helpers ---
  Timer? _resyncTimer;

  // --- timeline / scrubbing ---
  bool _isScrubbing = false;
  Duration _scrubTarget = Duration.zero;

  // Panel expansion state (all closed by default)
  final _expanded = <String, bool>{
    'cast': false,
    'base': false,
    'overlay': false,
    'image': false,
    'audio': false,
    'subs': false,
  };

  @override
  void initState() {
    super.initState();
    _cast = CastSession(hostLink); // hostLink is your existing global/singleton
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
      /// Configure audio session to MIX with the video player's audio
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

      // Make sure the session is active so just_audio keeps playing
      await session.setActive(true);

      // (Optional) resume extra audio after interruptions
      session.interruptionEventStream.listen((event) async {
        if (event.begin) {
          if (_useExtraAudio) await _extraAudio.pause();
        } else {
          if (_useExtraAudio && _baseVideo.value.isPlaying) {
            await _extraAudio.play();
          }
        }
      });

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

      // If audio toggle already on
      if (_useExtraAudio) {
        await _extraAudio.seek(_baseVideo.value.position);
        await _extraAudio.play();
      }

      _wireErrorListeners();

      // Coarse resync extra audio to base
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

      // If we are connected to a Host, send LOAD so the host mirrors the same assets
      if (hostLink.isConnected) {
        hostLink.sendLoad(
          bgUrl: baseUrl,
          fgUrl: overlayUrl,
          extraAudioUrl: _useExtraAudio ? extraAudioUrl : null,
          opacity: _overlayOpacity,
        );
      }
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
    // Stop any ongoing cast session.
    _cast.stop();
    _baseVideo.dispose();
    _overlayVideo.dispose();
    _extraAudio.dispose();
    super.dispose();
  }

  Future<void> _togglePlayPause() async {
    final isPlaying = _baseVideo.value.isPlaying;
    if (isPlaying) {
      final pauseAt = _baseVideo.value.position.inMilliseconds;
      await _baseVideo.pause();
      await _overlayVideo.pause();
      if (_useExtraAudio) await _extraAudio.pause();
      if (hostLink.isConnected) hostLink.sendPauseAt(pauseAt);
    } else {
      final pos = _baseVideo.value.position;
      await _overlayVideo.seekTo(pos);
      if (_useExtraAudio) await _extraAudio.seek(pos);
      await _baseVideo.play();
      await _overlayVideo.play();
      if (_useExtraAudio) await _extraAudio.play();
      if (hostLink.isConnected) {
        hostLink.sendPlay(pos.inMilliseconds, rate: 1.0);
      }
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
    // Re-send LOAD so host knows extraAudio changed
    if (hostLink.isConnected) {
      hostLink.sendLoad(
        bgUrl: baseUrl,
        fgUrl: overlayUrl,
        extraAudioUrl: _useExtraAudio ? extraAudioUrl : null,
        opacity: _overlayOpacity,
      );
    }
    setState(() {});
  }

  // Start/stop WebRTC casting of the mixed output
  Future<void> _toggleCast(bool on) async {
    if (on) {
      if (!hostLink.isConnected) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Connect to a Host first to cast')),
        );
        return;
      }
      try {
        await _cast.start();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Cast start failed: $e')));
      }
    } else {
      try {
        await _cast.stop();
      } catch (_) {}
    }
    if (mounted) setState(() {});
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

    if (hostLink.isConnected) {
      hostLink.sendSeek(to.inMilliseconds);
    }

    if (wasPlaying) {
      await _baseVideo.play();
      await _overlayVideo.play();
      if (_useExtraAudio) await _extraAudio.play();
      if (hostLink.isConnected) {
        hostLink.sendPlay(to.inMilliseconds, rate: 1.0);
      }
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
      await hostLink.connectFromPairUri(scanned);

      // After connecting, tell host what to load so we mirror content.
      if (_ready) {
        hostLink.sendLoad(
          bgUrl: baseUrl,
          fgUrl: overlayUrl,
          extraAudioUrl: _useExtraAudio ? extraAudioUrl : null,
          opacity: _overlayOpacity,
        );
        // If already playing, nudge host to same point
        final posMs = _baseVideo.value.position.inMilliseconds;
        if (_baseVideo.value.isPlaying) {
          hostLink.sendPlay(posMs, rate: 1.0);
        } else {
          hostLink.sendPauseAt(posMs);
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connected to Ambistream Host')),
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
          // Scan Host button
          IconButton(
            tooltip: hostLink.isConnected
                ? 'Connected'
                : 'Scan host to connect',
            onPressed: _scanAndConnectHost,
            icon: Icon(
              hostLink.isConnected ? Icons.link : Icons.qr_code_scanner,
            ),
          ),
          const SizedBox(width: 6),
          const AirPlayRoutePicker(size: 26),
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
                                  bottom: 12, // closer to timeline now
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
                      // Casting panel (new)
                      _layerPanel(
                        context,
                        keyStr: 'cast',
                        icon: Icons.cast_rounded,
                        title: 'Cast Mixed Output',
                        enabled: _cast.isActive,
                        onToggle: (v) => _toggleCast(v),
                        child: Padding(
                          padding: const EdgeInsets.only(left: 16, right: 16),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              hostLink.isConnected
                                  ? (_cast.isActive
                                        ? 'Casting to host…'
                                        : 'Tap the switch to start casting the mixed video to the host.')
                                  : 'Connect to a host first, then enable casting.',
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ),
                        ),
                      ),

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
                                      if (hostLink.isConnected) {
                                        hostLink.sendOpacity(v);
                                      }
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
      margin: const EdgeInsets.symmetric(vertical: 1),
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
      child: Column(
        children: [
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
            onTap: () => setState(() => _expanded[keyStr] = !isExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
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

// ----------------- SRT utils -----------------

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
