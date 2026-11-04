import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:video_player/video_player.dart';

import '../providers/comm/mqtt_provider.dart';
import '../providers/comm/rosbridge_provider.dart';
import '../services/capture_saver_io.dart'
    if (dart.library.html) '../services/capture_saver_web.dart';
import '../services/photo_capture_service.dart';
import '../services/video_stream_service.dart';

/// 视频预览页：
///   - 默认 WebRTC（MediaMTX WHEP）低延迟预览；
///   - 健康状态 HEALTHY / DEGRADED / LOST，自动主/低码流降级；
///   - 拍照走 CompressedImage 单帧（与视频链路解耦）。
class CameraPage extends ConsumerStatefulWidget {
  const CameraPage({super.key});

  @override
  ConsumerState<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends ConsumerState<CameraPage> {
  bool _initialized = false;
  bool _capturing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(videoStreamManagerProvider).init();
      if (mounted) setState(() => _initialized = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final manager = ref.watch(videoStreamManagerProvider);
    final player = manager.player;
    final health = manager.health;
    final source = manager.currentSource;
    final mqttConnected =
        ref.watch(mqttConnectionProvider).valueOrNull ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('摄像头'),
        actions: [
          // 画质策略
          PopupMenuButton<VideoQualityMode>(
            tooltip: '画质策略',
            icon: const Icon(Icons.tune),
            initialValue: manager.qualityMode,
            onSelected: (mode) =>
                ref.read(videoStreamManagerProvider).setQualityMode(mode),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: VideoQualityMode.auto,
                child: Text('自动（弱网切低码流）'),
              ),
              PopupMenuItem(
                value: VideoQualityMode.main,
                child: Text('主码流 320×240'),
              ),
              PopupMenuItem(
                value: VideoQualityMode.low,
                child: Text('低码流 160×120'),
              ),
            ],
          ),
          // 视频源
          PopupMenuButton<VideoSource>(
            tooltip: '视频源',
            icon: const Icon(Icons.settings_input_antenna),
            initialValue: source,
            onSelected: (s) =>
                ref.read(videoStreamManagerProvider).switchSource(s),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: VideoSource.webrtc,
                child: Text('WebRTC（低延迟，默认）'),
              ),
              PopupMenuItem(
                value: VideoSource.rtsp,
                child: Text('RTSP（TCP 兼容）'),
              ),
              PopupMenuItem(
                value: VideoSource.rosbridge,
                child: Text('rosbridge JPEG（旧链路）'),
              ),
            ],
          ),
          IconButton(
            icon: _capturing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.camera_alt),
            tooltip: '拍照（CompressedImage 单帧）',
            onPressed: _capturing ? null : _capturePhoto,
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: _buildVideo(source, player)),
          Positioned(
            left: 8,
            top: 8,
            right: 8,
            child: _healthBar(health, mqttConnected),
          ),
          if (health.state == VideoHealthState.lost)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: _lostBanner(health, mqttConnected),
            ),
        ],
      ),
    );
  }

  Widget _buildVideo(VideoSource source, VideoStreamPlayer? player) {
    if (player == null) {
      return const Center(child: CircularProgressIndicator());
    }
    switch (source) {
      case VideoSource.webrtc:
        final renderer = player.renderer;
        if (renderer == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return Center(
          child: RTCVideoView(
            renderer,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
            mirror: false,
          ),
        );
      case VideoSource.rtsp:
        final controller = player.controller;
        if (controller == null || !controller.value.isInitialized) {
          return const Center(child: CircularProgressIndicator());
        }
        return Center(
          child: AspectRatio(
            aspectRatio: controller.value.aspectRatio,
            child: VideoPlayer(controller),
          ),
        );
      case VideoSource.rosbridge:
        final frames = player.frameStream;
        if (frames == null) {
          return const Center(child: Text('rosbridge 模式无帧流'));
        }
        return StreamBuilder<Uint8List>(
          stream: frames,
          builder: (context, snapshot) {
            final frame = snapshot.data;
            if (frame == null) {
              return const Center(child: Text('等待 JPEG 帧…'));
            }
            return Center(
              child: Image.memory(
                frame,
                gaplessPlayback: true,
                fit: BoxFit.contain,
              ),
            );
          },
        );
    }
  }

  Widget _healthBar(VideoHealthSnapshot h, bool mqttConnected) {
    final color = _healthColor(h.state);
    final stats = <String>[
      if (h.fps > 0) '${h.fps.toStringAsFixed(1)} fps',
      if (h.width > 0) '${h.width}×${h.height}',
      if (h.rttMs != null) 'RTT ${h.rttMs!.toStringAsFixed(0)} ms',
      if (h.jitterMs != null)
        'jitter ${h.jitterMs!.toStringAsFixed(0)} ms',
      if (h.decodeP95Ms != null)
        'decode P50/P95 ${h.decodeP50Ms?.toStringAsFixed(0)}/'
            '${h.decodeP95Ms!.toStringAsFixed(0)} ms',
      if (h.reconnectCount > 0) '重连 ${h.reconnectCount} 次',
    ];
    return Card(
      color: Colors.black.withValues(alpha: 0.62),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              '视频 ${h.state.label}',
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                stats.join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ),
            Text(
              mqttConnected ? '控制面在线' : '控制面离线',
              style: TextStyle(
                fontSize: 11,
                color: mqttConnected ? Colors.greenAccent : Colors.redAccent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lostBanner(VideoHealthSnapshot h, bool mqttConnected) {
    final last = h.lastFrameAt;
    final lastText = last == null
        ? '从未收到画面'
        : '最后帧 ${last.toLocal().toString().substring(11, 19)}'
            '（${DateTime.now().difference(last).inSeconds}s 前）';
    return Card(
      color: Colors.red.withValues(alpha: 0.85),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '视频中断，正在重连…',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              '$lastText · 控制通道${mqttConnected ? '仍可用' : '不可用'}',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
            if (h.error != null)
              Text(
                h.error!,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
          ],
        ),
      ),
    );
  }

  Color _healthColor(VideoHealthState state) {
    switch (state) {
      case VideoHealthState.healthy:
        return Colors.greenAccent;
      case VideoHealthState.degraded:
        return Colors.orangeAccent;
      case VideoHealthState.lost:
        return Colors.redAccent;
      case VideoHealthState.connecting:
        return Colors.blueAccent;
    }
  }

  Future<void> _capturePhoto() async {
    if (_capturing) return;
    setState(() => _capturing = true);
    try {
      final bytes = await PhotoCaptureService(
        ref.read(rosbridgeClientProvider),
      ).captureJpeg();
      final msg = await saveCapture(bytes);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    } on TimeoutException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('拍照超时：/camera/image_raw/compressed 无数据')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('拍照失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }
}
