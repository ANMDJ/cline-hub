/// Hub v1 的返回结构（字段按服务端 camelCase 原样映射）。
///
/// 服务端是「缺字段就给 null」的风格，所以解析一律容错：
/// 任何一处类型不对都不该让整页崩掉，最坏情况显示成占位符。
library;

import 'dart:convert';

DateTime? _dt(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toLocal();
}

int? _int(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

String? _str(Object? value) {
  if (value is! String) return null;
  return value.trim().isEmpty ? null : value;
}

bool _bool(Object? value, {bool fallback = false}) =>
    value is bool ? value : fallback;

Map<String, dynamic> _map(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : const <String, dynamic>{};

List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList(growable: false)
    : const <Map<String, dynamic>>[];

/// 列表页用的会话摘要：不含 resultText 全文（服务端只给前 400 字预览）。
class SessionItem {
  const SessionItem({
    required this.deviceId,
    required this.sessionId,
    this.workspace,
    this.workspaceRoot,
    this.source,
    this.status,
    this.exitCode,
    this.provider,
    this.model,
    this.startedAt,
    this.endedAt,
    this.updatedAt,
    this.prompt,
    this.userPrompt,
    this.resultOk = false,
    this.resultError,
    this.resultPreview,
    this.resultTruncated = false,
    this.commandCount = 0,
    this.metrics = const <String, dynamic>{},
    this.collectedAt,
    this.sortAt,
  });

  factory SessionItem.fromJson(Map<String, dynamic> json) => SessionItem(
    deviceId: _str(json['deviceId']) ?? '',
    sessionId: _str(json['sessionId']) ?? '',
    workspace: _str(json['workspace']),
    workspaceRoot: _str(json['workspaceRoot']),
    source: _str(json['source']),
    status: _str(json['status']),
    exitCode: _int(json['exitCode']),
    provider: _str(json['provider']),
    model: _str(json['model']),
    startedAt: _dt(json['startedAt']),
    endedAt: _dt(json['endedAt']),
    updatedAt: _dt(json['updatedAt']),
    prompt: _str(json['prompt']),
    userPrompt: _str(json['userPrompt']),
    resultOk: _bool(json['resultOk']),
    resultError: _str(json['resultError']),
    resultPreview: _str(json['resultPreview']),
    resultTruncated: _bool(json['resultTruncated']),
    commandCount: _int(json['commandCount']) ?? 0,
    metrics: _map(json['metrics']),
    collectedAt: _dt(json['collectedAt']),
    sortAt:
        _dt(json['sortAt']) ??
        _dt(json['endedAt']) ??
        _dt(json['startedAt']) ??
        _dt(json['updatedAt']),
  );

  final String deviceId;
  final String sessionId;
  final String? workspace;
  final String? workspaceRoot;
  final String? source;
  final String? status;
  final int? exitCode;
  final String? provider;
  final String? model;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final DateTime? updatedAt;
  final String? prompt;
  final String? userPrompt;
  final bool resultOk;
  final String? resultError;
  final String? resultPreview;
  final bool resultTruncated;
  final int commandCount;
  final Map<String, dynamic> metrics;
  final DateTime? collectedAt;
  final DateTime? sortAt;

  /// 列表标题：优先用户原话，其次 Cline 的结论首句。
  String get title => userPrompt ?? prompt ?? '（无标题会话）';

  Duration? get duration {
    final start = startedAt;
    final end = endedAt;
    if (start == null || end == null) return null;
    final span = end.difference(start);
    return span.isNegative ? null : span;
  }

  bool get succeeded => resultOk || status == 'completed' || exitCode == 0;
}

class SessionCommand {
  const SessionCommand({
    required this.id,
    required this.tool,
    required this.command,
  });

  factory SessionCommand.fromJson(Map<String, dynamic> json) => SessionCommand(
    id: _str(json['id']) ?? '',
    tool: _str(json['tool']) ?? 'tool',
    command: _str(json['command']) ?? '',
  );

  final String id;
  final String tool;
  final String command;
}

/// 详情页：摘要 + resultText 全文 + 抽出来的命令。
class SessionDetail extends SessionItem {
  const SessionDetail({
    required super.deviceId,
    required super.sessionId,
    super.workspace,
    super.workspaceRoot,
    super.source,
    super.status,
    super.exitCode,
    super.provider,
    super.model,
    super.startedAt,
    super.endedAt,
    super.updatedAt,
    super.prompt,
    super.userPrompt,
    super.resultOk,
    super.resultError,
    super.resultPreview,
    super.resultTruncated,
    super.commandCount,
    super.metrics,
    super.collectedAt,
    super.sortAt,
    this.resultText,
    this.commands = const <SessionCommand>[],
  });

  factory SessionDetail.fromJson(Map<String, dynamic> json) {
    final base = SessionItem.fromJson(json);
    return SessionDetail(
      deviceId: base.deviceId,
      sessionId: base.sessionId,
      workspace: base.workspace,
      workspaceRoot: base.workspaceRoot,
      source: base.source,
      status: base.status,
      exitCode: base.exitCode,
      provider: base.provider,
      model: base.model,
      startedAt: base.startedAt,
      endedAt: base.endedAt,
      updatedAt: base.updatedAt,
      prompt: base.prompt,
      userPrompt: base.userPrompt,
      resultOk: base.resultOk,
      resultError: base.resultError,
      resultPreview: base.resultPreview,
      resultTruncated: base.resultTruncated,
      commandCount: base.commandCount,
      metrics: base.metrics,
      collectedAt: base.collectedAt,
      sortAt: base.sortAt,
      resultText: _str(json['resultText']),
      commands: _maps(json['commands'])
          .map(SessionCommand.fromJson)
          .toList(growable: false),
    );
  }

  final String? resultText;
  final List<SessionCommand> commands;
}

class SessionPage {
  const SessionPage({required this.items, this.nextCursor});

  factory SessionPage.fromJson(Map<String, dynamic> json) => SessionPage(
    items: _maps(json['items'])
        .map(SessionItem.fromJson)
        .toList(growable: false),
    nextCursor: _str(json['nextCursor']),
  );

  final List<SessionItem> items;
  final String? nextCursor;
}

/// 远程命令：App 下发、bridge 领取、执行完回写。
class CommandItem {
  const CommandItem({
    required this.id,
    required this.deviceId,
    required this.prompt,
    required this.mode,
    required this.status,
    this.workspace,
    this.sessionId,
    this.requestedBy,
    this.resultText,
    this.errorText,
    this.createdAt,
    this.deliveredAt,
    this.startedAt,
    this.finishedAt,
  });

  factory CommandItem.fromJson(Map<String, dynamic> json) => CommandItem(
    id: _str(json['id']) ?? '',
    deviceId: _str(json['deviceId']) ?? '',
    prompt: _str(json['prompt']) ?? '',
    mode: _str(json['mode']) ?? 'plan',
    status: _str(json['status']) ?? 'pending',
    workspace: _str(json['workspace']),
    sessionId: _str(json['sessionId']),
    requestedBy: _str(json['requestedBy']),
    resultText: _str(json['resultText']),
    errorText: _str(json['errorText']),
    createdAt: _dt(json['createdAt']),
    deliveredAt: _dt(json['deliveredAt']),
    startedAt: _dt(json['startedAt']),
    finishedAt: _dt(json['finishedAt']),
  );

  final String id;
  final String deviceId;
  final String prompt;
  final String mode;
  final String status;
  final String? workspace;

  /// 有值时表示这条命令是「在某个已有会话里继续说」。
  final String? sessionId;
  final String? requestedBy;
  final String? resultText;
  final String? errorText;
  final DateTime? createdAt;
  final DateTime? deliveredAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  bool get isActive =>
      status == 'pending' || status == 'delivered' || status == 'running';

  Duration? get duration {
    final start = startedAt ?? deliveredAt ?? createdAt;
    final end = finishedAt ?? (isActive ? DateTime.now() : null);
    if (start == null || end == null) return null;
    final span = end.difference(start);
    return span.isNegative ? null : span;
  }

  String get modeLabel => switch (mode) {
    'act' => 'ACT',
    'yolo' => 'YOLO',
    _ => 'PLAN',
  };
}

/// Hook 事件流（Cline 任务开始 / 结束 / 中断时由 bridge 推上来）。
class HookItem {
  const HookItem({
    required this.id,
    this.deviceId,
    this.event,
    this.workspace,
    this.title,
    this.body,
    this.sessionId,
    this.receivedAt,
  });

  factory HookItem.fromJson(Map<String, dynamic> json) => HookItem(
    id: _int(json['id']) ?? 0,
    deviceId: _str(json['deviceId']),
    event: _str(json['event']),
    workspace: _str(json['workspace']),
    title: _str(json['title']),
    body: _str(json['body']),
    sessionId: _str(json['sessionId']),
    receivedAt: _dt(json['receivedAt']),
  );

  final int id;
  final String? deviceId;
  final String? event;
  final String? workspace;
  final String? title;
  final String? body;

  /// bridge 的完成通知会带上会话 id，动态卡片靠它跳进详情页；
  /// Cline 自己的 hook 没有这个字段，所以是 null。
  final String? sessionId;
  final DateTime? receivedAt;
}

/// 会话里的一条消息：一段正文，或一次工具调用（命令过程）。
///
/// 服务端按 `(device, session, message_id)` upsert，流式回复的同一条消息
/// 会被覆盖成最新内容，所以这里不需要自己去重。
class SessionMessage {
  const SessionMessage({
    required this.messageId,
    required this.role,
    required this.kind,
    required this.text,
    this.tool,
    this.ts,
    this.seq = 0,
  });

  factory SessionMessage.fromJson(Map<String, dynamic> json) => SessionMessage(
    messageId: _str(json['messageId']) ?? _str(json['id']) ?? '',
    role: _str(json['role']) ?? 'assistant',
    kind: _str(json['kind']) ?? 'text',
    text: _str(json['text']) ?? '',
    tool: _str(json['tool']),
    ts: _dt(json['ts']),
    seq: _int(json['seq']) ?? 0,
  );

  final String messageId;
  final String role;
  final String kind;
  final String text;
  final String? tool;
  final DateTime? ts;
  final int seq;

  bool get isUser => role == 'user';
  bool get isCommand => kind == 'command';

  /// 列表 key：message_id 全局稳定，列表刷新时不会整屏重排。
  String get key => messageId.isNotEmpty ? messageId : '$seq-$role-$kind';
}

class HealthInfo {
  const HealthInfo({
    required this.ok,
    required this.service,
    required this.version,
    this.uptimeSec = 0,
    this.dbOk = false,
    this.dbLatencyMs,
    this.sseClients = 0,
  });

  factory HealthInfo.fromJson(Map<String, dynamic> json) {
    final db = _map(json['db']);
    return HealthInfo(
      ok: _bool(json['ok']),
      service: _str(json['service']) ?? 'hub',
      version: _str(json['version']) ?? '?',
      uptimeSec: _int(json['uptimeSec']) ?? 0,
      dbOk: _bool(db['ok']),
      dbLatencyMs: _int(db['latencyMs']),
      sseClients: _int(json['sseClients']) ?? 0,
    );
  }

  final bool ok;
  final String service;
  final String version;
  final int uptimeSec;
  final bool dbOk;
  final int? dbLatencyMs;
  final int sseClients;
}

/// SSE 里的一帧；`tick` 是网页端降级轮询用的自造心跳。
class HubEvent {
  const HubEvent(this.type, this.data);

  factory HubEvent.fromSse(String type, String raw) {
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(raw);
      data = decoded is Map
          ? decoded.cast<String, dynamic>()
          : <String, dynamic>{'value': decoded};
    } catch (_) {
      data = <String, dynamic>{'raw': raw};
    }
    return HubEvent(type, data);
  }

  final String type;
  final Map<String, dynamic> data;
}
