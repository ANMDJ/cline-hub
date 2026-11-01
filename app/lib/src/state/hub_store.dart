import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/hub_api.dart';
import '../data/settings_store.dart';
import '../models/models.dart';

/// 与服务端 SSE 的连接状态。
enum LinkState { idle, connecting, live, retrying, offline }

/// 页面级状态仓库：三份列表 + 事件流 + 分页游标。
///
/// 只用 ChangeNotifier 是有意选择：依赖越少，几年后越容易还跑得起来。
class HubStore extends ChangeNotifier {
  HubStore({
    required this.settings,
    HubApi Function(SettingsStore settings)? apiFactory,
  }) : api = (apiFactory ?? _defaultApi)(settings);

  static HubApi _defaultApi(SettingsStore settings) =>
      HttpHubApi(baseUrl: settings.baseUrl, token: settings.token);

  final SettingsStore settings;
  final HubApi api;

  // ---------------------------------------------------------------- sessions
  List<SessionItem> sessions = <SessionItem>[];
  bool loadingSessions = false;
  bool loadingMoreSessions = false;
  bool hasMoreSessions = false;
  String? sessionsError;
  String query = '';
  String? _sessionCursor;

  // ---------------------------------------------------------------- commands
  List<CommandItem> commands = <CommandItem>[];
  bool loadingCommands = false;
  String? commandsError;

  // ------------------------------------------------------------------- hooks
  List<HookItem> hooks = <HookItem>[];
  bool loadingHooks = false;
  bool hasMoreHooks = false;
  String? hooksError;
  int? _hookCursor;

  // -------------------------------------------------------------------- link
  LinkState link = LinkState.idle;
  DateTime? lastEventAt;
  String? linkError;

  int _attempt = 0;
  int _ticks = 0;
  bool _started = false;
  bool _paused = false;
  bool _disposed = false;
  StreamSubscription<HubEvent>? _sub;
  Timer? _reconnectTimer;
  Timer? _sessionDebounce;

  /// 已知设备 id：优先设置里的，其次从已有数据里猜。
  List<String> get knownDevices {
    final ids = <String>{
      if (settings.deviceId.isNotEmpty) settings.deviceId,
      ...commands.map((item) => item.deviceId),
      ...sessions.map((item) => item.deviceId),
      ...hooks.map((item) => item.deviceId ?? ''),
    }..removeWhere((id) => id.isEmpty);
    return ids.toList()..sort();
  }

  String get activeDeviceId {
    if (settings.deviceId.isNotEmpty) return settings.deviceId;
    final known = knownDevices;
    return known.isEmpty ? '' : known.first;
  }

  int get activeCommandCount => commands.where((item) => item.isActive).length;

  // ------------------------------------------------------------- sessions API
  Future<void> refreshSessions() async {
    if (_disposed || loadingSessions) return;
    loadingSessions = true;
    sessionsError = null;
    notifyListeners();
    try {
      final page = await api.sessions(
        limit: 30,
        query: query.isEmpty ? null : query,
      );
      sessions = List<SessionItem>.of(page.items);
      _sessionCursor = page.nextCursor;
      hasMoreSessions = page.nextCursor != null;
    } on ApiException catch (error) {
      sessionsError = error.friendly;
    } catch (error) {
      sessionsError = '$error';
    } finally {
      if (!_disposed) {
        loadingSessions = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadMoreSessions() async {
    final cursor = _sessionCursor;
    if (_disposed || loadingMoreSessions || cursor == null) return;
    loadingMoreSessions = true;
    notifyListeners();
    try {
      final page = await api.sessions(
        limit: 30,
        cursor: cursor,
        query: query.isEmpty ? null : query,
      );
      final seen = sessions
          .map((item) => '${item.deviceId}/${item.sessionId}')
          .toSet();
      sessions = <SessionItem>[
        ...sessions,
        ...page.items.where(
          (item) => !seen.contains('${item.deviceId}/${item.sessionId}'),
        ),
      ];
      _sessionCursor = page.nextCursor;
      hasMoreSessions = page.nextCursor != null;
    } on ApiException catch (error) {
      sessionsError = error.friendly;
    } finally {
      if (!_disposed) {
        loadingMoreSessions = false;
        notifyListeners();
      }
    }
  }

  Future<void> setQuery(String value) async {
    final next = value.trim();
    if (next == query) return;
    query = next;
    _sessionCursor = null;
    await refreshSessions();
  }

  // ------------------------------------------------------------- commands API
  Future<void> refreshCommands() async {
    if (_disposed || loadingCommands) return;
    loadingCommands = true;
    commandsError = null;
    notifyListeners();
    try {
      commands = List<CommandItem>.of(await api.commands(limit: 50));
    } on ApiException catch (error) {
      commandsError = error.friendly;
    } catch (error) {
      commandsError = '$error';
    } finally {
      if (!_disposed) {
        loadingCommands = false;
        notifyListeners();
      }
    }
  }

  Future<CommandItem> sendCommand({
    required String prompt,
    required String mode,
    String? workspace,
    String? deviceId,
  }) async {
    final target = (deviceId == null || deviceId.trim().isEmpty)
        ? activeDeviceId
        : deviceId.trim();
    if (target.isEmpty) {
      throw ApiException(0, 'no_device', '还没确定执行设备：先在设置里填一个 deviceId');
    }
    final created = await api.sendCommand(
      deviceId: target,
      prompt: prompt,
      mode: mode,
      workspace: workspace,
    );
    _upsertCommand(created);
    notifyListeners();
    return created;
  }

  // ---------------------------------------------------------------- hooks API
  Future<void> refreshHooks() async {
    if (_disposed || loadingHooks) return;
    loadingHooks = true;
    hooksError = null;
    notifyListeners();
    try {
      hooks = List<HookItem>.of(await api.hooks(limit: 50));
      _hookCursor = hooks.isEmpty ? null : hooks.last.id;
      hasMoreHooks = hooks.length >= 50;
    } on ApiException catch (error) {
      hooksError = error.friendly;
    } catch (error) {
      hooksError = '$error';
    } finally {
      if (!_disposed) {
        loadingHooks = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadMoreHooks() async {
    final cursor = _hookCursor;
    if (_disposed || loadingHooks || cursor == null) return;
    loadingHooks = true;
    notifyListeners();
    try {
      final page = await api.hooks(limit: 50, beforeId: cursor);
      final seen = hooks.map((item) => item.id).toSet();
      hooks = <HookItem>[
        ...hooks,
        ...page.where((item) => !seen.contains(item.id)),
      ];
      _hookCursor = hooks.isEmpty ? null : hooks.last.id;
      hasMoreHooks = page.length >= 50;
    } on ApiException catch (error) {
      hooksError = error.friendly;
    } finally {
      if (!_disposed) {
        loadingHooks = false;
        notifyListeners();
      }
    }
  }

  // ------------------------------------------------------------------ 生命周期
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    await refreshAll();
    _connect();
  }

  /// 退到后台就主动断流：SSE 挂着只会白烧电，回到前台再拉一次最新数据。
  void pause() {
    if (_paused || _disposed) return;
    _paused = true;
    _sub?.cancel();
    _sub = null;
    _reconnectTimer?.cancel();
    link = LinkState.idle;
    notifyListeners();
  }

  void resume() {
    if (!_paused || _disposed) return;
    _paused = false;
    _attempt = 0;
    unawaited(refreshAll());
    _connect();
  }

  // ---------------------------------------------------------------- SSE 连接
  void _connect() {
    if (_disposed || _paused) return;
    _sub?.cancel();
    if (link != LinkState.retrying) {
      link = LinkState.connecting;
      notifyListeners();
    }
    _sub = api.events().listen(
      _onEvent,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: true,
    );
  }

  void _onEvent(HubEvent event) {
    if (_disposed) return;
    _attempt = 0;
    lastEventAt = DateTime.now();
    linkError = null;
    final wasLive = link == LinkState.live;
    link = LinkState.live;

    switch (event.type) {
      case 'session':
        _scheduleSessionRefresh();
      case 'hook':
        _upsertHook(HookItem.fromJson(event.data));
      case 'command':
      case 'command.update':
        final item = CommandItem.fromJson(event.data);
        if (item.id.isNotEmpty) _upsertCommand(item);
      case 'tick':
        _refreshTick();
      default:
        break;
    }
    if (!wasLive || event.type != 'tick') notifyListeners();
  }

  void _onDone() {
    if (_disposed || _paused) return;
    link = LinkState.retrying;
    notifyListeners();
    _scheduleReconnect();
  }

  void _onError(Object error) {
    if (_disposed || _paused) return;
    linkError = error is ApiException ? error.friendly : '$error';
    if (error is ApiException && error.isAuth) {
      // token 废了就别再敲服务器，让用户去设置页换一个
      link = LinkState.offline;
      notifyListeners();
      return;
    }
    link = LinkState.retrying;
    notifyListeners();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    const delays = <int>[1, 2, 5, 10, 20];
    final seconds = delays[_attempt.clamp(0, delays.length - 1)];
    _attempt = (_attempt + 1).clamp(0, delays.length);
    _reconnectTimer = Timer(Duration(seconds: seconds), _connect);
  }

  /// 一次上报可能连着来好几条 session 事件，合并成一次刷新。
  void _scheduleSessionRefresh() {
    _sessionDebounce?.cancel();
    _sessionDebounce = Timer(const Duration(milliseconds: 900), () {
      unawaited(refreshSessions());
    });
  }

  /// web 端没有真 SSE，靠这个节拍轮询；Android 上只有 25s 一次的心跳帧，不会走到这里。
  void _refreshTick() {
    _ticks++;
    if (_ticks % 2 == 1) unawaited(refreshCommands());
    if (_ticks % 3 == 0) unawaited(refreshHooks());
    if (_ticks % 5 == 0) unawaited(refreshSessions());
  }

  void _upsertCommand(CommandItem item) {
    final index = commands.indexWhere((entry) => entry.id == item.id);
    if (index < 0) {
      commands = <CommandItem>[item, ...commands];
      return;
    }
    final next = List<CommandItem>.of(commands);
    next[index] = item;
    commands = next;
  }

  void _upsertHook(HookItem item) {
    if (item.id == 0 || hooks.any((entry) => entry.id == item.id)) return;
    hooks = <HookItem>[item, ...hooks];
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _reconnectTimer?.cancel();
    _sessionDebounce?.cancel();
    unawaited(api.close());
    super.dispose();
  }

  Future<void> refreshAll() async {
    await Future.wait<void>(<Future<void>>[
      refreshSessions(),
      refreshCommands(),
      refreshHooks(),
    ]);
  }
}
