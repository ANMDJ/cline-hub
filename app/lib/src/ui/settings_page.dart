import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_update.dart';
import '../data/app_version.dart';
import '../data/hub_api.dart';
import '../data/link_launcher.dart';
import '../data/settings_store.dart';
import '../models/models.dart';
import '../state/hub_store.dart';
import '../util/format.dart';
import 'theme.dart';
import 'widgets.dart';

/// 设置：连接信息、健康检查、默认设备、换连接。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.settings, required this.store});

  final SettingsStore settings;
  final HubStore store;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _deviceCtrl = TextEditingController(
    text: widget.settings.deviceId,
  );
  bool _checking = false;
  String? _healthLine;
  String? _healthError;

  bool _checkingUpdate = false;
  bool _checkedUpdate = false;
  AppRelease? _release;
  String? _updateError;

  bool _requestingNotify = false;
  String? _notifyStatus;

  bool _loadingDevices = false;

  final LinkLauncher _links = const LinkLauncher();

  @override
  void initState() {
    super.initState();
    // 设置页打开时顺手刷新一次：在线状态 / 计数要新，不能只靠启动时那一次。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshDevices();
    });
  }

  Future<void> _refreshDevices() async {
    setState(() => _loadingDevices = true);
    await widget.store.refreshDevices();
    if (mounted) setState(() => _loadingDevices = false);
  }

  /// 把某台电脑设为默认下发目标（同时更新输入框，不用再手动保存一次）。
  Future<void> _useDevice(DeviceItem device) async {
    await widget.settings.setDeviceId(device.id);
    _deviceCtrl.text = device.id;
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('默认执行设备已切到 ${device.label}'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  /// 有新版本时直接交给系统浏览器下载，不用再「复制链接 → 打开浏览器 → 粘贴」。
  /// 打不开（Web 预览 / 没有浏览器 / 地址不合法）就退回复制，至少不会卡住。
  Future<void> _openDownload(AppRelease release) async {
    final url = release.apkUrl ?? '';
    final opened = await _links.open(url);
    if (!mounted || opened) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('这个环境打不开浏览器，已复制下载地址'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _requestNotifyPermission() async {
    setState(() => _requestingNotify = true);
    final granted = await widget.store.notifier.ensurePermission();
    if (!mounted) return;
    setState(() {
      _requestingNotify = false;
      _notifyStatus = widget.store.notifier.supported
          ? (granted ? '已允许' : '未授予：通知不会出现，去系统设置里打开')
          : '当前平台没有系统通知（Web 预览 / 测试）';
    });
  }

  @override
  void dispose() {
    _deviceCtrl.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _healthLine = null;
      _healthError = null;
    });
    try {
      final health = await widget.store.api.health();
      if (!mounted) return;
      setState(() {
        _healthLine =
            '${health.service} v${health.version} · 运行 ${formatUptime(health.uptimeSec)}\n'
            '数据库 ${health.dbOk ? '正常' : '异常'}（${health.dbLatencyMs ?? '?'}ms）· SSE 连接 ${health.sseClients} 条';
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _healthError = error.friendly);
    } catch (error) {
      if (mounted) setState(() => _healthError = '$error');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// 检查更新：读 Hub 的 `/api/v1/app/latest`（服务器上没有清单时返回 404）。
  Future<void> _checkUpdate() async {
    setState(() {
      _checkingUpdate = true;
      _checkedUpdate = true;
      _updateError = null;
    });
    try {
      final release = await fetchLatestRelease(
        baseUrl: widget.settings.baseUrl,
        token: widget.settings.token,
      );
      if (!mounted) return;
      setState(() => _release = release);
    } catch (error) {
      if (mounted) setState(() => _updateError = '$error');
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  void _showChangelog() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: kPanel,
        title: const Text('更新日志'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final entry in kChangelog) ...[
                Text(
                  '${entry.version} · ${entry.date}',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: kAccent,
                  ),
                ),
                const SizedBox(height: 4),
                for (final item in entry.items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      '· $item',
                      style: const TextStyle(fontSize: 12, height: 1.6),
                    ),
                  ),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveDevice() async {
    await widget.settings.setDeviceId(_deviceCtrl.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('默认设备已保存'), duration: Duration(seconds: 1)),
    );
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: kPanel,
        title: const Text('换一套连接？'),
        content: const Text(
          '会清空本机保存的地址和 token，回到首次启动的向导。App 里的数据都在服务器上，不会丢。',
          style: TextStyle(fontSize: 13, height: 1.6, color: kMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空并退出', style: TextStyle(color: kDanger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.settings.signOut();
    if (mounted) Navigator.of(context).pop();
  }

  String formatUptime(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    if (minutes < 60) return '${minutes}m';
    final hours = minutes ~/ 60;
    if (hours < 24) return '${hours}h${minutes % 60}m';
    return '${hours ~/ 24}d${hours % 24}h';
  }

  Widget _kv(String label, String value, {bool mono = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: kMuted, height: 1.5),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: mono
                  ? kMono
                  : const TextStyle(fontSize: 12.5, height: 1.5, color: kText),
            ),
          ),
        ],
      ),
    );
  }

  Widget _devicesBody() {
    final store = widget.store;
    if (store.devices.isEmpty) {
      if (_loadingDevices) {
        return const Text(
          '正在读取设备列表…',
          style: TextStyle(fontSize: 12, color: kMuted),
        );
      }
      if (store.devicesError != null) {
        return Text(
          '读取失败：${store.devicesError}',
          style: const TextStyle(fontSize: 12, height: 1.6, color: kWarn),
        );
      }
      return const Text(
        '还没有电脑接入。在电脑上起 bridge 后点右上角「刷新」。',
        style: TextStyle(fontSize: 12, height: 1.65, color: kMuted),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final device in store.devices) _deviceRow(device),
        if (store.devicesError != null)
          Text(
            '刷新失败：${store.devicesError}',
            style: const TextStyle(fontSize: 11.5, height: 1.6, color: kWarn),
          ),
      ],
    );
  }

  Widget _deviceRow(DeviceItem device) {
    final online = device.isOnline;
    final isDefault = widget.settings.deviceId == device.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 5, right: 8),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: online ? kAccent : kMuted,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.label == device.id
                      ? device.id
                      : '${device.label} · ${device.id}',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${online ? '在线' : '离线'} · 会话 ${device.sessionCount} · '
                  '待执行 ${device.pendingCommands} · 执行中 ${device.runningCommands}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    height: 1.5,
                    color: kMuted,
                  ),
                ),
                Text(
                  '最近上报 ${relativeTime(device.lastSeenAt)}',
                  style: const TextStyle(fontSize: 11, color: kMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (isDefault)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '默认',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: kAccent,
                ),
              ),
            )
          else
            TextButton(
              onPressed: () => _useDevice(device),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('设为默认', style: TextStyle(fontSize: 11.5)),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 32),
        children: [
          SectionCard(
            title: '连接',
            trailing: LinkBadge(
              state: widget.store.link,
              detail: widget.store.linkError,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _kv('地址', settings.baseUrl, mono: true),
                _kv('token', settings.maskedToken, mono: true),
                _kv(
                  '默认设备',
                  settings.deviceId.isEmpty ? '（未设置）' : settings.deviceId,
                  mono: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Hub 健康',
            trailing: TextButton(
              onPressed: _checking ? null : _check,
              child: Text(
                _checking ? '检查中…' : '检查',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_healthLine == null && _healthError == null)
                  const Text(
                    '点「检查」拉一次 /api/v1/health，确认服务、数据库和 SSE 都在。',
                    style: TextStyle(fontSize: 12, height: 1.65, color: kMuted),
                  ),
                if (_healthLine != null)
                  Text(
                    _healthLine!,
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.7,
                      color: kAccent,
                    ),
                  ),
                if (_healthError != null)
                  Text(
                    _healthError!,
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.7,
                      color: kDanger,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: '通知',
            trailing: TextButton(
              onPressed: _requestingNotify ? null : _requestNotifyPermission,
              child: Text(
                _requestingNotify ? '请求中…' : '请求权限',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text(
                    '命令完成 / 失败',
                    style: TextStyle(fontSize: 12.5),
                  ),
                  subtitle: const Text(
                    '远程命令跑到终态时弹系统通知（含失败原因）',
                    style: TextStyle(fontSize: 11, height: 1.5, color: kMuted),
                  ),
                  value: settings.notifyCommands,
                  onChanged: (value) async {
                    await settings.setNotifyCommands(value);
                    if (mounted) setState(() {});
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text(
                    '会话完成 / 失败',
                    style: TextStyle(fontSize: 12.5),
                  ),
                  subtitle: const Text(
                    'bridge 发现会话从「执行中」翻成终态时提醒',
                    style: TextStyle(fontSize: 11, height: 1.5, color: kMuted),
                  ),
                  value: settings.notifySessions,
                  onChanged: (value) async {
                    await settings.setNotifySessions(value);
                    if (mounted) setState(() {});
                  },
                ),
                const SizedBox(height: 4),
                Text(
                  _notifyStatus ??
                      'Android 13+ 需要授予通知权限；App 退到后台会主动断 SSE 省电，'
                          '这期间由 ntfy 兜底，回到 App 后会补发后台期间结束的命令。',
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.6,
                    color: _notifyStatus == null ? kMuted : kText,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: '默认执行设备',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _deviceCtrl,
                  autocorrect: false,
                  style: kMono,
                  decoration: const InputDecoration(hintText: 'localone'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '下发命令时默认发到这台设备，可在下发面板里临时改。',
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.6,
                          color: kMuted,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: _saveDevice,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 36),
                      ),
                      child: const Text('保存', style: TextStyle(fontSize: 12.5)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: '已接入设备',
            trailing: TextButton(
              onPressed: _loadingDevices ? null : _refreshDevices,
              child: Text(
                _loadingDevices ? '刷新中…' : '刷新',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            child: _devicesBody(),
          ),
          const SizedBox(height: 12),
          const SectionCard(
            title: '安全提示',
            child: Text(
              '当前是 IP + 随机前缀的明文 HTTP 入口（域名还在等备案）。同网络的其他人理论上能嗅探到 token，'
              '所以尽量别在公共 Wi-Fi 下用；备案通过后把地址换成 https://hub.littlewish.top，'
              '并在服务器上轮换 device / app token。',
              style: TextStyle(fontSize: 12, height: 1.7, color: kMuted),
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: '换个 Hub',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '清空本机的地址和 token，重新走一遍向导。',
                  style: TextStyle(fontSize: 12, height: 1.65, color: kMuted),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _signOut,
                  icon: const Icon(Icons.logout_rounded, size: 16),
                  label: const Text('清空并退出'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kDanger,
                    side: BorderSide(color: kDanger.withValues(alpha: 0.4)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: '版本与更新',
            trailing: TextButton(
              onPressed: _checkingUpdate ? null : _checkUpdate,
              child: Text(
                _checkingUpdate ? '检查中…' : '检查更新',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Cline Console $kAppVersion（build $kAppBuild）',
                  style: const TextStyle(fontSize: 12.5, height: 1.7),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Hub API v1 · Flutter Android 客户端 · 数据只存在你自己的服务器',
                  style: TextStyle(fontSize: 11.5, height: 1.7, color: kMuted),
                ),
                if (_updateError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '检查失败：$_updateError',
                    style: const TextStyle(fontSize: 11.5, height: 1.6, color: kWarn),
                  ),
                ],
                if (_release != null) ...[
                  const SizedBox(height: 10),
                  if (_release!.isNewer) ...[
                    Text(
                      '有新版本 ${_release!.version}（build ${_release!.build}）',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: kAccent,
                      ),
                    ),
                    const SizedBox(height: 4),
                    for (final note in _release!.notes)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          '· $note',
                          style: const TextStyle(fontSize: 11.5, height: 1.6),
                        ),
                      ),
                    if ((_release!.apkUrl ?? '').isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          FilledButton.icon(
                            onPressed: () => _openDownload(_release!),
                            icon: const Icon(Icons.open_in_new_rounded, size: 15),
                            label: const Text(
                              '打开下载页',
                              style: TextStyle(fontSize: 12.5),
                            ),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                          CopyButton(text: _release!.apkUrl!, label: '复制链接'),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '「打开下载页」会用系统浏览器打开 APK 地址，下载后用系统安装器覆盖安装即可（同一签名）。',
                        style: TextStyle(fontSize: 11, height: 1.6, color: kMuted),
                      ),
                    ],
                  ] else
                    const Text(
                      '已是最新版本。',
                      style: TextStyle(fontSize: 12, color: kMuted),
                    ),
                ],
                if (_checkedUpdate && _release == null && _updateError == null)
                  const Text(
                    '服务器还没有发布过 APK（releases/latest.json 不存在）。',
                    style: TextStyle(fontSize: 11.5, height: 1.6, color: kMuted),
                  ),
                const SizedBox(height: 6),
                TextButton(
                  onPressed: _showChangelog,
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('更新日志', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
