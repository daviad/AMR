import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// 大屏视频播放器（非 Web 端）：video_player 硬解，Android ExoPlayer 支持 HLS。
class DashboardVideoPlayer extends StatefulWidget {
  const DashboardVideoPlayer({super.key, required this.url});

  final String url;

  @override
  State<DashboardVideoPlayer> createState() => _DashboardVideoPlayerState();
}

class _DashboardVideoPlayerState extends State<DashboardVideoPlayer> {
  VideoPlayerController? _controller;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(widget.url),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _controller = controller;
    try {
      await controller.initialize();
      await controller.play();
      controller.setLooping(true);
      if (mounted) setState(() => _initialized = true);
    } catch (e) {
      debugPrint('[DashboardVideo] init error: $e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (!_initialized || controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return AspectRatio(
      aspectRatio: controller.value.aspectRatio,
      child: VideoPlayer(controller),
    );
  }
}
