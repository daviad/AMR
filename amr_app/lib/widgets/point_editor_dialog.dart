import 'dart:math';

import 'package:flutter/material.dart';

import '../models/inspection_point.dart';

/// 巡检点新建/编辑对话框。
/// [initial] 非空为编辑，[world] 为新建时的世界坐标。
/// 返回配置完成的巡检点，取消返回 null。
Future<InspectionPoint?> showPointEditorDialog(
  BuildContext context, {
  InspectionPoint? initial,
  Offset? world,
}) {
  final nameController =
      TextEditingController(text: initial?.name ?? '');
  var theta = initial?.theta ?? 0.0;
  var dwellTime = initial?.dwellTime ?? 3;
  var capturePhoto = initial?.capturePhoto ?? false;
  final baseX = initial?.x ?? world?.dx ?? 0.0;
  final baseY = initial?.y ?? world?.dy ?? 0.0;

  return showDialog<InspectionPoint>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(initial == null ? '新建巡检点' : '编辑巡检点'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              const SizedBox(height: 8),
              Text('位置: (${baseX.toStringAsFixed(2)}, '
                  '${baseY.toStringAsFixed(2)})'),
              Row(
                children: [
                  const Text('朝向'),
                  Expanded(
                    child: Slider(
                      value: theta,
                      min: -pi,
                      max: pi,
                      onChanged: (v) => setState(() => theta = v),
                    ),
                  ),
                  Text('${(theta * 180 / pi).round()}°'),
                ],
              ),
              Row(
                children: [
                  const Text('停留'),
                  Expanded(
                    child: Slider(
                      value: dwellTime.toDouble(),
                      min: 0,
                      max: 60,
                      divisions: 60,
                      onChanged: (v) =>
                          setState(() => dwellTime = v.round()),
                    ),
                  ),
                  Text('${dwellTime}s'),
                ],
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('到达后拍照'),
                value: capturePhoto,
                onChanged: (v) => setState(() => capturePhoto = v),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final name = nameController.text.trim().isEmpty
                  ? '点${DateTime.now().millisecondsSinceEpoch % 10000}'
                  : nameController.text.trim();
              Navigator.of(context).pop(InspectionPoint(
                id: initial?.id ??
                    'p_${DateTime.now().millisecondsSinceEpoch}',
                name: name,
                x: baseX,
                y: baseY,
                theta: theta,
                dwellTime: dwellTime,
                capturePhoto: capturePhoto,
              ));
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
}
