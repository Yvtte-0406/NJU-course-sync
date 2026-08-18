import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../Models/CourseModel.dart';
import '../Utils/CourseDiff.dart';
import '../Utils/MissingCourseSweeper.dart';

/// 一条变更说明该显示成什么样。用来给条目上色/配图标，不参与逻辑判断。
enum SyncChangeKind { added, changed, hidden, deleted, restored }

/// 后台自动更新做完之后，留给用户看的一条变更说明。
///
/// 刻意只存**字符串**：这份摘要是在后台 isolate 里生成、写进
/// SharedPreferences，等用户下次打开 App 才读出来显示的。中间隔着进程重启，
/// 存 Course 对象或数据库 id 都可能在读出来时已经对不上了（那门课可能又被
/// 改了或删了），存好的文案则永远能显示。
class SyncChangeEntry {
  const SyncChangeEntry({
    required this.kind,
    required this.name,
    required this.detail,
  });

  final SyncChangeKind kind;

  /// 课程名。
  final String name;

  /// 这门课发生了什么，已经组好的一句话。
  final String detail;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'name': name,
        'detail': detail,
      };

  static SyncChangeEntry? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final kindName = raw['kind']?.toString();
    for (final kind in SyncChangeKind.values) {
      if (kind.name != kindName) continue;
      return SyncChangeEntry(
        kind: kind,
        name: raw['name']?.toString() ?? '',
        detail: raw['detail']?.toString() ?? '',
      );
    }
    // 认不出的类型：多半是降级安装后读到了新版本写的摘要，跳过这条即可。
    return null;
  }
}

/// 一轮后台更新的完整变更摘要。
class SyncChangeSummary {
  const SyncChangeSummary({
    required this.at,
    required this.tableName,
    required this.entries,
  });

  /// 这轮更新发生的时间。用户可能隔了很久才打开 App，得让他知道是什么时候的事。
  final DateTime at;

  /// 更新的是哪张课表。
  final String tableName;

  final List<SyncChangeEntry> entries;

  bool get isEmpty => entries.isEmpty;

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'tableName': tableName,
        'entries': [for (final e in entries) e.toJson()],
      };

  static SyncChangeSummary? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final at = DateTime.tryParse(raw['at']?.toString() ?? '');
    if (at == null) return null;
    final rawEntries = raw['entries'];
    final entries = <SyncChangeEntry>[];
    if (rawEntries is List) {
      for (final item in rawEntries) {
        final entry = SyncChangeEntry.fromJson(item);
        if (entry != null) entries.add(entry);
      }
    }
    if (entries.isEmpty) return null;
    return SyncChangeSummary(
      at: at,
      tableName: raw['tableName']?.toString() ?? '',
      entries: entries,
    );
  }

  /// 把一轮同步的比对结果和消失处理结果，翻译成给人看的条目。
  ///
  /// 没有任何值得说的变化时返回 null——没变化就不该弹窗打扰用户。
  static SyncChangeSummary? build({
    required String tableName,
    required DateTime at,
    CourseDiffResult? diff,
    MissingSweepResult? sweep,
  }) {
    final entries = <SyncChangeEntry>[];

    if (diff != null) {
      for (final group in diff.addedCourses.values) {
        for (final course in group) {
          entries.add(SyncChangeEntry(
            kind: SyncChangeKind.added,
            name: course.name ?? '',
            detail: '新增课程 · ${_slotOf(course)}',
          ));
        }
      }
      for (final course in diff.addedSlots) {
        entries.add(SyncChangeEntry(
          kind: SyncChangeKind.added,
          name: course.name ?? '',
          detail: '新增时间段 · ${_slotOf(course)}',
        ));
      }
      for (final change in diff.changedSlots) {
        entries.add(SyncChangeEntry(
          kind: SyncChangeKind.changed,
          name: change.oldSlot.name ?? '',
          detail: _describeFieldChanges(change),
        ));
      }
    }

    // 消失处理是按整轮汇总的（隐藏/删除/恢复各多少条），拿不到具体是哪几门，
    // 所以这里只能给出数量。真要逐条列出来，得让 sweeper 把处理过的课程带
    // 回来——那是另一处改动，现在没必要。
    final s = sweep;
    if (s != null) {
      if (s.hidden > 0) {
        entries.add(SyncChangeEntry(
          kind: SyncChangeKind.hidden,
          name: '${s.hidden} 门课已暂时隐藏',
          detail: '学校数据里没找到。如果下次仍然找不到就会删除；期间重新出现会自动恢复。',
        ));
      }
      if (s.deleted > 0) {
        entries.add(SyncChangeEntry(
          kind: SyncChangeKind.deleted,
          name: '${s.deleted} 门课已删除',
          detail: '连续两次都没在学校数据里找到。',
        ));
      }
      if (s.restored > 0) {
        entries.add(SyncChangeEntry(
          kind: SyncChangeKind.restored,
          name: '${s.restored} 门课已恢复显示',
          detail: '之前没抓到，这次又出现了。',
        ));
      }
    }

    if (entries.isEmpty) return null;
    return SyncChangeSummary(at: at, tableName: tableName, entries: entries);
  }

  static String _slotOf(Course c) {
    final week = c.weekTime;
    final start = c.startTime;
    final room = (c.classroom ?? '').trim();
    final where = room.isEmpty ? '' : ' · $room';
    if (week == null || start == null) return '时间未知$where';
    return '星期$week 第$start 节$where';
  }

  static const Map<String, String> _fieldNames = {
    'classroom': '教室',
    'info': '备注',
    'weekTime': '星期',
    'startTime': '起始节次',
    'timeCount': '节次跨度',
    'weeks': '周次',
  };

  static String _describeFieldChanges(CourseSlotChange change) {
    final parts = <String>[];
    change.changedFields.forEach((field, value) {
      final label = _fieldNames[field] ?? field;
      final before = (value.key ?? '').isEmpty ? '（空）' : value.key!;
      final after = (value.value ?? '').isEmpty ? '（空）' : value.value!;
      parts.add('$label：$before → $after');
    });
    return parts.isEmpty ? '有变化' : parts.join('\n');
  }
}

/// 摘要的存取。
///
/// 写在后台 isolate、读在前台，所以只能走 SharedPreferences 这类跨 isolate
/// 可见的存储。读之前要 `reload()`，否则前台拿到的是自己启动时的旧缓存，
/// 后台刚写的那条根本看不见。
class SyncChangeSummaryStore {
  static const String prefsKey = 'bgSyncPendingSummary';

  /// 覆盖式保存：只保留最近一轮。用户没看就又跑了一轮的情况下，旧的那份
  /// 已经不重要了——课表已经是最新状态，重要的是最后这次改了什么。
  static Future<void> save(SyncChangeSummary summary) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(prefsKey, json.encode(summary.toJson()));
    } catch (_) {
      // 摘要存不上不该影响这轮更新本身——课表数据已经落库了。
    }
  }

  static Future<SyncChangeSummary?> read() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.reload();
      final raw = sp.getString(prefsKey);
      if (raw == null || raw.isEmpty) return null;
      return SyncChangeSummary.fromJson(json.decode(raw));
    } catch (_) {
      return null;
    }
  }

  /// 用户看过之后清掉，避免每次打开 App 都弹同一份。
  static Future<void> clear() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(prefsKey);
    } catch (_) {}
  }
}
