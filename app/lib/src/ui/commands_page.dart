import 'package:flutter/material.dart';

import '../data/hub_api.dart';
import '../models/models.dart';
import '../state/hub_store.dart';
import '../util/format.dart';
import 'new_command_sheet.dart';
import 'session_detail_page.dart';
import 'theme.dart';
import 'widgets.dart';

/// 命令页：看每条远程命令走到哪一步，结果直接在手机上读。
class CommandsPage extends StatelessWidget {
  const CommandsPage({super.key, required this.store});

  final HubStore store;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 多设备时才出现（只有一台时不占空间）。
        DeviceFilterBar(store: store),
        Expanded(child: _buildList(context)),
      ],
    );
  }

  Widget _buildList(BuildContext context) {
    final items = store.visibleCommands;
    if (items.isEmpty) {
      if (store.loadingCommands) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      }
      if (store.commandsError != null) {
        return ErrorView(
          message: store.commandsError!,
          onRetry: store.refreshCommands,
        );
      }
      if (store.commands.isNotEmpty) {
        return EmptyState(
          icon: Icons.filter_alt_off_outlined,
          title: '设备 ${store.deviceFilter} 还没有命令',
          description: '切回「全部设备」能看到其它机器上执行的命令。',
          action: OutlinedButton(
            onPressed: () => store.setDeviceFilter(null),
            child: const Text('查看全部设备'),
          ),
        );
      }
      return EmptyState(
        icon: Icons.bolt_outlined,
        title: '还没有下发过命令',
        description: 'Windows 上 bridge 跑着时，这里发出去的 prompt 会被领取、执行，再把输出回写到这里。',
        action: FilledButton.icon(
          onPressed: () => showNewCommandSheet(context, store),
          icon: const Icon(Icons.add_rounded, size: 16),
          label: const Text('下发第一条'),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: store.refreshCommands,
      color: kAccent,
      backgroundColor: kPanel,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 96),
        itemCount: items.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index == items.length) return const _BridgeHint();
          final item = items[index];
          return _CommandTile(
            item: item,
            onTap: () => _showCommandDetail(context, item, store),
          );
        },
      ),
    );
  }
}

class _CommandTile extends StatelessWidget {
  const _CommandTile({required this.item, required this.onTap});

  final CommandItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = statusColor(item.status);
    return Material(
      color: kPanel,
      borderRadius: BorderRadius.circular(kRadius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(kRadius),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(kRadius),
            border: Border.all(color: kLine),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  StatusDot(color: color),
                  const SizedBox(width: 8),
                  Text(
                    statusLabel(item.status),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Pill(label: item.modeLabel, color: modeColor(item.mode)),
                  const Spacer(),
                  Text(
                    formatClock(item.createdAt),
                    style: const TextStyle(fontSize: 11.5, color: kMuted),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                item.prompt,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13.5, height: 1.5),
              ),
              const SizedBox(height: 7),
              MetaLine(
                parts: [
                  workspaceLabel(item.workspace),
                  item.deviceId,
                  relativeTime(item.createdAt),
                ],
                icon: Icons.folder_outlined,
                trailing: ElapsedText(
                  start: item.startedAt ?? item.deliveredAt ?? item.createdAt,
                  end: item.finishedAt,
                  running: item.isActive,
                  prefix: '耗时 ',
                ),
              ),
              if (item.resultText != null) ...[
                const SizedBox(height: 6),
                Text(
                  inlinePreview(item.resultText!),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.55,
                    color: Color(0xFFA9BBCB),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _BridgeHint extends StatelessWidget {
  const _BridgeHint();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: 6, bottom: 4),
      child: Text(
        '只显示最近 50 条。命令一直停在 pending，说明 bridge 没在跑或还没轮询到。',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, height: 1.6, color: kMuted),
      ),
    );
  }
}

void _showCommandDetail(
  BuildContext context,
  CommandItem snapshot,
  HubStore store,
) {
  final pageContext = context;
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: kPanel,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    // 弹层会停留很久：命令跑完时靠 store 的推送换成本地最新状态，
    // 否则状态停在「执行中」、耗时一直往上加。
    builder: (sheetContext) => ListenableBuilder(
      listenable: store,
      builder: (sheetContext, _) {
        final item = store.commands.firstWhere(
          (entry) => entry.id == snapshot.id,
          orElse: () => snapshot,
        );
        final color = statusColor(item.status);
        // 命令输出是终端回放：带 ANSI 颜色码，手机上显示/复制前先过滤（库里保留原字节）。
        final output = item.resultText == null
            ? null
            : stripAnsi(item.resultText!);
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.62,
          minChildSize: 0.35,
          maxChildSize: 0.92,
          builder: (context, controller) => ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: kLine,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  StatusDot(color: color),
                  const SizedBox(width: 8),
                  Text(
                    statusLabel(item.status),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Pill(label: item.modeLabel, color: modeColor(item.mode)),
                  const Spacer(),
                  CopyButton(text: item.id, label: '复制 ID'),
                ],
              ),
              const SizedBox(height: 6),
              MetaLine(
                parts: [
                  workspaceLabel(item.workspace),
                  item.deviceId,
                  relativeTime(item.createdAt),
                ],
                trailing: ElapsedText(
                  start: item.startedAt ?? item.deliveredAt ?? item.createdAt,
                  end: item.finishedAt,
                  running: item.isActive,
                  prefix: '耗时 ',
                ),
              ),
              const SizedBox(height: 16),
              const Text('指令', style: TextStyle(fontSize: 12, color: kMuted)),
              const SizedBox(height: 6),
              SelectableText(
                item.prompt,
                style: const TextStyle(fontSize: 13.5, height: 1.65),
              ),
              if (item.workspace != null) ...[
                const SizedBox(height: 10),
                MetaLine(parts: [item.workspace], icon: Icons.folder_outlined),
              ],
              // 进程身份：pid 只在 bridge 活着时可信；pidStartedAt 用于防 PID 复用。
              if (item.pid != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: MetaLine(
                        parts: [
                          'pid ${item.pid}',
                          if (item.runner != null) item.runner!,
                          if (item.pidStartedAt != null)
                            '启动于 ${formatDateTime(item.pidStartedAt)}',
                        ],
                        icon: Icons.memory_rounded,
                      ),
                    ),
                    const SizedBox(width: 8),
                    CopyButton(text: item.diagnosticsCommand, label: '复制排查命令'),
                  ],
                ),
              ],
              // bridge 执行完会把新开会话的 ID 回写到这里，点一下直接进会话。
              if ((item.sessionId ?? '').isNotEmpty) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: MetaLine(
                        parts: [item.sessionId!],
                        icon: Icons.forum_outlined,
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        Navigator.of(pageContext).push(
                          MaterialPageRoute<void>(
                            builder: (_) => SessionDetailPage(
                              store: store,
                              item: SessionItem(
                                deviceId: item.deviceId,
                                sessionId: item.sessionId!,
                              ),
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.arrow_forward_rounded, size: 14),
                      label: const Text(
                        '打开会话',
                        style: TextStyle(fontSize: 12.5),
                      ),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],
                ),
              ],
              if (output != null && output.trim().isNotEmpty) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '输出',
                        style: TextStyle(fontSize: 12, color: kMuted),
                      ),
                    ),
                    CopyButton(text: output, label: '复制输出'),
                  ],
                ),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: kBg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: kLine),
                  ),
                  child: SelectableText(output, style: kMono),
                ),
              ],
              if (item.errorText != null) ...[
                const SizedBox(height: 16),
                const Text('错误', style: TextStyle(fontSize: 12, color: kMuted)),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: kDanger.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: kDanger.withValues(alpha: 0.3)),
                  ),
                  child: SelectableText(
                    item.errorText!,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.6,
                      color: kDanger,
                    ),
                  ),
                ),
              ],
              if (item.isActive) ...[
                const SizedBox(height: 16),
                Text(
                  item.isCancelling
                      ? '已请求取消，等 bridge 停掉执行进程…'
                      : item.status == 'pending'
                      ? '排队中，等 bridge 来领取…'
                      : 'bridge 已领取，正在执行…',
                  style: const TextStyle(fontSize: 12, color: kWarn),
                ),
                const SizedBox(height: 10),
                _CancelCommandButton(item: item, store: store),
              ],
              if (sheetContext.mounted) const SizedBox(height: 8),
            ],
          ),
        );
      },
    ),
  );
}

/// 取消按钮（P14）：只有「还没结束」的命令才会出现。
///
/// 取消是不可撤销的（bridge 会直接杀掉执行进程树），所以先二次确认；
/// 点完立刻置灰并显示「已请求取消」，真正的终态由 SSE 推回来。
class _CancelCommandButton extends StatefulWidget {
  const _CancelCommandButton({required this.item, required this.store});

  final CommandItem item;
  final HubStore store;

  @override
  State<_CancelCommandButton> createState() => _CancelCommandButtonState();
}

class _CancelCommandButtonState extends State<_CancelCommandButton> {
  bool _busy = false;
  bool _requested = false;

  bool get _cancelling => _requested || widget.item.isCancelling;

  Future<void> _confirm() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: kPanel,
        title: const Text('取消这条命令？'),
        content: const Text('bridge 会停掉这条命令的执行进程。已经产生的输出会保留，但不会再继续。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('不取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('取消命令'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await widget.store.cancelCommand(widget.item.id);
      if (!mounted) return;
      setState(() => _requested = true);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已请求取消')));
    } on ApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('取消失败：${error.friendly}')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('取消失败：$error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final disabled = _busy || _cancelling;
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: disabled ? null : _confirm,
        icon: const Icon(Icons.stop_circle_outlined, size: 16),
        label: Text(
          _busy
              ? '正在取消…'
              : _cancelling
              ? '已请求取消，等 bridge 停进程'
              : '取消这条命令',
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: kDanger,
          disabledForegroundColor: kMuted,
          side: BorderSide(
            color: (disabled ? kLine : kDanger).withValues(alpha: 0.5),
          ),
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }
}
