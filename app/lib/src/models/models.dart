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

List<String> _strings(Object? value) => value is List
    ? value
          .whereType<String>()
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false)
    : const <String>[];

/// 列表页用的会话摘要：不含 resultText 全文（服务端只给前 400 字预览）。
class SessionItem {
  const SessionItem({
    required this.deviceId,
    required this.sessionId,
    this.workspace,
    this.workspaceRoot,
    this.project,
    this.projectRoot,
    this.projectKind,
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
    project: _str(json['project']),
    projectRoot: _str(json['projectRoot']),
    projectKind: _str(json['projectKind']),
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

  /// 项目名（bridge 从工作目录向上找到 .git / 构建标记的目录名）。
  final String? project;
  final String? projectRoot;

  /// project = 识别到项目根；loose = 家目录等散会话。
  final String? projectKind;
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
    super.project,
    super.projectRoot,
    super.projectKind,
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
      project: base.project,
      projectRoot: base.projectRoot,
      projectKind: base.projectKind,
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

/// 随命令一起发给电脑的附件（文件 / 图片）。
///
/// 只有元数据：内容在 Hub 的 `attachments` 表里，bridge 领取命令时按 [id]
/// 自己下载到本机。列表接口也只返回这几个字段，不会把文件内容塞进 JSON。
class AttachmentInfo {
  const AttachmentInfo({
    required this.id,
    this.name,
    this.mimeType,
    this.byteSize = 0,
    this.createdAt,
  });

  factory AttachmentInfo.fromJson(Map<String, dynamic> json) => AttachmentInfo(
    id: _str(json['id']) ?? '',
    name: _str(json['name']),
    mimeType: _str(json['mimeType']),
    byteSize: _int(json['byteSize']) ?? 0,
    // 入库时间：附件落进 Hub 的时刻。旧版本 Hub 不返回时保持 null（界面显示 —）。
    createdAt: _dt(json['createdAt']),
  );

  final String id;
  final String? name;
  final String? mimeType;
  final int byteSize;

  /// 附件在 Hub 的入库时间（不是命令下发时间）。
  final DateTime? createdAt;

  bool get isEmpty => id.isEmpty;

  /// 展示用文件名：Hub 没给名字（极端容错）时退回 id。
  String get label {
    final value = (name ?? '').trim();
    return value.isEmpty ? id : value;
  }

  bool get isImage => (mimeType ?? '').startsWith('image/');
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
    this.runner,
    this.pid,
    this.pidStartedAt,
    this.resultText,
    this.errorText,
    this.createdAt,
    this.deliveredAt,
    this.startedAt,
    this.finishedAt,
    this.cancelRequestedAt,
    this.attachment,
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
    runner: _str(json['runner']),
    pid: _int(json['pid']),
    pidStartedAt: _dt(json['pidStartedAt']),
    resultText: _str(json['resultText']),
    errorText: _str(json['errorText']),
    createdAt: _dt(json['createdAt']),
    deliveredAt: _dt(json['deliveredAt']),
    startedAt: _dt(json['startedAt']),
    finishedAt: _dt(json['finishedAt']),
    cancelRequestedAt: _dt(json['cancelRequestedAt']),
    attachment: json['attachment'] is Map
        ? AttachmentInfo.fromJson(_map(json['attachment']))
        : null,
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

  /// bridge 实际上用的执行器：`cline` / `shell`。
  final String? runner;

  /// 执行这条命令的子进程 PID（bridge spawn 后上报）。
  ///
  /// **只用来看和核对**：Windows 会复用 PID，没有 [pidStartedAt] 时不得按它杀进程。
  final int? pid;

  /// 子进程启动时间（bridge 本地时钟），与 [pid] 成对用于防 PID 复用。
  final DateTime? pidStartedAt;

  final String? resultText;
  final String? errorText;
  final DateTime? createdAt;
  final DateTime? deliveredAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  /// 手机端请求取消的时间；`null` 表示没人取消过。
  final DateTime? cancelRequestedAt;

  /// 这条命令带过去的附件（文件 / 图片）；`null` = 纯文字命令。
  final AttachmentInfo? attachment;

  /// 还在流程里：排队 / 已送达 / 执行中 / 正在取消。
  /// `cancelling` 必须算「活着」：此时 bridge 还没杀完进程，取消按钮要显示「取消中」。
  bool get isActive =>
      status == 'pending' ||
      status == 'delivered' ||
      status == 'running' ||
      status == 'cancelling';

  /// bridge 已经收到取消请求，正在停进程。
  bool get isCancelling => status == 'cancelling';

  /// 本机排障用的 PowerShell：先核对启动时间，再决定要不要杀。
  ///
  /// 直接 `taskkill /pid` 有误伤风险（PID 复用），所以把核对命令放在最前面。
  /// 注意 `$pid` 在这里是 **Dart 插值**，会落成真实数字；PowerShell 里的 `$pid`
  /// 是「当前 PowerShell 进程」，照抄过去会查到自己身上。
  String get diagnosticsCommand {
    if (pid == null) return '';
    return <String>[
      'Get-Process -Id $pid | Select-Object Id,StartTime,Path',
      if (pidStartedAt != null)
        '# 登记启动时间 ${pidStartedAt!.toIso8601String()}：StartTime 对不上就不要按 pid 杀',
      '# 确认是这条命令后再执行（bridge 侧更稳：cd bridge; npm run ps）',
      'taskkill /pid $pid /t /f',
    ].join('\n');
  }

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
    this.truncated = false,
    this.options = const <String>[],
  });

  factory SessionMessage.fromJson(Map<String, dynamic> json) => SessionMessage(
    messageId: _str(json['messageId']) ?? _str(json['id']) ?? '',
    role: _str(json['role']) ?? 'assistant',
    kind: _str(json['kind']) ?? 'text',
    text: _str(json['text']) ?? '',
    tool: _str(json['tool']),
    ts: _dt(json['ts']),
    seq: _int(json['seq']) ?? 0,
    truncated: _bool(json['truncated']),
    options: _strings(json['options']),
  );

  final String messageId;
  final String role;
  final String kind;
  final String text;
  final String? tool;
  final DateTime? ts;
  final int seq;

  /// bridge 上报时已按 `maxTextChars` 截断：界面上要说明「这不是全文」。
  final bool truncated;

  /// kind=question 时的可选项（Cline `ask_question` 的 options）。
  final List<String> options;

  bool get isQuestion => kind == 'question';

  bool get isUser => role == 'user';
  bool get isCommand => kind == 'command';

  /// 列表 key：message_id 全局稳定，列表刷新时不会整屏重排。
  String get key => messageId.isNotEmpty ? messageId : '$seq-$role-$kind';
}

/// 一台接入 Hub 的电脑（bridge）。
///
/// `GET /api/v1/devices` 只返回 `role=device` 的 client；手机自己的 app client
/// 不在里面，所以这个列表可以直接拿来当「下发目标 / 筛选chip」的候选。
class DeviceItem {
  const DeviceItem({
    required this.id,
    this.name,
    this.createdAt,
    this.lastSeenAt,
    this.sessionCount = 0,
    this.commandCount = 0,
    this.pendingCommands = 0,
    this.runningCommands = 0,
    this.lastSessionAt,
    this.lastCommandAt,
  });

  factory DeviceItem.fromJson(Map<String, dynamic> json) => DeviceItem(
    id: _str(json['id']) ?? '',
    name: _str(json['name']),
    createdAt: _dt(json['createdAt']),
    lastSeenAt: _dt(json['lastSeenAt']),
    sessionCount: _int(json['sessionCount']) ?? 0,
    commandCount: _int(json['commandCount']) ?? 0,
    pendingCommands: _int(json['pendingCommands']) ?? 0,
    runningCommands: _int(json['runningCommands']) ?? 0,
    lastSessionAt: _dt(json['lastSessionAt']),
    lastCommandAt: _dt(json['lastCommandAt']),
  );

  final String id;
  final String? name;
  final DateTime? createdAt;

  /// bridge 每次请求都会 touch，只是 60 秒节流一次；用它判断「在线」足够。
  final DateTime? lastSeenAt;

  final int sessionCount;
  final int commandCount;
  final int pendingCommands;
  final int runningCommands;
  final DateTime? lastSessionAt;
  final DateTime? lastCommandAt;

  /// 展示名：没起名字（name == id）时直接用 id。
  String get label {
    final value = (name ?? '').trim();
    return value.isEmpty || value == id ? id : value;
  }

  /// 2 分钟内有上报就算在线——bridge 默认 5 秒轮询一次命令。
  bool isOnlineAt(
    DateTime now, {
    Duration window = const Duration(minutes: 2),
  }) {
    final seen = lastSeenAt;
    if (seen == null) return false;
    final diff = now.difference(seen);
    return !diff.isNegative && diff <= window;
  }

  bool get isOnline => isOnlineAt(DateTime.now());
}

/// 一档 DeepSeek 余额（按币种一行；目前官方只返回 CNY 或 USD 一档）。
///
/// 金额是**字符串**：DeepSeek 返回 `"110.00"`，直接展示不经过 double，
/// 避免 `99.999` 这种浮点误差把余额显示成 `100.00`。
class DeepSeekBalanceInfo {
  const DeepSeekBalanceInfo({
    required this.currency,
    this.totalBalance,
    this.grantedBalance,
    this.toppedUpBalance,
  });

  factory DeepSeekBalanceInfo.fromJson(Map<String, dynamic> json) =>
      DeepSeekBalanceInfo(
        currency: (_str(json['currency']) ?? '').toUpperCase(),
        totalBalance: _str(json['totalBalance']),
        grantedBalance: _str(json['grantedBalance']),
        toppedUpBalance: _str(json['toppedUpBalance']),
      );

  /// `CNY` / `USD`（服务端已大写，这里再兜一次）。
  final String currency;

  /// 总可用余额（充值 + 未过期赠金）。
  final String? totalBalance;

  /// 未过期的赠金余额。
  final String? grantedBalance;

  /// 充值余额。
  final String? toppedUpBalance;

  String get symbol => switch (currency) {
    'CNY' => '¥',
    'USD' => r'$',
    _ => '',
  };

  String get totalText =>
      totalBalance == null ? '—' : '$symbol${totalBalance!}';

  /// `充值 100.00 · 赠金 10.00`；两项都缺时返回 null。
  String? get breakdownText {
    final parts = <String>[
      if (toppedUpBalance != null) '充值 ${toppedUpBalance!}',
      if (grantedBalance != null) '赠金 ${grantedBalance!}',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

/// DeepSeek 账户余额（`GET /api/v1/deepseek/balance`）。
///
/// API Key 只存在 Hub 上，这里拿到的永远是代查结果：
/// `configured=false` = Hub 没配 Key（不是错误），[stale] = 上游挂了但还有旧数字。
class DeepSeekBalance {
  const DeepSeekBalance({
    this.configured = true,
    this.isAvailable = false,
    this.balances = const <DeepSeekBalanceInfo>[],
    this.fetchedAt,
    this.cached = false,
    this.stale = false,
    this.hint,
  });

  factory DeepSeekBalance.fromJson(Map<String, dynamic> json) {
    final balances = _maps(json['balances'])
        .map(DeepSeekBalanceInfo.fromJson)
        .toList(growable: false);
    return DeepSeekBalance(
      // 老 Hub 不会带这个字段：有余额就按「已配置」处理，别把正常数据显示成未配置。
      configured: _bool(json['configured'], fallback: balances.isNotEmpty),
      isAvailable: _bool(json['isAvailable']),
      balances: balances,
      fetchedAt: _dt(json['fetchedAt']),
      cached: _bool(json['cached']),
      stale: _bool(json['stale']),
      hint: _str(json['hint']),
    );
  }

  /// Hub 上是否配了 `DEEPSEEK_API_KEY`。false 时除了 [hint] 没有别的可用信息。
  final bool configured;

  /// DeepSeek 认为「余额够不够用」；余额为 0 时官方会给 false。
  final bool isAvailable;

  final List<DeepSeekBalanceInfo> balances;

  /// Hub 拿到这份余额的时间（不是 App 请求的时间）。
  final DateTime? fetchedAt;

  /// 本次是不是从 Hub 的短缓存里拿的。
  final bool cached;

  /// 上游刷新失败、退回了上一次的结果。
  final bool stale;

  /// 未配置时的提示文案（由 Hub 下发）。
  final String? hint;

  bool get hasBalance => balances.isNotEmpty;

  DeepSeekBalanceInfo? get primary => balances.isEmpty ? null : balances.first;

  /// 主余额展示：`¥110.00`。
  String get totalText => primary?.totalText ?? '—';

  /// 明细：`充值 100.00 · 赠金 10.00`。
  String? get breakdownText => primary?.breakdownText;
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
