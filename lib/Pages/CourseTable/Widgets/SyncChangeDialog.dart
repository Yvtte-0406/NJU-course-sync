import 'package:flutter/material.dart';

import '../../../Components/Dialog.dart';
import '../../../Services/SyncChangeSummary.dart';

/// 后台自动更新完之后，告诉用户这一轮改了什么。
///
/// 课表已经是更新好的状态了，这个弹窗只是"说明发生过什么"，没有需要用户
/// 确认的动作——所以只有一个「知道了」。
///
/// 条目多的时候在窗内滚动，不分页：分页要用户左右翻才能看全，而这里只是
/// 一条通知性质的说明，滚动一下比翻页更省事。
Future<void> showSyncChangeDialog(
  BuildContext context,
  SyncChangeSummary summary,
) {
  return showDialog<void>(
    context: context,
    builder: (context) => _SyncChangeDialog(summary: summary),
  );
}

class _SyncChangeDialog extends StatelessWidget {
  const _SyncChangeDialog({required this.summary});

  final SyncChangeSummary summary;

  @override
  Widget build(BuildContext context) {
    return MDialog(
      '课表已自动更新',
      SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _headline(),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 12),
            for (final entry in summary.entries) _EntryRow(entry: entry),
          ],
        ),
      ),
      overrideActions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    );
  }

  String _headline() {
    final where = summary.tableName.isEmpty ? '课表' : summary.tableName;
    return '$where · ${_describeWhen(summary.at, DateTime.now())}';
  }

  /// 用户可能隔了几天才打开 App，得说清楚这是什么时候的事。
  static String _describeWhen(DateTime at, DateTime now) {
    final elapsed = now.difference(at);
    if (elapsed.isNegative || elapsed.inMinutes < 1) return '刚刚';
    if (elapsed.inHours < 1) return '${elapsed.inMinutes} 分钟前';
    if (elapsed.inDays < 1) return '${elapsed.inHours} 小时前';
    return '${elapsed.inDays} 天前';
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry});

  final SyncChangeEntry entry;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _styleOf(context, entry.kind);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14)),
                if (entry.detail.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      entry.detail,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 图标和颜色只用来分类，不承载额外信息——文案里已经说清楚了。
  (IconData, Color) _styleOf(BuildContext context, SyncChangeKind kind) {
    switch (kind) {
      case SyncChangeKind.added:
        return (Icons.add_circle_outline, Colors.green);
      case SyncChangeKind.changed:
        return (Icons.swap_horiz, Theme.of(context).colorScheme.primary);
      case SyncChangeKind.hidden:
        return (Icons.visibility_off_outlined, Colors.orange);
      case SyncChangeKind.deleted:
        return (Icons.remove_circle_outline, Colors.red);
      case SyncChangeKind.restored:
        return (Icons.undo, Colors.green);
    }
  }
}
