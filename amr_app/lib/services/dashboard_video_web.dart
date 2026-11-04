// Web 端大屏视频：通过 HtmlElementView 插入 <video data-hls=...>，
// 由 web/index.html 中的 hls.js 胶水脚本自动绑定播放（Chrome/Edge 无原生 HLS）。
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
// ignore: undefined_prefixed_name
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

/// 大屏视频播放器（Web 端）。
class DashboardVideoPlayer extends StatefulWidget {
  const DashboardVideoPlayer({super.key, required this.url});

  final String url;

  @override
  State<DashboardVideoPlayer> createState() => _DashboardVideoPlayerState();
}

class _DashboardVideoPlayerState extends State<DashboardVideoPlayer> {
  static final Set<String> _registered = {};
  late final String _viewType = 'hls-video-${widget.url.hashCode}';

  @override
  void initState() {
    super.initState();
    if (_registered.add(_viewType)) {
      ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
        return html.VideoElement()
          ..dataset['hls'] = widget.url
          ..autoplay = true
          ..muted = true
          ..controls = true
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.objectFit = 'contain'
          ..style.backgroundColor = '#000';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }
}
