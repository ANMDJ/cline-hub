import 'package:flutter/material.dart';

import '../data/app_version.dart';
import '../models/models.dart';
import '../state/hub_store.dart';
import 'theme.dart';
import 'widgets.dart';

/// 右侧划出菜单：已接入的电脑 + 设置入口（P38）。
///
/// 设备列表原来塞在设置页里，用手机时要「先点齿轮、再往下滚」才看得到哪台在线。
/// 挪到常驻抽屉后：顶栏只留连接状态与一个菜单按钮，常用的「这台电脑在线吗 /
/// 切默认设备 / 刷新 / 进设置」都在一划之内。
class HomeDrawer extends StatelessWidget {
  const HomeDrawer({
    super.key,
    required this.store,
    required this.onOpenSettings,
  });

  final HubStore store;

  /// 由 HomeShell 提供：先关抽屉再 push，避免返回时抽屉还开着。
  final VoidCallback onOpenSettings;

  /// `GET /api/v1/devices` 没数据时退回「已知设备 id」，老 Hub 也还能用。
  List<DeviceItem> get _menuDevices {
    if (store.devices.isNotEmpty) return store.devices;
    return store.knownDevices
        .map((id) => DeviceItem(id: id))
        .toList(growable: false);
  }

  Future<void> _refresh(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await store.refreshAll();
    if (!context.mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('已刷新'), duration: Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final devices = _menuDevices;
    return Drawer(
      backgroundColor: kBg,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    gradient: const LinearGradient(
                      colors: [kAccent, Color(0xFF38BDF8)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: const Icon(
                    Icons.terminal_rounded,
                    size: 17,
                    color: Color(0xFF04140D),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Cline Console',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'v$kAppVersion（build $kAppBuild）',
                        style: const TextStyle(fontSize: 11, color: kMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _SectionTitle(
              title: '电脑',
              trailing: store.loadingDevices ? '刷新中…' : null,
            ),
            const SizedBox(height: 4),

            if (devices.isEmpty)
              Text(
                store.loadingDevices
                    ? '正在读取设备列表…'
                    : (store.devicesError != null
                          ? '读取失败：${store.devicesError}'
                          : '还没有电脑接入。在电脑上起 bridge 后点下面的「刷新数据」。'),
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: store.devicesError != null ? kWarn : kMuted,
                ),
              )
            else
              for (final device in devices) _deviceTile(context, device),
            const SizedBox(height: 6),
            const Text(
              '点一台电脑设为默认下发目标；在线 = 2 分钟内有上报。',
              style: TextStyle(fontSize: 10.5, height: 1.6, color: kMuted),
            ),
            const SizedBox(height: 14),
            const Divider(color: kLine, height: 1),
            const SizedBox(height: 8),
            _ActionTile(
              icon: Icons.refresh_rounded,
              label: '刷新数据',
              onTap: () => _refresh(context),
            ),
            _ActionTile(
              icon: Icons.settings_outlined,
              label: '设置',
              subtitle: store.settings.baseUrl,
              onTap: () {
                Navigator.of(context).pop();
                onOpenSettings();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _deviceTile(BuildContext context, DeviceItem device) {
    final online = device.isOnline;
    // 用 settings.deviceId 判断「默认」：activeDeviceId 在没设过时也会返回第一台，
    // 那样会把「还没选过」误标成已选。
    final isDefault = store.settings.deviceId == device.id;
    final name = device.label == device.id
        ? device.id
        : '${device.label} · ${device.id}';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          final messenger = ScaffoldMessenger.of(context);
          await store.setDefaultDevice(device.id);
          if (!context.mounted) return;
          messenger.showSnackBar(
            SnackBar(
              content: Text('默认执行设备已切到 ${device.label}'),
              duration: const Duration(seconds: 1),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: StatusDot(color: online ? kAccent : kMuted, size: 7),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: online ? kText : kMuted,
                            ),
                          ),
                        ),
                        if (isDefault) ...[
                          const SizedBox(width: 6),
                          Pill(label: '默认', color: kAccent),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${online ? '在线' : '离线'} · 会话 ${device.sessionCount} · '
                      '待执行 ${device.pendingCommands} · 执行中 ${device.runningCommands}',
                      style: const TextStyle(
                        fontSize: 11,
                        height: 1.5,
                        color: kMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                isDefault
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked,
                size: 17,
                color: isDefault ? kAccent : kMuted.withValues(alpha: 0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: kMuted,
          ),
        ),
        const Spacer(),
        if (trailing != null)
          Text(trailing!, style: const TextStyle(fontSize: 10.5, color: kMuted)),
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final detail = (subtitle ?? '').trim();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      leading: Icon(icon, size: 19, color: kMuted),
      title: Text(label, style: const TextStyle(fontSize: 13)),
      subtitle: detail.isEmpty
          ? null
          : Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10.5, color: kMuted),
            ),
      trailing: const Icon(Icons.chevron_right_rounded, size: 18, color: kMuted),
      onTap: onTap,
    );
  }
}

