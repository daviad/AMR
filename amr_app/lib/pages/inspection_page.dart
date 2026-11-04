import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/inspection_route.dart';
import '../providers/data/inspection_provider.dart';
import '../providers/inspection/points_controller.dart';
import '../providers/inspection/route_controller.dart';
import '../widgets/point_editor_dialog.dart';

/// 巡检管理页：巡检点 / 路线 两个 Tab。
class InspectionPage extends ConsumerWidget {
  const InspectionPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('巡检管理'),
          bottom: const TabBar(
            tabs: [Tab(text: '巡检点'), Tab(text: '路线')],
          ),
        ),
        body: const TabBarView(
          children: [_PointsTab(), _RoutesTab()],
        ),
      ),
    );
  }
}

class _PointsTab extends ConsumerWidget {
  const _PointsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final points = ref.watch(pointsControllerProvider);
    if (points.isEmpty) {
      return const Center(
        child: Text('暂无巡检点\n请在地图页切换到「加点」模式点击地图创建',
            textAlign: TextAlign.center),
      );
    }
    return ListView.separated(
      itemCount: points.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final p = points[i];
        return ListTile(
          leading: CircleAvatar(child: Text('${i + 1}')),
          title: Text(p.name),
          subtitle: Text(
            '(${p.x.toStringAsFixed(2)}, ${p.y.toStringAsFixed(2)})'
            '  停留 ${p.dwellTime}s${p.capturePhoto ? "  拍照" : ""}',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.edit),
                onPressed: () async {
                  final updated =
                      await showPointEditorDialog(context, initial: p);
                  if (updated != null) {
                    ref
                        .read(pointsControllerProvider.notifier)
                        .updatePoint(updated);
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () => ref
                    .read(pointsControllerProvider.notifier)
                    .removePoint(p.id),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RoutesTab extends ConsumerWidget {
  const _RoutesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routes = ref.watch(routeControllerProvider);
    final status = ref.watch(inspectionStatusProvider).valueOrNull;
    final running = status?.isRunning ?? false;

    return Scaffold(
      body: Column(
        children: [
          if (status != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('巡检状态: ${status.state}'
                      '${status.total > 0 ? "  ${status.progress}/${status.total}" : ""}'
                      '${status.currentPoint.isNotEmpty ? "  当前: ${status.currentPoint}" : ""}'),
                  if (running && status.total > 0)
                    LinearProgressIndicator(
                        value: status.progress / status.total),
                ],
              ),
            ),
          Expanded(
            child: routes.isEmpty
                ? const Center(child: Text('暂无路线，点右下角新建'))
                : ListView.separated(
                    itemCount: routes.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final r = routes[i];
                      return ListTile(
                        leading: const Icon(Icons.route),
                        title: Text(r.name),
                        subtitle: Text(
                            '${r.pointIds.length} 个点${r.loop ? " · 循环" : ""}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(
                                running ? Icons.stop : Icons.play_arrow,
                                color: running ? Colors.red : Colors.green,
                              ),
                              tooltip: running ? '停止巡检' : '启动巡检',
                              onPressed: () {
                                final ctrl = ref.read(
                                    routeControllerProvider.notifier);
                                if (running) {
                                  ctrl.stopInspection();
                                } else {
                                  ctrl.startRoute(r.id);
                                }
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete),
                              onPressed: () => ref
                                  .read(routeControllerProvider.notifier)
                                  .removeRoute(r.id),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('新建路线'),
        onPressed: () => _showRouteEditor(context, ref),
      ),
    );
  }

  Future<void> _showRouteEditor(BuildContext context, WidgetRef ref) async {
    final points = ref.read(pointsControllerProvider);
    if (points.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先创建巡检点')));
      return;
    }
    final nameController = TextEditingController();
    final selected = <String>[];
    var loop = false;

    final route = await showDialog<InspectionRoute>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('新建路线'),
          content: SizedBox(
            width: 360,
            height: 420,
            child: Column(
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: '路线名称'),
                ),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('循环执行'),
                  value: loop,
                  onChanged: (v) => setState(() => loop = v),
                ),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('按选择顺序执行:', style: TextStyle(fontSize: 12)),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final p in points)
                        CheckboxListTile(
                          dense: true,
                          title: Text(p.name),
                          subtitle: selected.contains(p.id)
                              ? Text('顺序: ${selected.indexOf(p.id) + 1}')
                              : null,
                          value: selected.contains(p.id),
                          onChanged: (checked) => setState(() {
                            if (checked ?? false) {
                              selected.add(p.id);
                            } else {
                              selected.remove(p.id);
                            }
                          }),
                        ),
                    ],
                  ),
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
              onPressed: selected.isEmpty
                  ? null
                  : () {
                      Navigator.of(context).pop(InspectionRoute(
                        id: 'route_${DateTime.now().millisecondsSinceEpoch}',
                        name: nameController.text.trim().isEmpty
                            ? '路线${DateTime.now().millisecondsSinceEpoch % 10000}'
                            : nameController.text.trim(),
                        pointIds: List.of(selected),
                        loop: loop,
                      ));
                    },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (route != null) {
      await ref.read(routeControllerProvider.notifier).addRoute(route);
    }
  }
}
