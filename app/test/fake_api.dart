import 'dart:async';
import 'dart:typed_data';

import 'package:cline_console/src/data/hub_api.dart';
import 'package:cline_console/src/models/models.dart';

/// 内存版 Hub：不碰网络，用来验证状态层和页面行为。
class FakeHubApi implements HubApi {
  FakeHubApi({
    this.sessionItems = const <SessionItem>[],
    this.commandItems = const <CommandItem>[],
    this.hookItems = const <HookItem>[],
    this.messageItems = const <SessionMessage>[],
    this.deviceItems = const <DeviceItem>[],
    this.deepseekBalanceItem,
    this.deepseekError,
    this.nextCursor,
    this.detail,
  });

  List<SessionItem> sessionItems;
  List<CommandItem> commandItems;
  List<HookItem> hookItems;
  List<SessionMessage> messageItems;
  List<DeviceItem> deviceItems;

  /// DeepSeek 余额（P44）：null = 用「未配置」的默认返回；[deepseekError] 用来模拟失败。
  DeepSeekBalance? deepseekBalanceItem;
  Object? deepseekError;
  int deepseekBalanceCalls = 0;
  bool lastBalanceRefresh = false;
  String? nextCursor;
  SessionDetail? detail;

  final StreamController<HubEvent> _events =
      StreamController<HubEvent>.broadcast();

  int healthCalls = 0;
  int messageCalls = 0;
  int sessionsCalls = 0;
  int? lastSessionsLimit;
  final List<Map<String, Object?>> sentCommands = <Map<String, Object?>>[];
  final List<String> cancelledCommands = <String>[];

  /// 上传过的附件（P38）：测试断言「先上传再下发」的先后与参数。
  final List<Map<String, Object?>> uploadedAttachments =
      <Map<String, Object?>>[];
  String? sessionQuery;
  bool closed = false;

  /// 测试用：让 `before` 请求返回空，模拟「历史已经翻到头」。
  bool ignoreBefore = false;

  void emit(String type, Map<String, dynamic> data) =>
      _events.add(HubEvent(type, data));

  @override
  Future<HealthInfo> health() async {
    healthCalls++;
    return const HealthInfo(
      ok: true,
      service: 'cline-hub',
      version: '0.1.0',
      dbOk: true,
      dbLatencyMs: 3,
    );
  }

  @override
  Future<SessionPage> sessions({
    String? cursor,
    String? query,
    String? status,
    String? deviceId,
    int limit = 30,
  }) async {
    sessionsCalls++;
    lastSessionsLimit = limit;
    sessionQuery = query;
    return SessionPage(items: sessionItems, nextCursor: nextCursor);
  }

  @override
  Future<SessionDetail> session(String sessionId) async {
    final found = detail;
    if (found != null) return found;
    return SessionDetail(deviceId: 'localone', sessionId: sessionId);
  }

  @override
  Future<List<SessionMessage>> sessionMessages(
    String sessionId, {
    int limit = 60,
    int? after,
    int? before,
  }) async {
    messageCalls++;
    // 语义对齐服务端：有 after 就升序取 seq > after（after=-1 即「从开头取」）；
    // 只有 before 时取 seq < before 的最后 N 条；都没有就取最后 N 条。
    final all = <SessionMessage>[...messageItems]
      ..sort((a, b) => a.seq.compareTo(b.seq));
    if (after != null) {
      return all.where((item) => item.seq > after).take(limit).toList();
    }
    if (before != null) {
      if (ignoreBefore) return const <SessionMessage>[];
      final older = all.where((item) => item.seq < before).toList();
      return older
          .skip(older.length > limit ? older.length - limit : 0)
          .toList();
    }
    return all.skip(all.length > limit ? all.length - limit : 0).toList();
  }

  @override
  Future<List<CommandItem>> commands({
    int limit = 50,
    String? status,
    String? deviceId,
  }) async => commandItems;

  @override
  Future<List<DeviceItem>> devices() async => deviceItems;

  @override
  Future<DeepSeekBalance> deepseekBalance({bool refresh = false}) async {
    deepseekBalanceCalls += 1;
    lastBalanceRefresh = refresh;
    final error = deepseekError;
    if (error != null) throw error;
    return deepseekBalanceItem ??
        const DeepSeekBalance(
          configured: false,
          hint: '在 Hub 的 server/.env 里配置 DEEPSEEK_API_KEY 后重启容器',
        );
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
    sentCommands.add(<String, Object?>{
      'deviceId': deviceId,
      'prompt': prompt,
      'mode': mode,
      'workspace': workspace,
      'sessionId': sessionId,
      'attachmentId': attachmentId,
    });
    return CommandItem(
      id: 'cmd_fake',
      deviceId: deviceId,
      prompt: prompt,
      mode: mode,
      status: 'pending',
      workspace: workspace,
      sessionId: sessionId,
      createdAt: DateTime.now(),
      attachment: attachmentId == null
          ? null
          : AttachmentInfo(
              id: attachmentId,
              name: 'fake.bin',
              mimeType: 'application/octet-stream',
              byteSize: 3,
            ),
    );
  }

  @override
  Future<AttachmentInfo> uploadAttachment({
    required String deviceId,
    required String name,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    final id = 'att_fake_${uploadedAttachments.length + 1}';
    uploadedAttachments.add(<String, Object?>{
      'id': id,
      'deviceId': deviceId,
      'name': name,
      'mimeType': mimeType,
      'byteSize': bytes.length,
    });
    return AttachmentInfo(
      id: id,
      name: name,
      mimeType: mimeType,
      byteSize: bytes.length,
    );
  }

  @override
  Future<CommandItem> cancelCommand(String id) async {
    cancelledCommands.add(id);
    final index = commandItems.indexWhere((item) => item.id == id);
    final base = index >= 0
        ? commandItems[index]
        : CommandItem(
            id: id,
            deviceId: 'localone',
            prompt: '(fake)',
            mode: 'plan',
            status: 'running',
          );
    final updated = CommandItem(
      id: base.id,
      deviceId: base.deviceId,
      prompt: base.prompt,
      mode: base.mode,
      status: 'cancelling',
      workspace: base.workspace,
      sessionId: base.sessionId,
      requestedBy: base.requestedBy,
      runner: base.runner,
      pid: base.pid,
      pidStartedAt: base.pidStartedAt,
      resultText: base.resultText,
      errorText: base.errorText,
      createdAt: base.createdAt,
      deliveredAt: base.deliveredAt,
      startedAt: base.startedAt,
      finishedAt: base.finishedAt,
      cancelRequestedAt: DateTime.now(),
    );
    commandItems = <CommandItem>[
      for (final item in commandItems)
        if (item.id == id) updated else item,
    ];
    return updated;
  }

  @override
  Future<List<HookItem>> hooks({
    int limit = 50,
    int? beforeId,
    String? deviceId,
  }) async => hookItems;
  @override
  Stream<HubEvent> events() => _events.stream;

  @override
  Future<void> close() async {
    closed = true;
    await _events.close();
  }
}
