import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:hive_flutter/hive_flutter.dart';

import 'app.dart';
import 'models/inspection_point.dart';
import 'models/inspection_route.dart';
import 'providers/inspection/points_controller.dart';
import 'providers/inspection/route_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // fvp：注册 MDK 后端，使 video_player 支持 RTSP 并走硬件解码（Web 端除外）
  // adb reverse 只转发 TCP，RTSP 必须强制 TCP interleaved 传输；lowLatency 2 适配直播流
  if (!kIsWeb) {
    fvp.registerWith(options: {
      'lowLatency': 2,
      'player': {
        'avformat.rtsp_transport': 'tcp',
        'avformat.stimeout': '5000000',
      },
    });
  }

  // Hive 初始化 + adapter 注册 + 开 Box
  await Hive.initFlutter();
  Hive.registerAdapter(InspectionPointAdapter());
  Hive.registerAdapter(InspectionRouteAdapter());
  final pointsBox = await Hive.openBox<InspectionPoint>('inspection_points');
  final routesBox = await Hive.openBox<InspectionRoute>('inspection_routes');

  // 横屏优先
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  runApp(
    ProviderScope(
      overrides: [
        inspectionPointsBoxProvider.overrideWithValue(pointsBox),
        inspectionRoutesBoxProvider.overrideWithValue(routesBox),
      ],
      child: const AmrApp(),
    ),
  );
}
