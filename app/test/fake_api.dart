import 'dart:async';

import 'package:cline_console/src/data/hub_api.dart';
import 'package:cline_console/src/models/models.dart';

/// 内存版 Hub：不碰网络，用来验证状态层和页面行为。
class FakeHubApi implements HubApi {
  FakeHubApi({
    this.sessionItems = const <SessionItem>[],
    this.commandItems = const <CommandItem>[],
    this.hookItems = const <HookItem>[],
    this.messageItems = const <SessionMessage>[],
    this.nextCursor,
    this.detail,
  });

  List<SessionItem> sessionItems;
  List<CommandItem> commandItems;
  List<HookItem> hookItems;
  List<SessionMessage> messageItems;
  String? nextCursor;
  SessionDetail? detail;

  final StreamController<HubEvent> _events =
      StreamController<HubEvent>.broadcast();

  int healthCalls = 0;
  int messageCalls = 0;
  int sessionsCalls = 0;
  int? lastSessionsLimit;
  final List<Map<String, Object?>> sentCommands = <Map<String, Object?>>[];
  String? sessionQuery;
  bool closed = false;

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
    var list = messageItems;
    if (after != null) list = list.where((item) => item.seq > after).toList();
    if (before != null) list = list.where((item) => item.seq < before).toList();
    return list;
  }

  @override
  Future<List<CommandItem>> commands({
    int limit = 50,
    String? status,
    String? deviceId,
  }) async => commandItems;

  @override
  Future<CommandItem> sendCommand({
    required String deviceId,
    required String prompt,
    String mode = 'plan',
    String? workspace,
    String? sessionId,
  }) async {
    sentCommands.add(<String, Object?>{
      'deviceId': deviceId,
      'prompt': prompt,
      'mode': mode,
      'workspace': workspace,
      'sessionId': sessionId,
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
    );
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
