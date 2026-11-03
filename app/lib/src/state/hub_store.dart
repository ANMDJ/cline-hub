import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/file_picker.dart';
import '../data/hub_api.dart';
import '../data/notifier.dart';
import '../data/settings_store.dart';
import '../models/models.dart';
import '../util/format.dart';

/// 与服务端 SSE 的连接状态。
enum LinkState { idle, connecting, live, retrying, offline }

/// 会话列表按工作目录聚合出的一个组（列表里可折叠）。
class SessionGroup {
  const SessionGroup({
    required this.key,
    required this.label,
    required this.path,
    required this.items,
    required this.deviceId,
    this.loose = false,
  });

  /// 折叠状态的键：`<设备>|<项目键>`。
  ///
  /// 设备必须进键里：`C:\work\b` 在两台电脑上是两个目录（内容可能不同），
  /// 只按项目路径合并会让组头「12 条」混着两台机器的会话。
  final String key;

  /// 组头显示的项目名，如 `kids_points_app`。
  final String label;

  /// 完整绝对路径；拿不到时为 null（组头只显示项目名）。
  final String? path;

  /// 这一组会话来自哪台电脑（Hub 的 device id）。
  final String deviceId;

  /// 散会话（`projectKind=loose`，家目录等）：工作区页永远排在最后。
  final bool loose;

  final List<SessionItem> items;
}

/// 页面级状态仓库：三份列表 + 事件流 + 分页游标。
///
/// 只用 ChangeNotifier 是有意选择：依赖越少，几年后越容易还跑得起来。
class HubStore extends ChangeNotifier {
  HubStore({
    required this.settings,
    HubApi Function(SettingsStore settings)? apiFactory,
    HubNotifier? notifier,
  }) : api = (apiFactory ?? _defaultApi)(settings),
       notifier = notifier ?? LocalHubNotifier();

  static HubApi _defaultApi(SettingsStore settings) =>
      HttpHubApi(baseUrl: settings.baseUrl, token: settings.token);

  final SettingsStore settings;
  final HubApi api;

  /// 通知出口：Android 走原生 MethodChannel，Web / 测试注入 Noop 实现。
  final HubNotifier notifier;

  // ---------------------------------------------------------------- sessions
  List<SessionItem> sessions = <SessionItem>[];
  bool loadingSessions = false;
  bool loadingMoreSessions = false;
  bool hasMoreSessions = false;
  String? sessionsError;
  String query = '';
  String? _sessionCursor;

  /// 工作区二级页的数据源：进页时单独整批拉一次（服务端 `limit` 上限 200），
  /// 这样组头的「N 条」统计的是全部会话，而不是主列表恰好翻到了哪儿。
  List<SessionItem> workspaceSessions = <SessionItem>[];
  bool loadingWorkspaces = false;
  String? workspacesError;

  /// 主列表首屏 / 每次上拉条数。
  static const int sessionPageSize = 60;

  /// 工作区页整批拉取的条数（= 服务端 `limitFrom(url, 50, 200)` 的上限）。
  static const int workspaceOverviewLimit = 200;

  // ----------------------------------------------------------------- devices
  /// Hub 上所有电脑端（bridge）。用来渲染设备列表卡片与筛选 chip 的显示名。
  List<DeviceItem> devices = <DeviceItem>[];
  bool loadingDevices = false;
  String? devicesError;

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

  /// 已弹过通知的键（`commandId:status` / `hook:<id>`）：
  /// SSE 与「回前台补拉」可能同时命中同一条，只弹一次。
  final Set<String> _notified = <String>{};

  /// 会话 id → 第一次提醒的时间。
  ///
  /// 一次远程命令会同时产生两条终态：`command.update`（done/failed）和 bridge
  /// 从 `sessions.db` 跃迁合出来的 `session_done`（那条命令开出来的会话）。
  /// 它们描述的是**同一件事**，但键不同（`cmd_x:done` / `hook:185`），
  /// 所以会并排弹两条：命令一结束先响「命令完成 · ACT」，30 秒后
  /// （`COMPLETION_SETTLE_MS`）再响「会话完成 · cline-hub」。
  /// 息屏期间断流、回前台补发时最明显——用户看到的就是「同一个任务两条消息」。
  ///
  /// 归并键用 `sessionId`（命令执行时 bridge 会 PATCH 回写），只在这个窗口内算同一次任务：
  /// 同一个会话几小时后重新跑一轮，应该再提醒。
  final Map<String, DateTime> _notifiedTasks = <String, DateTime>{};

  static const Duration _taskDedupeWindow = Duration(minutes: 15);

  /// 退到后台时还在跑的命令 id：回前台如果已经结束，补一条通知。
  Set<String> _activeAtPause = <String>{};

  /// 当前是否在后台（`pause()` / `resume()` 维护）。
  ///
  /// 与 `_paused` 分开：保活期间 App 在后台但 SSE 没断（`_paused=false`），
  /// 等保活结束时才需要按「后台」策略补一次断流。
  bool _backgrounded = false;

  static const Set<String> _terminalStatuses = <String>{
    'done',
    'failed',
    'cancelled',
  };

  /// bridge 自己合成的会话终态事件（见 `bridge/src/index.js` 的 emitCompletion）。
  /// 只认这三个，不认 `agent_*`：那边是 Cline hook，和 sessions.db 的状态跃迁会重复。
  static const Set<String> _terminalSessionEvents = <String>{
    'session_done',
    'session_failed',
    'session_cancelled',
  };

  /// 已知设备 id：优先设置里的，其次 Hub 的设备列表，最后从已有数据里兜底猜
  /// （老版本 Hub 没有 `/api/v1/devices` 时，chip 仍然能用）。
  List<String> get knownDevices {
    final ids = <String>{
      if (settings.deviceId.isNotEmpty) settings.deviceId,
      ...devices.map((item) => item.id),
      ...commands.map((item) => item.deviceId),
      ...sessions.map((item) => item.deviceId),
      ...hooks.map((item) => item.deviceId ?? ''),
    }..removeWhere((id) => id.isEmpty);
    return ids.toList()..sort();
  }

  /// 设备 chip 的显示名：能查到就显示 `name`，否则退回 id。
  String deviceLabel(String deviceId) {
    for (final item in devices) {
      if (item.id == deviceId) return item.label;
    }
    return deviceId;
  }

  String get activeDeviceId {
    if (settings.deviceId.isNotEmpty) return settings.deviceId;
    final known = knownDevices;
    return known.isEmpty ? '' : known.first;
  }

  /// 设备过滤（`null` = 全部设备）。只影响列表展示，不改请求参数。
  String? _deviceFilter;

  String? get deviceFilter => _deviceFilter;

  void setDeviceFilter(String? deviceId) {
    final next = (deviceId ?? '').trim().isEmpty ? null : deviceId!.trim();
    if (next == _deviceFilter) return;
    _deviceFilter = next;
    notifyListeners();
  }

  bool _onDevice(String deviceId) =>
      _deviceFilter == null || deviceId == _deviceFilter;

  /// 当前设备过滤下的会话 / 命令 / 动态。
  ///
  /// 过滤放在本地是有意的：服务端一次只给 50–60 条，多打一次请求换不来什么，
  /// 反而要和分页游标配合。`sessions` / `commands` / `hooks` 仍是全量。
  List<SessionItem> get visibleSessions => _deviceFilter == null
      ? sessions
      : sessions
            .where((item) => _onDevice(item.deviceId))
            .toList(growable: false);

  List<CommandItem> get visibleCommands => _deviceFilter == null
      ? commands
      : commands
            .where((item) => _onDevice(item.deviceId))
            .toList(growable: false);

  List<HookItem> get visibleHooks => _deviceFilter == null
      ? hooks
      : hooks
            .where((item) => _onDevice(item.deviceId ?? ''))
            .toList(growable: false);

  /// 下发面板「工作目录」的候选：会话 / 命令 / 动态里出现过的**绝对路径**。
  ///
  /// 只收绝对路径是因为 bridge 的 `resolveWorkspace()` 用 `fs.existsSync()`
  /// 判断目录存不存在：`session.workspace` 那种相对名（`kids_points_app`）
  /// 必然落空，会静默退回 `commands.defaultWorkspace`，界面上给了反而误导。
  /// 按出现次数降序、去重，最多 6 条 —— 手机屏幕放不下更多。
  List<String> get knownWorkspaces {
    // 同一个目录的两种写法（`C:\a` / `C:/a`）只留一个 chip：按归一化后的键计数，
    // 展示值保留第一次见到的写法（服务端入库时已统一成反斜杠）。
    final counts = <String, int>{};
    final labels = <String, String>{};
    void bump(String? raw) {
      final value = (raw ?? '').trim();
      if (!_looksAbsolute(value)) return;
      final key = _pathKey(value);
      labels.putIfAbsent(key, () => value);
      counts[key] = (counts[key] ?? 0) + 1;
    }

    for (final item in sessions) {
      bump(item.workspaceRoot);
    }
    for (final item in commands) {
      bump(item.workspace);
    }
    for (final item in hooks) {
      bump(item.workspace);
    }

    final ranked = counts.entries.toList()
      ..sort(
        (a, b) => a.value == b.value
            ? a.key.compareTo(b.key)
            : b.value.compareTo(a.value),
      );
    return <String>[
      for (final entry in ranked.take(6)) labels[entry.key] ?? entry.key,
    ];
  }

  static final RegExp _windowsPath = RegExp(r'^[a-zA-Z]:[\\/]');
  static bool _looksAbsolute(String value) =>
      value.startsWith('/') || _windowsPath.hasMatch(value);

  /// 路径比较键：`C:\a\b`、`C:/a/b`、`C:\a\b\` 都归一成 `c:/a/b`。
  ///
  /// 只用于「是不是同一个目录」的判断（分组 / 去重），不改界面上的展示值。
  /// cline CLI 写 `sessions.db` 用正斜杠、bridge 白名单是人手填的反斜杠，
  /// 不归一化时同一个项目会显示成两组（2026-11-02 实测 `...\cline-hub` 31 条
  /// 与 `.../cline-hub` 1 条并排）。
  static String _pathKey(String value) {
    final slashed = value.trim().replaceAll('\\', '/');
    final collapsed = slashed.replaceAll(RegExp(r'/+'), '/');
    final trimmed = collapsed.length > 1 && collapsed.endsWith('/')
        ? collapsed.substring(0, collapsed.length - 1)
        : collapsed;
    return trimmed.toLowerCase();
  }

  /// 会话按「设备 + 工作目录」分组：组顺序跟每组第一条会话走（列表本身按时间倒序），
  /// 组内保持原顺序。同一台机器上同一个目录的不同写法（大小写 / 分隔符 / 尾斜杠）
  /// 会并成一组；不同机器的同名项目各成一组，组头显示来自哪台电脑。
  List<SessionGroup> get sessionGroups {
    // 工作区页优先用整批数据；还没拉到（或拉失败）时退回主列表已加载的部分。
    final source = (workspaceSessions.isNotEmpty ? workspaceSessions : sessions)
        .where((item) => _onDevice(item.deviceId))
        .toList(growable: false);
    final buckets = <String, List<SessionItem>>{};
    for (final item in source) {
      buckets.putIfAbsent(_groupKey(item), () => <SessionItem>[]).add(item);
    }
    return <SessionGroup>[
      for (final entry in buckets.entries)
        SessionGroup(
          key: entry.key,
          label: _groupLabel(entry.value.first),
          path: _absoluteWorkspace(entry.value.first),
          deviceId: entry.value.first.deviceId,
          loose: _isLoose(entry.value.first),
          items: entry.value,
        ),
    ];
  }

  /// 绝对工作目录：`workspaceRoot` 是完整路径，`workspace` 通常只是项目名。
  static String? _absoluteWorkspace(SessionItem item) {
    final root = (item.workspaceRoot ?? '').trim();
    if (_looksAbsolute(root)) return root;
    final name = (item.workspace ?? '').trim();
    if (_looksAbsolute(name)) return name;
    return null;
  }

  /// 分组键 = `<设备>|<项目键>`。
  ///
  /// 设备前缀不能省：两台电脑都有 `cline-hub` 时，它们的绝对路径不同
  /// （`C:\Users\a\...` / `C:\work\...`），但「项目名兜底」分支会撞进同一组；
  /// 而同名项目在两台机器上本来就不是同一堆会话。
  static String _groupKey(SessionItem item) {
    final device = item.deviceId.trim().toLowerCase();
    final scope = device.isEmpty ? '' : '$device|';
    // 有 project 信息时按「项目根」分组；loose（家目录等）统一进散会话。
    final kind = (item.projectKind ?? '').trim();
    final project = (item.project ?? '').trim();
    final root = (item.projectRoot ?? '').trim();
    if (kind.isNotEmpty || project.isNotEmpty) {
      if (_isLoose(item)) return '${scope}__loose__';
      return root.isNotEmpty
          ? '$scope${_pathKey(root)}'
          : '${scope}project:${project.toLowerCase()}';
    }
    // 旧数据（还没回填 project）：保持按绝对路径分组，但同样走路径键，
    // 否则 `C:\...\cline-hub` 与 `C:/.../cline-hub` 会并排显示两组。
    final path = _absoluteWorkspace(item);
    if (path != null) return '$scope${_pathKey(path)}';
    final name = (item.workspace ?? '').trim();
    return name.isEmpty ? scope : '${scope}name:${name.toLowerCase()}';
  }

  /// 有项目字段、但属于松散会话（家目录里临时聊的）。
  static bool _isLoose(SessionItem item) {
    final kind = (item.projectKind ?? '').trim();
    final project = (item.project ?? '').trim();
    if (kind.isEmpty && project.isEmpty) return false;
    return kind == 'loose' || project.isEmpty;
  }

  static String _groupLabel(SessionItem item) {
    if (_isLoose(item)) return '散会话（无项目）';
    final kind = (item.projectKind ?? '').trim();
    final project = (item.project ?? '').trim();
    if (kind.isNotEmpty || project.isNotEmpty) {
      return project;
    }
    final name = (item.workspace ?? '').trim();
    if (name.isNotEmpty) return name;
    final path = _absoluteWorkspace(item);
    if (path != null) {
      final parts = path
          .split(RegExp(r'[\\/]'))
          .where((part) => part.isNotEmpty)
          .toList(growable: false);
      if (parts.isNotEmpty) return parts.last;
    }
    return '未标注工作区';
  }

  int get activeCommandCount => commands.where((item) => item.isActive).length;

  // ------------------------------------------------------------- 前台保活（P34）
  /// 保活前台服务当前是否处于「已拉起」状态。
  ///
  /// 只在有活跃命令且链路可用时存在：SSE 挂了（401 等）挂着服务也没有意义。
  /// 只在内存里，进程重启后由 [refreshCommands] 重新判定。
  bool _keepAliveOn = false;

  /// 活跃命令数变化后调用：0→1 开服务、1→0 停，幂等。
  ///
  /// 为什么不监听生命周期：回前台就停会让「再进后台」变成后台启动 FGS，
  /// Android 11+ 会直接拒绝。命令跑的这几分钟留着常驻通知，顺便当状态指示。
  void _syncKeepAlive() {
    if (_disposed) return;
    final want = settings.keepAliveEnabled &&
        notifier.supported &&
        activeCommandCount > 0 &&
        link != LinkState.offline;
    if (want == _keepAliveOn) return;
    _keepAliveOn = want;
    if (want) {
      final count = activeCommandCount;
      unawaited(
        notifier.startKeepAlive(
          count == 1 ? '有 1 条命令正在执行' : '有 $count 条命令正在执行',
        ),
      );
    } else {
      unawaited(notifier.stopKeepAlive());
      // 后台且已无活跃命令：不用再保活，按原策略断流省电。
      if (_backgrounded && activeCommandCount == 0) _pauseNow();
    }
  }

  /// 设置页改了「锁屏也提醒」后调用：立刻按新开关调整，不用等下一条命令。
  void syncKeepAliveNow() => _syncKeepAlive();

  // ------------------------------------------------------------- sessions API
  Future<void> refreshSessions() async {
    if (_disposed || loadingSessions) return;
    loadingSessions = true;
    sessionsError = null;
    notifyListeners();
    try {
      final page = await api.sessions(
        limit: sessionPageSize,
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
        limit: sessionPageSize,
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

  /// 工作区页进页时调用：整批拉一次，用于按项目分组统计。
  ///
  /// 不复用主列表的 `sessions`，因为主列表是「滚到哪算哪」的分页结果，
  /// 用它分组会让组头条数偏小（实测只加载 30 条时 cline-hub 只显示 1 条）。
  Future<void> refreshWorkspaceOverview({bool force = false}) async {
    if (_disposed || loadingWorkspaces) return;
    if (!force && workspaceSessions.isNotEmpty) {
      // 已经拉过：静默刷新，页面上不出现骨架/转圈。
      unawaited(_reloadWorkspaceOverview());
      return;
    }
    loadingWorkspaces = true;
    workspacesError = null;
    notifyListeners();
    await _reloadWorkspaceOverview();
    if (!_disposed) {
      loadingWorkspaces = false;
      notifyListeners();
    }
  }

  Future<void> _reloadWorkspaceOverview() async {
    try {
      final page = await api.sessions(limit: workspaceOverviewLimit);
      workspaceSessions = List<SessionItem>.of(page.items);
      workspacesError = null;
    } on ApiException catch (error) {
      workspacesError = error.friendly;
    } catch (error) {
      workspacesError = '$error';
    }
  }

  Future<void> setQuery(String value) async {
    final next = value.trim();
    if (next == query) return;
    query = next;
    _sessionCursor = null;
    await refreshSessions();
  }

  // -------------------------------------------------------------- devices API
  Future<void> refreshDevices() async {
    if (_disposed || loadingDevices) return;
    loadingDevices = true;
    devicesError = null;
    notifyListeners();
    try {
      devices = List<DeviceItem>.of(await api.devices());
    } on ApiException catch (error) {
      devicesError = error.friendly;
    } catch (error) {
      devicesError = '$error';
    } finally {
      if (!_disposed) {
        loadingDevices = false;
        notifyListeners();
      }
    }
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
        // 启动时会把「已经在跑」的命令一起拉回来，这里决定要不要开保活。
        _syncKeepAlive();
        notifyListeners();
      }
    }
  }

  Future<CommandItem> sendCommand({
    required String prompt,
    required String mode,
    String? workspace,
    String? deviceId,
    String? attachmentId,
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
      attachmentId: attachmentId,
    );
    _upsertCommand(created);
    // 新命令是 pending：这是「0→1」，App 此时在前台，启动 FGS 合法。
    _syncKeepAlive();
    notifyListeners();
    return created;
  }

  /// 上传附件（文件 / 图片）到 Hub，拿到 [sendCommand] 要的 `attachmentId`。
  ///
  /// 设备在**上传时**就定下来：服务端会校验「命令的 deviceId 必须与附件一致」，
  /// 避免 A 电脑的附件被发给 B 电脑（见 docs/api.md）。
  Future<AttachmentInfo> uploadAttachment({
    required PickedAttachment file,
    String? deviceId,
  }) async {
    final target = (deviceId == null || deviceId.trim().isEmpty)
        ? activeDeviceId
        : deviceId.trim();
    if (target.isEmpty) {
      throw ApiException(0, 'no_device', '还没确定执行设备：先在设置里填一个 deviceId');
    }
    return api.uploadAttachment(
      deviceId: target,
      name: file.name,
      mimeType: file.mimeType,
      bytes: file.bytes,
    );
  }

  /// 把某台电脑设为默认下发目标（右侧菜单 / 设置页共用）。
  ///
  /// `settings` 只通知自己的监听者，所以这里补一次 `notifyListeners()`：
  /// 菜单里的「默认」标记与下发面板的预填设备要立刻跟着变。
  Future<void> setDefaultDevice(String deviceId) async {
    final next = deviceId.trim();
    if (next.isEmpty || next == settings.deviceId) return;
    await settings.setDeviceId(next);
    if (!_disposed) notifyListeners();
  }

  /// 取消一条还没结束的命令（P14）。
  ///
  /// 服务端返回的是一条**新状态**的命令：排队中的直接 `cancelled`，
  /// 执行中的先 `cancelling`，bridge 收尾后 SSE 会再推一条 `cancelled`。
  /// 这里先把列表更新掉，用户不用等下一轮刷新才看到「取消中」。
  Future<CommandItem> cancelCommand(String id) async {
    final updated = await api.cancelCommand(id);
    final previous = _upsertCommand(updated);
    // 排队中取消是直接终态：通知规则同「命令结束」，别让用户以为它还在跑。
    _maybeNotifyCommand(previous, updated);
    _syncKeepAlive();
    notifyListeners();
    return updated;
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

  /// 退到后台：默认断流省电（SSE 挂着白烧电，回前台再拉一次最新数据）。
  ///
  /// 例外是**保活服务在跑**（P34）：那条常驻通知的目的就是让 App 在后台
  /// 继续收事件，断掉 SSE 等于把保活做成了纯摆设。这时只记下在跑的命令，
  /// 等活跃数归 0（服务停）时由 [_syncKeepAlive] 再按原策略断流。
  void pause() {
    if (_disposed) return;
    _backgrounded = true;
    if (_keepAliveOn) {
      // 不断流：仍记一份，覆盖极短的断线窗口（见 _refreshAfterResume）。
      _activeAtPause = commands
          .where((item) => item.isActive)
          .map((item) => item.id)
          .toSet();
      return;
    }
    _pauseNow();
  }

  /// 真正取消 SSE 订阅并回到 idle。
  void _pauseNow() {
    if (_paused || _disposed) return;
    _paused = true;
    // 后台期间收不到 SSE：先记下还在跑的命令，回前台时补通知（见 _refreshAfterResume）。
    _activeAtPause = commands
        .where((item) => item.isActive)
        .map((item) => item.id)
        .toSet();
    _sub?.cancel();
    _sub = null;
    _reconnectTimer?.cancel();
    link = LinkState.idle;
    notifyListeners();
  }

  void resume() {
    if (_disposed) return;
    final wasBackground = _backgrounded;
    _backgrounded = false;
    final wasActive = _activeAtPause;
    _activeAtPause = <String>{};
    if (!_paused) {
      // 保活期间 SSE 一直连着：仍补一次，覆盖断线窗口里漏掉的事件。
      if (wasBackground) unawaited(_refreshAfterResume(wasActive));
      return;
    }
    _paused = false;
    _attempt = 0;
    unawaited(_refreshAfterResume(wasActive));
    _connect();
  }

  /// 回前台：先拉最新数据，再把「后台期间已经结束的命令」补一条通知。
  Future<void> _refreshAfterResume(Set<String> wasActive) async {
    await refreshAll();
    if (_disposed || wasActive.isEmpty) return;
    for (final item in commands) {
      if (wasActive.contains(item.id)) _notifyCommandResult(item);
    }
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
        final hook = HookItem.fromJson(event.data);
        if (_upsertHook(hook)) _maybeNotifyHook(hook);
      case 'command':
      case 'command.update':
        final item = CommandItem.fromJson(event.data);
        if (item.id.isEmpty) break;
        final previous = _upsertCommand(item);
        _maybeNotifyCommand(previous, item);
        _syncKeepAlive();
      case 'tick':
        _refreshTick();
      case 'open':
        // 服务端 ": connected" 的回应：单纯告诉上层链路通了，不用拉数据。
        break;
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
      // 链路断了，保活挂着也没意义：直接收掉常驻通知。
      _syncKeepAlive();
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

  /// 就地替换/插入命令；返回替换前的那一条（新命令返回 null）。
  CommandItem? _upsertCommand(CommandItem item) {
    final index = commands.indexWhere((entry) => entry.id == item.id);
    if (index < 0) {
      commands = <CommandItem>[item, ...commands];
      return null;
    }
    final next = List<CommandItem>.of(commands);
    final previous = next[index];
    next[index] = item;
    commands = next;
    return previous;
  }

  /// 返回是否是「第一次见到」，动态列表与通知都靠它去重。
  bool _upsertHook(HookItem item) {
    if (item.id == 0 || hooks.any((entry) => entry.id == item.id)) return false;
    hooks = <HookItem>[item, ...hooks];
    return true;
  }

  // ------------------------------------------------------------------ 通知
  /// 命令从「执行中」走到终态才弹：首次加载的一堆历史命令不该刷屏。
  void _maybeNotifyCommand(CommandItem? previous, CommandItem next) {
    if (previous == null || !previous.isActive) return;
    _notifyCommandResult(next);
  }

  void _notifyCommandResult(CommandItem item) {
    if (!settings.notifyCommands) return;
    if (!_terminalStatuses.contains(item.status)) return;
    final key = '${item.id}:${item.status}';
    if (!_notified.add(key)) return;
    // 同一条任务已经提醒过（例如先到的是 session_done）：不再弹第二条。
    if (_taskAlreadyNotified(item.sessionId)) return;

    final ok = item.status == 'done';
    final headline = switch (item.status) {
      'done' => '命令完成',
      'cancelled' => '命令已取消',
      _ => '命令失败',
    };
    final detail = ok
        ? (item.resultText ?? item.prompt)
        : (item.errorText ?? item.resultText ?? item.prompt);
    _rememberTask(item.sessionId);
    unawaited(
      notifier.show(
        HubNotification(
          key: key,
          title: '$headline · ${item.modeLabel}',
          body: _notificationBody(detail),
        ),
      ),
    );
  }

  /// 会话终态由 bridge 合成（`session_*`），只弹一次。
  void _maybeNotifyHook(HookItem item) {
    if (!settings.notifySessions) return;
    final event = item.event ?? '';
    if (!_terminalSessionEvents.contains(event)) return;
    final key = 'hook:${item.id}';
    if (!_notified.add(key)) return;
    // 远程命令跑出来的会话：命令那条已经提醒过（或即将提醒），别再弹一遍。
    if (_taskAlreadyNotified(item.sessionId)) return;

    final headline = switch (event) {
      'session_done' => '会话完成',
      'session_cancelled' => '会话已中断',
      _ => '会话失败',
    };
    final subject = _shorten(inlinePreview(item.title ?? ''), 40);
    _rememberTask(item.sessionId);
    unawaited(
      notifier.show(
        HubNotification(
          key: key,
          title: subject.isEmpty ? headline : '$headline · $subject',
          body: _notificationBody(item.body),
        ),
      ),
    );
  }

  /// 这个会话在归并窗口内是否已经提醒过（没有 sessionId 的历史数据一律算「没提醒过」）。
  bool _taskAlreadyNotified(String? sessionId) {
    final id = (sessionId ?? '').trim();
    if (id.isEmpty) return false;
    final at = _notifiedTasks[id];
    if (at == null) return false;
    if (DateTime.now().difference(at) > _taskDedupeWindow) {
      _notifiedTasks.remove(id);
      return false;
    }
    return true;
  }

  void _rememberTask(String? sessionId) {
    final id = (sessionId ?? '').trim();
    if (id.isEmpty) return;
    if (_notifiedTasks.length >= 300) {
      final cutoff = DateTime.now().subtract(_taskDedupeWindow);
      _notifiedTasks.removeWhere((_, at) => at.isBefore(cutoff));
      if (_notifiedTasks.length >= 300) _notifiedTasks.clear();
    }
    _notifiedTasks[id] = DateTime.now();
  }

  /// 通知正文：去 ANSI、折叠空白、截到一行能读的长度（按码点切，不劈开 emoji）。
  static String _notificationBody(String? text) {
    final plain = inlinePreview(text ?? '');
    if (plain.isEmpty) return '（没有输出）';
    return _shorten(plain, 160);
  }

  static String _shorten(String text, int max) {
    final points = text.runes.toList(growable: false);
    if (points.length <= max) return text;
    return '${String.fromCharCodes(points.take(max - 1))}…';
  }

  @override
  void dispose() {
    _disposed = true;
    if (_keepAliveOn) {
      _keepAliveOn = false;
      unawaited(notifier.stopKeepAlive());
    }
    _sub?.cancel();
    _reconnectTimer?.cancel();
    _sessionDebounce?.cancel();
    unawaited(api.close());
    super.dispose();
  }

  Future<void> refreshAll() async {
    await Future.wait<void>(<Future<void>>[
      refreshDevices(),
      refreshSessions(),
      refreshCommands(),
      refreshHooks(),
    ]);
  }
}
