// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:typed_data';

/// Web 端：触发浏览器下载，返回提示文案。
Future<String> saveCapture(Uint8List frame) async {
  final blob = html.Blob([frame], 'image/jpeg');
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..download = 'shot_${DateTime.now().millisecondsSinceEpoch}.jpg'
    ..click();
  html.Url.revokeObjectUrl(url);
  return '已开始下载截图';
}
