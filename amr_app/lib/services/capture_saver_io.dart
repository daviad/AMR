import 'dart:io';
import 'dart:typed_data';

/// 非 Web 端：保存到临时目录，返回提示文案。
Future<String> saveCapture(Uint8List frame) async {
  final dir = Directory('${Directory.systemTemp.path}/amr_captures');
  await dir.create(recursive: true);
  final file = File(
      '${dir.path}/shot_${DateTime.now().millisecondsSinceEpoch}.jpg');
  await file.writeAsBytes(frame, flush: true);
  return '已保存: ${file.path}';
}
