import 'package:flutter/material.dart';

import 'pages/camera_page.dart';
import 'pages/dashboard_page.dart';
import 'pages/inspection_page.dart';
import 'pages/map_page.dart';

/// 应用根 Widget：主题 + 路由。
class AmrApp extends StatelessWidget {
  const AmrApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AMR 巡检',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      initialRoute: '/',
      routes: {
        '/': (_) => const MapPage(),
        '/inspection': (_) => const InspectionPage(),
        '/camera': (_) => const CameraPage(),
        '/dashboard': (_) => const DashboardPage(),
      },
    );
  }
}
