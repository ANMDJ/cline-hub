import 'package:flutter/material.dart';

import '../models/models.dart';
import '../util/format.dart';
import 'theme.dart';
import 'widgets.dart';

/// 会话卡片（列表页与工作区页共用）：状态点 + 标题 + 执行中/命令数 + 元信息 + 结果预览。
class SessionTile extends StatelessWidget {
  const SessionTile({super.key, required this.item, required this.onTap});

  final SessionItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = statusColor(item.status, ok: item.succeeded);
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: StatusDot(color: color),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (item.status == 'running') ...[
                    const SizedBox(width: 8),
                    Pill(
                      label: '执行中',
                      color: kInfo,
                      icon: Icons.play_arrow_rounded,
                    ),
                  ],
                  if (item.commandCount > 0) ...[
                    const SizedBox(width: 8),
                    Pill(
                      label: '${item.commandCount} 命令',
                      color: kInfo,
                      icon: Icons.bolt_rounded,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              MetaLine(
                parts: [item.workspace, relativeTime(item.sortAt), item.model],
              ),
              if (item.resultPreview != null) ...[
                const SizedBox(height: 6),
                Text(
                  inlinePreview(item.resultPreview!),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
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
