import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/constants.dart';

/// 网关业务异常：把服务端 `{"error":{"code","message"}}` 原样带上来。
class GatewayException implements Exception {
  GatewayException(this.code, this.message, [this.status = 0]);

  final String code;
  final String message;
  final int status;

  @override
  String toString() => 'GatewayException($status $code: $message)';
}

/// 业务网关 HTTP 客户端（App 唯一的业务出口）。
///
/// 契约见 docs/架构-网关收口.md §5：
///   - 地图元信息 / PGM 下载
///   - 任务下发 / 取消 / 重试 / 查询
///   - 非任务指令（模式/急停/回充/巡检）
///   - 控制锁（避免 App 与 Web 大屏抢控）
///   - 最新 JPEG 快照（替代 rosbridge 拍照）
class GatewayClient {
  GatewayClient({
    String? baseUrl,
    String? token,
    http.Client? client,
  })  : baseUrl = baseUrl ?? AppConstants.gatewayHttpBase,
        token = token ?? AppConstants.gatewayToken,
        _http = client ?? http.Client();

  final String baseUrl;
  final String token;
  final http.Client _http;

  static const Duration _timeout = Duration(seconds: 10);

  Map<String, String> get _auth => {'Authorization': 'Bearer $token'};

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool auth = true,
  }) async {
    final uri = _uri(path, query);
    final headers = <String, String>{
      if (auth) ..._auth,
      if (body != null) 'Content-Type': 'application/json',
    };
    switch (method) {
      case 'GET':
        return _http.get(uri, headers: headers).timeout(_timeout);
      case 'POST':
        return _http
            .post(uri, headers: headers, body: jsonEncode(body ?? {}))
            .timeout(_timeout);
      case 'DELETE':
        return _http.delete(uri, headers: headers).timeout(_timeout);
      default:
        throw ArgumentError('不支持的方法 $method');
    }
  }

  Map<String, dynamic> _decode(http.Response resp) {
    final map = resp.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode >= 200 && resp.statusCode < 300) return map;
    final err = map['error'];
    if (err is Map) {
      throw GatewayException(
        '${err['code'] ?? 'ERROR'}',
        '${err['message'] ?? resp.statusCode}',
        resp.statusCode,
      );
    }
    throw GatewayException('HTTP_${resp.statusCode}', resp.body, resp.statusCode);
  }

  // ───────────────── 健康 ─────────────────
  /// `/healthz` 不需要 token，用来判断网关/MQTT/rosbridge 是否在线。
  Future<Map<String, dynamic>> healthz() async {
    final resp = await _send('GET', '/healthz', auth: false);
    return _decode(resp);
  }

  // ───────────────── 地图 ─────────────────
  /// 地图元信息；网关还没收到 `/map` 时返回 null（HTTP 404 MAP_NOT_READY）。
  Future<Map<String, dynamic>?> mapMeta() async {
    final resp = await _send('GET', '/api/v1/map/meta');
    if (resp.statusCode == 404) return null;
    return _decode(resp);
  }

  /// 下载 PGM；版本已过期（409）或未就绪（404）时返回 null。
  Future<Uint8List?> mapPgm(String version) async {
    final resp = await _send(
      'GET',
      '/api/v1/map/pgm',
      query: {'version': version},
    );
    if (resp.statusCode == 404 || resp.statusCode == 409) return null;
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return resp.bodyBytes;
    }
    _decode(resp);
    return null;
  }

  // ───────────────── 任务 ─────────────────
  /// 下发导航任务。成功返回 `{cmd_id, trace_id, phase, task}`。
  Future<Map<String, dynamic>> createNavigate({
    required double x,
    required double y,
    required double theta,
    int ttlMs = 8000,
    String holder = AppConstants.controlHolder,
  }) async {
    final resp = await _send('POST', '/api/v1/tasks', body: {
      'type': 'navigate',
      'x': x,
      'y': y,
      'theta': theta,
      'ttl_ms': ttlMs,
      'holder': holder,
    });
    return _decode(resp);
  }

  Future<Map<String, dynamic>> cancelTask(
    String cmdId, {
    String holder = AppConstants.controlHolder,
  }) async {
    final resp = await _send(
      'POST',
      '/api/v1/tasks/$cmdId/cancel',
      body: {'holder': holder},
    );
    return _decode(resp);
  }

  /// 重试：网关复用同一 cmd_id 并重新生成 timestamp_ms（修复旧版 EXPIRED 缺陷）。
  Future<Map<String, dynamic>> retryTask(
    String cmdId, {
    String holder = AppConstants.controlHolder,
  }) async {
    final resp = await _send(
      'POST',
      '/api/v1/tasks/$cmdId/retry',
      body: {'holder': holder},
    );
    return _decode(resp);
  }

  Future<Map<String, dynamic>> getTask(String cmdId) async {
    final resp = await _send('GET', '/api/v1/tasks/$cmdId');
    return _decode(resp);
  }

  Future<List<Map<String, dynamic>>> listTasks({int limit = 20}) async {
    final resp =
        await _send('GET', '/api/v1/tasks', query: {'limit': '$limit'});
    final list = (_decode(resp)['tasks'] as List? ?? const []);
    return list.cast<Map<String, dynamic>>();
  }

  // ───────────────── 非任务指令 ─────────────────
  Future<Map<String, dynamic>> sendCommand(
    String name,
    Map<String, dynamic> payload, {
    String holder = AppConstants.controlHolder,
  }) async {
    final resp = await _send('POST', '/api/v1/commands', body: {
      'name': name,
      'payload': payload,
      'holder': holder,
    });
    return _decode(resp);
  }

  // ───────────────── 控制锁 ─────────────────
  Future<Map<String, dynamic>> acquireLock({
    String holder = AppConstants.controlHolder,
    int ttlSeconds = 60,
  }) async {
    final resp = await _send('POST', '/api/v1/lock', body: {
      'holder': holder,
      'ttl_s': ttlSeconds,
    });
    return _decode(resp);
  }

  Future<void> releaseLock({String holder = AppConstants.controlHolder}) async {
    final resp = await _send(
      'DELETE',
      '/api/v1/lock',
      query: {'holder': holder},
    );
    if (resp.statusCode == 204) return;
    _decode(resp);
  }

  // ───────────────── 快照（拍照）─────────────────
  Future<Uint8List?> snapshot() async {
    final resp = await _send('GET', '/api/v1/snapshot');
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return resp.bodyBytes;
    }
    // 503 NO_FRAME：还没有图像帧，返回 null 由 UI 提示
    if (resp.statusCode == 503) return null;
    _decode(resp);
    return null;
  }

  void dispose() => _http.close();
}
