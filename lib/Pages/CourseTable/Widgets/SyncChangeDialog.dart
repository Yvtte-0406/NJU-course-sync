import 'package:flutter/material.dart';
import 'package:flutter_swiper_null_safety_flutter3/flutter_swiper_null_safety_flutter3.dart';

import '../../../Components/Dialog.dart';
import '../../../Services/SyncChangeSummary.dart';

/// 每页放几条。多了单页要滚动，弹窗本身也会顶到屏幕边；四条在小屏上刚好
/// 不用滚。
const int _kEntriesPerPage = 4;

/// 后台自动更新完之后，告诉用户这一轮改了什么。
///
/// 课表已经是更新好的状态了，这个弹窗只是"说明发生过什么"，没有需要用户
/// 确认的动作——所以只有一个「知道了」。
///
/// 变化多的时候分页左右翻，跟一个格子里挤了多门课时那个弹窗是同一套交互
/// （[Swiper] + 圆点），用户见过。
Future<void> showSyncChangeDialog(
  BuildContext context,
  SyncChangeSummary summary,
) {
  final pages = <List<SyncChangeEntry>>[];
  for (var i = 0; i < summary.entries.length; i += _kEntriesPerPage) {
    pages.add(summary.entries.sublist(
      i,
      (i + _kEntriesPerPage).clamp(0, summary.entries.length),
    ));
  }

  return showDialog<void>(
    context: context,
    builder: (context) {
      if (pages.length == 1) {
        return _SyncChangePage(summary: summary, entries: pages.first);
      }
      return Swiper(
        itemBuilder: (context, index) => _SyncChangePage(
          summary: summary,
          entries: pages[index],
          pageLabel: '${index + 1} / ${pages.length}',
        ),
        itemCount: pages.length,
        pagination: SwiperPagination(
          margin: const EdgeInsets.only(bottom: 100),
          builder: DotSwiperPaginationBuilder(
            color: Colors.grey,
            activeColor: Theme.of(context).primaryColor,
          ),
        ),
        // 变更条目是有顺序的，循环翻页会让人分不清看没看完。
        loop: false,
        viewportFraction: 1,
        scale: 1,
      );
    },
  );
}

class _SyncChangePage extends StatelessWidget {
  const _SyncChangePage({
    required this.summary,
    required this.entries,
    this.pageLabel,
  });

  final SyncChangeSummary summary;
  final List<SyncChangeEntry> entries;
  final String? pageLabel;

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
            for (final entry in entries) _EntryRow(entry: entry),
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
    final when = _describeWhen(summary.at, DateTime.now());
    final page = pageLabel == null ? '' : '　$pageLabel';
    return '$where · $when$page';
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
