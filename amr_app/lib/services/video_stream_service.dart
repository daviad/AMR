import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../comm/rosbridge_client.dart';
import '../core/constants.dart';
import '../core/topic_mapping.dart';
import '../providers/comm/rosbridge_provider.dart';

/// 视频源类型
enum VideoSource {
  webrtc,    // WebRTC WHEP（主路径，H.264 硬解）
  rtsp,      // RTSP（video_player 硬解，TCP fallback）
  rosbridge, // rosbridge CompressedImage（JPEG 软解，仅兼容旧链路）
}

/// 画质策略：自动在主/低码流间切换，也可手动锁定。
enum VideoQualityMode { auto, main, low }

/// 视频健康状态：HEALTHY → DEGRADED → LOST，恢复后回到 HEALTHY。
enum VideoHealthState { connecting, healthy, degraded, lost }

extension VideoHealthStateX on VideoHealthState {
  String get label {
    switch (this) {
      case VideoHealthState.connecting:
        return '连接中';
      case VideoHealthState.healthy:
        return 'HEALTHY';
      case VideoHealthState.degraded:
        return 'DEGRADED';
      case VideoHealthState.lost:
        return 'LOST';
    }
  }
}

class VideoHealthSnapshot {
  const VideoHealthSnapshot({
    this.state = VideoHealthState.connecting,
    this.fps = 0,
    this.width = 0,
    this.height = 0,
    this.rttMs,
    this.jitterMs,
    this.decodeP50Ms,
    this.decodeP95Ms,
    this.decodeP99Ms,
    this.framesDecoded = 0,
    this.packetsLost = 0,
    this.freezeCount = 0,
    this.reconnectCount = 0,
    this.lastFrameAt,
    this.path = AppConstants.videoMainPath,
    this.error,
  });

  final VideoHealthState state;
  final double fps;
  final int width;
  final int height;
  final double? rttMs;
  final double? jitterMs;
  final double? decodeP50Ms;
  final double? decodeP95Ms;
  final double? decodeP99Ms;
  final int framesDecoded;
  final int packetsLost;
  final int freezeCount;
  final int reconnectCount;
  final DateTime? lastFrameAt;
  final String path;
  final String? error;

  VideoHealthSnapshot copyWith({
    VideoHealthState? state,
    double? fps,
    int? width,
    int? height,
    double? rttMs,
    double? jitterMs,
    double? decodeP50Ms,
    double? decodeP95Ms,
    double? decodeP99Ms,
    int? framesDecoded,
    int? packetsLost,
    int? freezeCount,
    int? reconnectCount,
    DateTime? lastFrameAt,
    String? path,
    String? error,
    bool clearError = false,
  }) =>
      VideoHealthSnapshot(
        state: state ?? this.state,
        fps: fps ?? this.fps,
        width: width ?? this.width,
        height: height ?? this.height,
        rttMs: rttMs ?? this.rttMs,
        jitterMs: jitterMs ?? this.jitterMs,
        decodeP50Ms: decodeP50Ms ?? this.decodeP50Ms,
        decodeP95Ms: decodeP95Ms ?? this.decodeP95Ms,
        decodeP99Ms: decodeP99Ms ?? this.decodeP99Ms,
        framesDecoded: framesDecoded ?? this.framesDecoded,
        packetsLost: packetsLost ?? this.packetsLost,
        freezeCount: freezeCount ?? this.freezeCount,
        reconnectCount: reconnectCount ?? this.reconnectCount,
        lastFrameAt: lastFrameAt ?? this.lastFrameAt,
        path: path ?? this.path,
        error: clearError ? null : (error ?? this.error),
      );
}

/// 视频流播放器抽象：上层 UI 只依赖本接口。
abstract class VideoStreamPlayer {
  VideoSource get source;

  /// JPEG 帧流（仅 rosbridge 模式有数据）
  Stream<Uint8List>? get frameStream;

  /// RTSP 模式的 video_player 控制器（仅 rtsp 模式非 null）
  VideoPlayerController? get controller;

  /// WebRTC 渲染器（仅 webrtc 模式非 null）
  RTCVideoRenderer? get renderer;

  /// 视频健康状态流（仅 webrtc 模式有数据）
  Stream<VideoHealthSnapshot>? get healthStream;

  VideoHealthSnapshot get health;

  Future<void> start();
  Future<void> stop();
  bool get isRunning;
}

/// rosbridge CompressedImage 实现（JPEG 软解，兼容旧链路）
class RosbridgeCompressedPlayer implements VideoStreamPlayer {
  RosbridgeCompressedPlayer(this._client);

  final RosbridgeClient _client;
  StreamSubscription<Map<String, dynamic>>? _sub;
  final StreamController<Uint8List> _controller =
      StreamController<Uint8List>.broadcast();

  @override
  VideoSource get source => VideoSource.rosbridge;

  @override
  Stream<Uint8List>? get frameStream => _controller.stream;

  @override
  VideoPlayerController? get controller => null;

  @override
  RTCVideoRenderer? get renderer => null;

  @override
  Stream<VideoHealthSnapshot>? get healthStream => null;

  @override
  VideoHealthSnapshot get health =>
      const VideoHealthSnapshot(state: VideoHealthState.healthy);

  @override
  bool get isRunning => _sub != null;

  @override
  Future<void> start() async {
    if (_sub != null) return;
    debugPrint('[Video] start() subscribing to ${TopicMapping.cameraCompressed}');
    _sub = _client
        .subscribe(
          TopicMapping.cameraCompressed,
          type: 'sensor_msgs/CompressedImage',
          queueLength: 1,
        )
        .listen((msg) {
      final data = msg['data'];
      if (data is String && !_controller.isClosed) {
        try {
          final bytes = base64Decode(data);
          _controller.add(bytes);
        } catch (e) {
          debugPrint('[Video] decode error: $e');
        }
      }
    }, onError: (e) => debugPrint('[Video] subscribe stream error: $e'));
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }
}

/// RTSP H.264 实现（video_player 硬解，TCP）
class RtspVideoPlayer implements VideoStreamPlayer {
  RtspVideoPlayer(this._rtspUrl);

  final String _rtspUrl;
  VideoPlayerController? _controller;

  @override
  VideoSource get source => VideoSource.rtsp;

  @override
  Stream<Uint8List>? get frameStream => null;

  @override
  VideoPlayerController? get controller => _controller;

  @override
  RTCVideoRenderer? get renderer => null;

  @override
  Stream<VideoHealthSnapshot>? get healthStream => null;

  @override
  VideoHealthSnapshot get health =>
      const VideoHealthSnapshot(state: VideoHealthState.healthy);

  @override
  bool get isRunning => _controller != null && _controller!.value.isPlaying;

  @override
  Future<void> start() async {
    if (_controller != null) return;
    debugPrint('[Video] start() RTSP $_rtspUrl');
    _controller = VideoPlayerController.networkUrl(
      Uri.parse(_rtspUrl),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    await _controller!.initialize();
    await _controller!.play();
    _controller!.setLooping(true);
  }

  @override
  Future<void> stop() async {
    await _controller?.pause();
    await _controller?.dispose();
    _controller = null;
  }
}

/// WebRTC WHEP 播放器 + 视频健康监测。
///
/// 链路：MediaMTX WHEP(:8889) → RTCVideoRenderer。
/// 健康判定基于 getStats：帧数增量、freezeCount、packetsLost、jitter、
/// 解码耗时与 RTT；LOST 后指数退避重建 PeerConnection。
class WebRtcWhepPlayer implements VideoStreamPlayer {
  WebRtcWhepPlayer({required this.path});

  final String path;
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  bool _rendererReady = false;

  RTCPeerConnection? _pc;
  StreamSubscription? _pcStateSub;
  Timer? _statsTimer;
  Timer? _reconnectTimer;
  bool _running = false;
  bool _connecting = false;
  int _reconnectAttempt = 0;
  String? _location;
  String? _lastError;

  final StreamController<VideoHealthSnapshot> _healthController =
      StreamController<VideoHealthSnapshot>.broadcast();
  VideoHealthSnapshot _health = const VideoHealthSnapshot();

  // stats 基线
  int _lastFrames = 0;
  int _lastFreeze = 0;
  int _lastLost = 0;
  double _lastDecodeTime = 0;
  DateTime? _lastStatsAt;
  DateTime? _lastFrameAt;
  int _lastFrameWidth = 0;
  int _lastFrameHeight = 0;
  int _stalledPolls = 0;
  int _lostPolls = 0;
  final List<double> _decodeSamples = [];

  @override
  VideoSource get source => VideoSource.webrtc;

  @override
  Stream<Uint8List>? get frameStream => null;

  @override
  VideoPlayerController? get controller => null;

  @override
  RTCVideoRenderer get renderer => _renderer;

  @override
  Stream<VideoHealthSnapshot>? get healthStream => _healthController.stream;

  @override
  VideoHealthSnapshot get health => _health;

  @override
  bool get isRunning => _running;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _emit(VideoHealthSnapshot(
      state: VideoHealthState.connecting,
      path: path,
    ));
    if (!_rendererReady) {
      await _renderer.initialize();
      _rendererReady = true;
    }
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _pollStats());
    await _connect();
  }

  Future<void> _connect() async {
    if (!_running || _connecting) return;
    _connecting = true;
    _emit(_health.copyWith(
      state: VideoHealthState.connecting,
      path: path,
      clearError: true,
    ));
    try {
      final pc = await createPeerConnection({
        'iceServers': [],
        'sdpSemantics': 'unified-plan',
      });
      _pc = pc;

      pc.onTrack = (RTCTrackEvent event) {
        if (event.track.kind == 'video' && event.streams.isNotEmpty) {
          _renderer.srcObject = event.streams[0];
          _lastFrameAt = DateTime.now();
        }
      };
      pc.onConnectionState = (RTCPeerConnectionState state) {
        debugPrint('[Video] peer state: $state');
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state ==
                RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          _markLost('peer $state');
          _scheduleReconnect();
        }
      };
      pc.onIceConnectionState = (RTCIceConnectionState state) {
        if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          _markLost('ice failed');
          _scheduleReconnect();
        }
      };

      // unified-plan 下 flutter_webrtc 的 Android 实现完全不读 constraints
      //（MethodCallHandlerImpl.peerConnectionCreateOffer 直接忽略该 Map），
      // 不显式加 transceiver 时 createOffer 生成的 SDP 里没有 m=video，
      // 也就没有 a=ice-ufrag，MediaMTX 会回 400
      // "SetRemoteDescription called with no ice-ufrag"。
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);

      final url = Uri.parse(AppConstants.whepUrl(path));
      final response = await http
          .post(
            url,
            headers: const {
              'Content-Type': 'application/sdp',
              'Accept': 'application/sdp',
            },
            body: offer.sdp,
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw 'WHEP ${response.statusCode}: ${response.body}';
      }
      _location = response.headers['location'];
      final answer = response.body;
      if (answer.trim().isEmpty) throw 'WHEP 空 SDP';
      await pc.setRemoteDescription(
        RTCSessionDescription(answer, 'answer'),
      );
      debugPrint('[Video] WHEP OK ${AppConstants.whepUrl(path)}');
      _emit(_health.copyWith(
        state: VideoHealthState.connecting,
        path: path,
        clearError: true,
      ));
    } catch (e) {
      _lastError = '$e';
      debugPrint('[Video] WHEP failed: $e');
      await _teardownPc();
      _emit(_health.copyWith(
        state: VideoHealthState.lost,
        error: _lastError,
        path: path,
      ));
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  Future<void> _pollStats() async {
    final pc = _pc;
    if (!_running || pc == null) return;
    try {
      final reports = await pc.getStats();
      final now = DateTime.now();
      Map<dynamic, dynamic>? inbound;
      for (final r in reports) {
        if (r.type == 'inbound-rtp') {
          final kind = r.values['kind'] ?? r.values['mediaType'];
          if (kind == 'video') {
            inbound = r.values;
            break;
          }
        }
      }
      double? rttMs;
      for (final r in reports) {
        if (r.type == 'candidate-pair' &&
            (r.values['selected'] == true || r.values['nominated'] == true)) {
          final rtt = _num(r.values['currentRoundTripTime']);
          if (rtt != null) rttMs = rtt * 1000.0;
        }
      }
      if (inbound == null) {
        _stalledPolls++;
        if (_stalledPolls >= 3) _markLost('无 inbound-rtp 统计');
        return;
      }
      final frames = (_num(inbound['framesDecoded']) ?? 0).toInt();
      final freeze = (_num(inbound['freezeCount']) ?? 0).toInt();
      final lost = (_num(inbound['packetsLost']) ?? 0).toInt();
      final jitter = (_num(inbound['jitter']) ?? 0) * 1000.0;
      final decodeTotal = _num(inbound['totalDecodeTime']) ?? 0;
      final width = (_num(inbound['frameWidth']) ?? 0).toInt();
      final height = (_num(inbound['frameHeight']) ?? 0).toInt();

      final previousAt = _lastStatsAt;
      _lastStatsAt = now;
      final elapsed = previousAt == null
          ? 1.0
          : now.difference(previousAt).inMilliseconds / 1000.0;
      final frameDelta = frames - _lastFrames;
      final lostDelta = lost - _lastLost;
      final freezeDelta = freeze - _lastFreeze;
      final fps = elapsed > 0 ? frameDelta / elapsed : 0.0;
      if (frameDelta > 0) {
        _lastFrameAt = now;
        _lastFrameWidth = width;
        _lastFrameHeight = height;
        _lostPolls = 0;
        _stalledPolls = 0;
        _reconnectAttempt = 0;
      }
      final decodeDelta = decodeTotal - _lastDecodeTime;
      if (frameDelta > 0 && decodeDelta > 0) {
        _decodeSamples.add(decodeDelta / frameDelta * 1000.0);
        if (_decodeSamples.length > 120) _decodeSamples.removeAt(0);
      }
      _lastFrames = frames;
      _lastLost = lost;
      _lastFreeze = freeze;
      _lastDecodeTime = decodeTotal;

      final healthState = _deriveState(
        frameDelta: frameDelta,
        fps: fps,
        jitterMs: jitter,
        lostDelta: lostDelta,
        freezeDelta: freezeDelta,
        now: now,
      );
      if (healthState == VideoHealthState.lost) {
        _lostPolls++;
      } else {
        _lostPolls = 0;
      }
      if (healthState == VideoHealthState.lost && _lostPolls >= 3) {
        _scheduleReconnect();
      }
      final samples = List<double>.from(_decodeSamples)..sort();
      _emit(VideoHealthSnapshot(
        state: healthState,
        fps: fps,
        width: _lastFrameWidth,
        height: _lastFrameHeight,
        rttMs: rttMs,
        jitterMs: jitter,
        decodeP50Ms: _percentile(samples, 0.50),
        decodeP95Ms: _percentile(samples, 0.95),
        decodeP99Ms: _percentile(samples, 0.99),
        framesDecoded: frames,
        packetsLost: lost,
        freezeCount: freeze,
        reconnectCount: _reconnectAttempt,
        lastFrameAt: _lastFrameAt,
        path: path,
        error: _lastError,
      ));
    } catch (e) {
      debugPrint('[Video] getStats error: $e');
    }
  }

  VideoHealthState _deriveState({
    required int frameDelta,
    required double fps,
    required double jitterMs,
    required int lostDelta,
    required int freezeDelta,
    required DateTime now,
  }) {
    final last = _lastFrameAt;
    if (last == null || now.difference(last).inSeconds >= 3) {
      return VideoHealthState.lost;
    }
    if (frameDelta == 0) return VideoHealthState.degraded;
    if (fps < 2.5 ||
        jitterMs > 200 ||
        lostDelta > 5 ||
        freezeDelta > 0) {
      return VideoHealthState.degraded;
    }
    return VideoHealthState.healthy;
  }

  void _markLost(String reason) {
    if (!_running) return;
    _lastError = reason;
    _emit(_health.copyWith(
      state: VideoHealthState.lost,
      error: reason,
      path: path,
    ));
  }

  void _scheduleReconnect() {
    if (!_running || _reconnectTimer != null) return;
    _reconnectAttempt++;
    final seconds = math.min(10, 1 << math.min(_reconnectAttempt, 3));
    debugPrint('[Video] reconnect in ${seconds}s (attempt $_reconnectAttempt)');
    _reconnectTimer = Timer(Duration(seconds: seconds), () async {
      _reconnectTimer = null;
      if (!_running) return;
      await _teardownPc();
      await _connect();
    });
  }

  Future<void> _teardownPc() async {
    await _pcStateSub?.cancel();
    _pcStateSub = null;
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    await _renderer.srcObject?.dispose();
    _renderer.srcObject = null;
  }

  void _emit(VideoHealthSnapshot snapshot) {
    _health = snapshot;
    if (!_healthController.isClosed) {
      _healthController.add(snapshot);
    }
  }

  double? _percentile(List<double> sorted, double ratio) {
    if (sorted.isEmpty) return null;
    final idx = ((sorted.length - 1) * ratio).round();
    return double.parse(sorted[idx].toStringAsFixed(2));
  }

  double? _num(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  @override
  Future<void> stop() async {
    _running = false;
    _statsTimer?.cancel();
    _statsTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final location = _location;
    if (location != null) {
      try {
        final base = Uri.parse(AppConstants.whepUrl(path));
        await http.delete(base.resolve(location)).timeout(
              const Duration(seconds: 3),
            );
      } catch (_) {}
    }
    _location = null;
    await _teardownPc();
    if (_rendererReady) {
      await _renderer.dispose();
      _rendererReady = false;
    }
    await _healthController.close();
  }
}

/// 视频管理器快照：不可变，UI 只按值渲染。
@immutable
class VideoManagerState {
  const VideoManagerState({
    this.player,
    this.currentSource = VideoSource.webrtc,
    this.qualityMode = VideoQualityMode.auto,
    this.isLowQuality = false,
    this.health = const VideoHealthSnapshot(),
  });

  final VideoStreamPlayer? player;
  final VideoSource currentSource;
  final VideoQualityMode qualityMode;
  final bool isLowQuality;
  final VideoHealthSnapshot health;
}

/// 视频流播放器管理器：支持 WebRTC / RTSP / rosbridge 动态切换。
class VideoStreamManager extends Notifier<VideoManagerState> {
  VideoStreamPlayer? _player;
  VideoSource _currentSource = VideoSource.webrtc;
  VideoQualityMode _qualityMode = VideoQualityMode.auto;
  bool _lowQuality = false;
  bool _qualitySwitching = false;
  DateTime? _lastQualitySwitchAt;
  VideoHealthSnapshot _health = const VideoHealthSnapshot();
  StreamSubscription<VideoHealthSnapshot>? _healthSub;
  int _degradedStreak = 0;
  int _healthyStreak = 0;
  bool _initialized = false;

  @override
  VideoManagerState build() {
    ref.onDispose(_dispose);
    return const VideoManagerState();
  }

  void _emit() {
    state = VideoManagerState(
      player: _player,
      currentSource: _currentSource,
      qualityMode: _qualityMode,
      isLowQuality: _lowQuality,
      health: _health,
    );
  }

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('video_source');
    if (saved == 'rtsp') {
      _currentSource = VideoSource.rtsp;
    } else if (saved == 'rosbridge') {
      _currentSource = VideoSource.rosbridge;
    } else {
      _currentSource = VideoSource.webrtc;
    }
    final savedQuality = prefs.getString('video_quality');
    if (savedQuality == 'low') {
      _qualityMode = VideoQualityMode.low;
      _lowQuality = true;
    } else if (savedQuality == 'main') {
      _qualityMode = VideoQualityMode.main;
    }
    await _createPlayer();
    _emit();
  }

  Future<void> switchSource(VideoSource source) async {
    if (_currentSource == source && _player != null) return;
    debugPrint('[Video] switching from $_currentSource to $source');
    await _healthSub?.cancel();
    _healthSub = null;
    await _player?.stop();
    _player = null;
    _currentSource = source;
    _health = const VideoHealthSnapshot();
    // 先通知：UI 立即切换到新源的占位视图，避免使用已 dispose 的旧播放器
    _emit();
    await _createPlayer();
    // 再通知：新播放器就绪（WebRTC renderer / RTSP initialize 完成）
    _emit();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('video_source', source.name);
  }

  /// 手动设置画质策略。auto 时由健康状态自动切换。
  Future<void> setQualityMode(VideoQualityMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('video_quality', mode.name);
    _qualityMode = mode;
    if (mode == VideoQualityMode.auto) {
      // 从低码流开始观察，恢复后自动升回主码流
      if (_lowQuality) await _restartForQuality(false);
    } else {
      final wantLow = mode == VideoQualityMode.low;
      if (wantLow != _lowQuality) await _restartForQuality(wantLow);
    }
    _emit();
  }

  Future<void> _restartForQuality(bool low) async {
    if (_qualitySwitching || _currentSource != VideoSource.webrtc) return;
    _qualitySwitching = true;
    try {
      _lowQuality = low;
      _lastQualitySwitchAt = DateTime.now();
      debugPrint('[Video] quality -> ${low ? 'low' : 'main'}');
      await _healthSub?.cancel();
      _healthSub = null;
      await _player?.stop();
      _player = null;
      _health = const VideoHealthSnapshot();
      _emit();
      await _createPlayer();
      _emit();
    } finally {
      _qualitySwitching = false;
    }
  }

  Future<void> _createPlayer() async {
    switch (_currentSource) {
      case VideoSource.webrtc:
        final path = _lowQuality
            ? AppConstants.videoLowPath
            : AppConstants.videoMainPath;
        _player = WebRtcWhepPlayer(path: path);
        _healthSub = _player!.healthStream?.listen(_onHealth);
        break;
      case VideoSource.rtsp:
        final path = _lowQuality
            ? AppConstants.videoLowPath
            : AppConstants.videoMainPath;
        _player = RtspVideoPlayer(AppConstants.rtspUrl(path));
        break;
      case VideoSource.rosbridge:
        _player = RosbridgeCompressedPlayer(
            ref.read(rosbridgeClientProvider));
        break;
    }
    await _player!.start();
    _health = _player!.health;
  }

  void _onHealth(VideoHealthSnapshot snapshot) {
    _health = snapshot;
    if (_currentSource == VideoSource.webrtc) {
      _evaluateAutoQuality(snapshot);
    }
    _emit();
  }

  void _evaluateAutoQuality(VideoHealthSnapshot snapshot) {
    if (_qualityMode != VideoQualityMode.auto || _qualitySwitching) return;
    final now = DateTime.now();
    final lastSwitch = _lastQualitySwitchAt;
    if (lastSwitch != null && now.difference(lastSwitch).inSeconds < 10) {
      return;
    }
    if (snapshot.state == VideoHealthState.degraded) {
      _degradedStreak++;
      _healthyStreak = 0;
    } else if (snapshot.state == VideoHealthState.lost) {
      _degradedStreak += 2;
      _healthyStreak = 0;
    } else if (snapshot.state == VideoHealthState.healthy) {
      _healthyStreak++;
      _degradedStreak = 0;
    }
    if (!_lowQuality && _degradedStreak >= 2) {
      _degradedStreak = 0;
      scheduleMicrotask(() => _restartForQuality(true));
    } else if (_lowQuality && _healthyStreak >= 4) {
      _healthyStreak = 0;
      scheduleMicrotask(() => _restartForQuality(false));
    }
  }

  void _dispose() {
    _healthSub?.cancel();
    _player?.stop();
    _player = null;
  }
}

/// 视频流管理器 Provider
final videoStreamManagerProvider =
    NotifierProvider<VideoStreamManager, VideoManagerState>(
        VideoStreamManager.new);

/// 便捷 Provider：当前播放器（供 UI 监听重建）
final videoStreamPlayerProvider = Provider<VideoStreamPlayer?>((ref) {
  return ref.watch(videoStreamManagerProvider).player;
});

/// 便捷 Provider：当前视频源
final videoSourceProvider = Provider<VideoSource>((ref) {
  return ref.watch(videoStreamManagerProvider).currentSource;
});

/// 便捷 Provider：视频健康快照
final videoHealthProvider = Provider<VideoHealthSnapshot>((ref) {
  return ref.watch(videoStreamManagerProvider).health;
});
