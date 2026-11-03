import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import '../models/models.dart';

/// 统一把服务端的 `{ ok:false, code, message }` 和网络异常转成一句中文。
class ApiException implements Exception {
  ApiException(this.status, this.code, this.message);

  /// status == 0 表示请求没走到服务端（DNS / 连接 / 超时）。
  final int status;
  final String code;
  final String message;

  bool get isAuth => status == 401 || code == 'forbidden';

  String get friendly => switch (code) {
    'network' => '连不上 Hub：检查地址、网络，以及 baseUrl 是否带了 /_h/<前缀>',
    'timeout' => '请求超时：服务器没响应，稍后再试',
    'unauthorized' => 'token 无效或已失效（401）——用 create-device 重新签发一个',
    'forbidden' =>
      'token 角色不对（403）：手机发命令要用 app token，device token 只给 bridge 上报用',
    'ip_not_allowed' => '服务器 IP 白名单拒绝了本机（403）',
    'rate_limited' => '触发限流（429），等一两秒再试',
    'not_found' || 'http_404' => '404：路径不存在，检查 baseUrl 是否包含 /_h/<前缀>',
    'http_502' || 'http_503' || 'http_504' => '网关后面的服务没起来（$code），去服务器看 Hub 进程',
    'unknown_device' => '设备不存在：先在 Hub 上创建设备客户端',
    'auth_unavailable' => 'Hub 连不上数据库（503）',
    'attachment_too_large' =>
      '附件太大：Hub 上限是 8 MB（可用 HUB_MAX_ATTACHMENT_BYTES 调大）',
    'deepseek_auth_failed' =>
      'DeepSeek 拒绝了 Hub 上的 API Key：检查 server/.env 的 DEEPSEEK_API_KEY',
    'deepseek_rate_limited' => 'DeepSeek 余额接口被限流（429），过一会儿再刷新',
    'deepseek_timeout' => 'DeepSeek 余额接口超时，过一会儿再刷新',
    'deepseek_unreachable' => 'Hub 连不上 api.deepseek.com（服务器网络 / 出口问题）',
    'deepseek_bad_response' || 'deepseek_error' => 'DeepSeek 余额接口返回异常（$code）',
    'invalid_field' => '参数不合法：$message',
    _ => status == 0 ? message : '$message（$status $code）',
  };

  @override
  String toString() => 'ApiException($status $code): $message';
}

/// 去掉末尾斜杠，App 里所有路径都按 `$base + /api/v1/...` 拼。
String normalizeBaseUrl(String raw) {
  var value = raw.trim();
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

/// App 只依赖这个接口：真实实现走 HTTP，测试里换成内存假实现。
abstract class HubApi {
  Future<HealthInfo> health();

  Future<SessionPage> sessions({
    String? cursor,
    String? query,
    String? status,
    String? deviceId,
    int limit,
  });

  Future<SessionDetail> session(String sessionId);

  /// 会话的完整消息流（正文 + 命令过程）。会话还在跑时服务端会继续增长，
  /// 详情页可以用 `after` 按 seq 增量续拉。
  Future<List<SessionMessage>> sessionMessages(
    String sessionId, {
    int limit,
    int? after,
    int? before,
  });

  Future<List<CommandItem>> commands({
    int limit,
    String? status,
    String? deviceId,
  });

  /// Hub 上所有电脑端（bridge）的概览：名字、在线时间、会话 / 命令计数。
  /// device token 只会拿到自己，app/admin 拿全部（见 docs/api.md）。
  Future<List<DeviceItem>> devices();

  /// DeepSeek 账户余额。API Key 只存在 Hub 上，App 只拿代查结果。
  ///
  /// [refresh] 要求 Hub 跳过它的短缓存（手动刷新按钮用）。
  Future<DeepSeekBalance> deepseekBalance({bool refresh = false});

  Future<CommandItem> sendCommand({
    required String deviceId,
    required String prompt,
    String mode,
    String? workspace,
    String? sessionId,
    String? attachmentId,
  });

  /// 上传一份附件（文件 / 图片）到 Hub，返回可被 [sendCommand] 引用的元数据。
  ///
  /// 内容走 base64 JSON，而不是 multipart：服务端是零框架的 `node:http`，
  /// 没有 multipart 解析（ADR-52）。上限见 `kMaxAttachmentBytes`（8 MB）。
  Future<AttachmentInfo> uploadAttachment({
    required String deviceId,
    required String name,
    required String mimeType,
    required Uint8List bytes,
  });

  /// 取消一条还没结束的命令。
  ///
  /// 排队中的会直接变 `cancelled`；执行中的先变 `cancelling`，
  /// 由 bridge 杀掉进程后再回写 `cancelled`（见 docs/api.md）。
  Future<CommandItem> cancelCommand(String id);

  Future<List<HookItem>> hooks({int limit, int? beforeId, String? deviceId});

  /// 服务端事件流。Android 走 SSE；web 预览不支持流式响应，退化成心跳轮询。
  Stream<HubEvent> events();

  Future<void> close();
}

class HttpHubApi implements HubApi {
  HttpHubApi({
    required String baseUrl,
    required String token,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _base = normalizeBaseUrl(baseUrl),
       _token = token.trim(),
       _client = client ?? http.Client();

  final String _base;
  final String _token;
  final http.Client _client;
  final Duration timeout;

  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('$_base$path');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: {...uri.queryParameters, ...query});
  }

  Map<String, String> get _headers => {
    'authorization': 'Bearer $_token',
    'accept': 'application/json',
  };

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Duration? timeLimit,
  }) async {
    final request = http.Request(method, _uri(path, query));
    request.headers.addAll(_headers);
    if (body != null) {
      request.headers['content-type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(body);
    }

    final limit = timeLimit ?? timeout;
    http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(limit);
    } on TimeoutException {
      throw ApiException(
        0,
        'timeout',
        'request timed out after ${limit.inSeconds}s',
      );
    } catch (error) {
      throw ApiException(0, 'network', '$error');
    }

    final text = await response.stream.bytesToString();
    return _decode(response.statusCode, text);
  }

  Map<String, dynamic> _decode(int status, String text) {
    Map<String, dynamic>? json;
    if (text.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) json = decoded.cast<String, dynamic>();
      } catch (_) {
        // 非 JSON（比如反代返回的 404 页面）走下面的兜底
      }
    }

    if (status >= 400 || (json != null && json['ok'] == false)) {
      final code =
          json?['code'] as String? ??
          (status >= 400 ? 'http_$status' : 'unknown');
      final message =
          json?['message'] as String? ??
          (text.isEmpty ? 'empty response' : text);
      throw ApiException(status, code, message);
    }
    if (json == null) {
      throw ApiException(status, 'bad_response', 'expected JSON, got: $text');
    }
    return json;
  }

  List<Map<String, dynamic>> _items(Map<String, dynamic> json) {
    final items = json['items'];
    if (items is! List) return const <Map<String, dynamic>>[];
    return items
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList(growable: false);
  }

  @override
  Future<HealthInfo> health() async =>
      HealthInfo.fromJson(await _request('GET', '/api/v1/health'));

  @override
  Future<SessionPage> sessions({
    String? cursor,
    String? query,
    String? status,
    String? deviceId,
    int limit = 30,
  }) async {
    final json = await _request(
      'GET',
      '/api/v1/sessions',
      query: {
        'limit': '$limit',
        if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
        if (query != null && query.isNotEmpty) 'q': query,
        if (status != null && status.isNotEmpty) 'status': status,
        if (deviceId != null && deviceId.isNotEmpty) 'deviceId': deviceId,
      },
    );
    return SessionPage.fromJson(json);
  }

  @override
  Future<SessionDetail> session(String sessionId) async {
    final json = await _request(
      'GET',
      '/api/v1/sessions/${Uri.encodeComponent(sessionId)}',
    );
    final raw = json['session'];
    return SessionDetail.fromJson(
      raw is Map ? raw.cast<String, dynamic>() : <String, dynamic>{},
    );
  }

  @override
  Future<List<SessionMessage>> sessionMessages(
    String sessionId, {
    int limit = 60,
    int? after,
    int? before,
  }) async {
    final json = await _request(
      'GET',
      '/api/v1/sessions/${Uri.encodeComponent(sessionId)}/messages',
      query: {
        'limit': '$limit',
        if (after != null) 'after': '$after',
        if (before != null) 'before': '$before',
      },
    );
    return _items(json).map(SessionMessage.fromJson).toList(growable: false);
  }

  @override
  Future<List<CommandItem>> commands({
    int limit = 50,
    String? status,
    String? deviceId,
  }) async {
    final json = await _request(
      'GET',
      '/api/v1/commands',
      query: {
        'limit': '$limit',
        if (status != null && status.isNotEmpty) 'status': status,
        if (deviceId != null && deviceId.isNotEmpty) 'deviceId': deviceId,
      },
    );
    return _items(json).map(CommandItem.fromJson).toList(growable: false);
  }

  @override
  Future<List<DeviceItem>> devices() async {
    final json = await _request('GET', '/api/v1/devices');
    return _items(json).map(DeviceItem.fromJson).toList(growable: false);
  }

  @override
  Future<DeepSeekBalance> deepseekBalance({bool refresh = false}) async {
    final json = await _request(
      'GET',
      '/api/v1/deepseek/balance',
      query: {if (refresh) 'refresh': '1'},
    );
    return DeepSeekBalance.fromJson(json);
  }

  @override
  Future<CommandItem> sendCommand({
    required String deviceId,
    required String prompt,
    String mode = 'plan',
    String? workspace,
    String? sessionId,
    String? attachmentId,
  }) async {
    final json = await _request(
      'POST',
      '/api/v1/commands',
      body: {
        'deviceId': deviceId,
        'prompt': prompt,
        'mode': mode,
        if (workspace != null && workspace.isNotEmpty) 'workspace': workspace,
        if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
        if (attachmentId != null && attachmentId.isNotEmpty)
          'attachmentId': attachmentId,
      },
    );
    final raw = json['command'];
    return CommandItem.fromJson(
      raw is Map ? raw.cast<String, dynamic>() : <String, dynamic>{},
    );
  }

  /// 上传超时单独放宽：一份 8 MB 的图片在移动网络下 15 秒根本传不完。
  static const Duration uploadTimeout = Duration(seconds: 90);

  @override
  Future<AttachmentInfo> uploadAttachment({
    required String deviceId,
    required String name,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    final json = await _request(
      'POST',
      '/api/v1/attachments',
      body: {
        'deviceId': deviceId,
        'name': name,
        'mimeType': mimeType,
        'data': base64Encode(bytes),
      },
      timeLimit: uploadTimeout,
    );
    final raw = json['attachment'];
    return AttachmentInfo.fromJson(
      raw is Map ? raw.cast<String, dynamic>() : <String, dynamic>{},
    );
  }

  @override
  Future<CommandItem> cancelCommand(String id) async {
    final json = await _request(
      'POST',
      '/api/v1/commands/${Uri.encodeComponent(id)}/cancel',
      body: const <String, Object?>{},
    );
    final raw = json['command'];
    return CommandItem.fromJson(
      raw is Map ? raw.cast<String, dynamic>() : <String, dynamic>{},
    );
  }

  @override
  Future<List<HookItem>> hooks({
    int limit = 50,
    int? beforeId,
    String? deviceId,
  }) async {
    final json = await _request(
      'GET',
      '/api/v1/hooks',
      query: {
        'limit': '$limit',
        if (beforeId != null) 'beforeId': '$beforeId',
        if (deviceId != null && deviceId.isNotEmpty) 'deviceId': deviceId,
      },
    );
    return _items(json).map(HookItem.fromJson).toList(growable: false);
  }

  @override
  Stream<HubEvent> events() => kIsWeb ? _poll() : _sse();

  /// 浏览器拿不到流式响应（BrowserClient 会缓冲整个 body），
  /// 与其装作有 SSE，不如老实地按固定节拍让上层去拉数据。
  Stream<HubEvent> _poll() async* {
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 6));
      yield const HubEvent('tick', <String, dynamic>{});
    }
  }

  Stream<HubEvent> _sse() async* {
    final request =
        http.Request('GET', _uri('/api/v1/events', {'token': _token}))
          ..headers['accept'] = 'text/event-stream'
          ..headers['cache-control'] = 'no-cache';

    final response = await _client.send(request);
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      _decode(response.statusCode, body); // 只为抛异常
    }

    String? event;
    final data = StringBuffer();
    // 服务端一连上就先发 ": connected"，把这行当成「链路已就绪」的信号交给上层。
    // 否则空闲时没有业务事件，UI 会一直停在「连接中」，直到下一次有人干活。
    var announced = false;

    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (data.isNotEmpty) {
          final payload = data.toString();
          data.clear();
          yield HubEvent.fromSse(event ?? 'message', payload);
        }
        event = null;
        continue;
      }
      if (line.startsWith(':')) {
        if (!announced) {
          announced = true;
          yield const HubEvent('open', <String, dynamic>{});
        }
        continue; // ": ping" 心跳
      }
      if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        if (data.isNotEmpty) data.write('\n');
        data.write(line.substring(5).trimLeft());
      }
    }
  }

  @override
  Future<void> close() async => _client.close();
}
