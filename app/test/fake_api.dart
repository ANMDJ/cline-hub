import 'dart:async';

import 'package:cline_console/src/data/hub_api.dart';
import 'package:cline_console/src/models/models.dart';

/// 内存版 Hub：不碰网络，用来验证状态层和页面行为。
class FakeHubApi implements HubApi {
  FakeHubApi({
    this.sessionItems = const <SessionItem>[],
    this.commandItems = const <CommandItem>[],
    this.hookItems = const <HookItem>[],
    this.nextCursor,
    this.detail,
  });

  List<SessionItem> sessionItems;
  List<CommandItem> commandItems;
  List<HookItem> hookItems;
  String? nextCursor;
  SessionDetail? detail;

  final StreamController<HubEvent> _events =
      StreamController<HubEvent>.broadcast();

  int healthCalls = 0;
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
  }) async {
    sentCommands.add(<String, Object?>{
      'deviceId': deviceId,
      'prompt': prompt,
      'mode': mode,
      'workspace': workspace,
    });
    return CommandItem(
      id: 'cmd_fake',
      deviceId: deviceId,
      prompt: prompt,
      mode: mode,
      status: 'pending',
      workspace: workspace,
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
