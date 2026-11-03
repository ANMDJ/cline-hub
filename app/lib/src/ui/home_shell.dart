import 'dart:async';

import 'package:flutter/material.dart';

import '../data/hub_api.dart';
import '../data/settings_store.dart';
import '../state/hub_store.dart';
import '../util/format.dart';
import 'activity_page.dart';
import 'commands_page.dart';
import 'home_drawer.dart';
import 'new_command_sheet.dart';
import 'sessions_page.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'widgets.dart';

/// 三个 Tab 的外壳：会话 / 命令 / 动态，顶栏常驻连接状态。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.settings, this.apiFactory});

  final SettingsStore settings;
  final HubApi Function(SettingsStore settings)? apiFactory;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  late final HubStore _store;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _store = HubStore(settings: widget.settings, apiFactory: widget.apiFactory);
    WidgetsBinding.instance.addObserver(this);
    _store.start();
    _ensureNotificationPermission();
  }

  /// 首次进入确认一次通知权限（Android 13+ 才会弹系统框；已授权时是空操作）。
  /// 延迟 600ms 等启动页让位，避免系统权限框挡住首屏。
  Future<void> _ensureNotificationPermission() async {
    if (!widget.settings.notificationsEnabled) return;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    await _store.notifier.ensurePermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _store.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 后台不挂 SSE，回前台先拉一次再重连（响应里会带上离线期间的新数据）
    if (state == AppLifecycleState.resumed) {
      _store.resume();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _store.pause();
    }
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(settings: widget.settings, store: _store),
      ),
    );
  }

  /// 右侧菜单：设备列表 / 刷新 / 设置都在里面（P38）。
  ///
  /// 打开时顺手刷一次设备：在线状态靠 `lastSeenAt`，用户点开菜单就是想看
  /// 「电脑还在不在」，拿启动时那份数据会骗人。
  void _openMenu() {
    _scaffoldKey.currentState?.openEndDrawer();
    unawaited(_store.refreshDevices());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        return Scaffold(
          key: _scaffoldKey,
          appBar: AppBar(
            title: Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    gradient: const LinearGradient(
                      colors: [kAccent, Color(0xFF38BDF8)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: const Icon(
                    Icons.terminal_rounded,
                    size: 15,
                    color: Color(0xFF04140D),
                  ),
                ),
                const SizedBox(width: 9),
                const Text('Cline Console'),
              ],
            ),
            actions: [
              LinkBadge(
                state: _store.link,
                detail:
                    _store.linkError ??
                    (_store.lastEventAt == null
                        ? null
                        : '最后一条事件：${formatClock(_store.lastEventAt)}'),
              ),
              IconButton(
                onPressed: _openMenu,
                tooltip: '设备与设置',
                icon: const Icon(Icons.menu_rounded),
              ),
              const SizedBox(width: 4),
            ],
          ),
          endDrawer: HomeDrawer(store: _store, onOpenSettings: _openSettings),
          body: IndexedStack(
            index: _index,
            children: [
              SessionsPage(store: _store),
              CommandsPage(store: _store),
              ActivityPage(store: _store),
            ],
          ),
          floatingActionButton: _index == 1
              ? FloatingActionButton.extended(
                  onPressed: () => showNewCommandSheet(context, _store),
                  backgroundColor: kAccent,
                  foregroundColor: const Color(0xFF04140D),
                  icon: const Icon(Icons.bolt_rounded, size: 18),
                  label: const Text(
                    '下发命令',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                )
              : null,
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (index) => setState(() => _index = index),
            destinations: [
              NavigationDestination(
                icon: const Icon(Icons.forum_outlined),
                selectedIcon: const Icon(Icons.forum_rounded),
                label: _store.sessions.isEmpty
                    ? '会话'
                    : '会话 ${_store.sessions.length}',
              ),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: _store.activeCommandCount > 0,
                  label: Text('${_store.activeCommandCount}'),
                  child: const Icon(Icons.bolt_outlined),
                ),
                selectedIcon: Badge(
                  isLabelVisible: _store.activeCommandCount > 0,
                  label: Text('${_store.activeCommandCount}'),
                  child: const Icon(Icons.bolt_rounded),
                ),
                label: '命令',
              ),
              NavigationDestination(
                icon: const Icon(Icons.notifications_none_rounded),
                selectedIcon: const Icon(Icons.notifications_rounded),
                label: '动态',
              ),
            ],
          ),
        );
      },
    );
  }
}
