/// 多久提醒一次"该检查课表更新了"。
///
/// 课表一学期只变几次，没必要做成实时监控，所以默认一天一次就够。
/// [manual] 表示完全关掉提醒，只在用户自己去点的时候才检查。
enum UpdateCheckInterval {
  everyLaunch,
  daily,
  everyThreeDays,
  weekly,
  manual,
}

extension UpdateCheckIntervalX on UpdateCheckInterval {
  /// 存进 SharedPreferences 的值。用字符串而不是 enum 下标，这样以后往
  /// 中间插一个新档位不会把已有用户的设置错位到别的档去。
  String get storageKey {
    switch (this) {
      case UpdateCheckInterval.everyLaunch:
        return 'everyLaunch';
      case UpdateCheckInterval.daily:
        return 'daily';
      case UpdateCheckInterval.everyThreeDays:
        return 'every3Days';
      case UpdateCheckInterval.weekly:
        return 'weekly';
      case UpdateCheckInterval.manual:
        return 'manual';
    }
  }

  String get displayName {
    switch (this) {
      case UpdateCheckInterval.everyLaunch:
        return '每次打开';
      case UpdateCheckInterval.daily:
        return '每天';
      case UpdateCheckInterval.everyThreeDays:
        return '每 3 天';
      case UpdateCheckInterval.weekly:
        return '每周';
      case UpdateCheckInterval.manual:
        return '不提醒';
    }
  }

  /// 距上次检查要过多久才再提醒。[UpdateCheckInterval.manual] 没有间隔
  /// 可言，取 null。
  Duration? get duration {
    switch (this) {
      case UpdateCheckInterval.everyLaunch:
        return Duration.zero;
      case UpdateCheckInterval.daily:
        return const Duration(days: 1);
      case UpdateCheckInterval.everyThreeDays:
        return const Duration(days: 3);
      case UpdateCheckInterval.weekly:
        return const Duration(days: 7);
      case UpdateCheckInterval.manual:
        return null;
    }
  }

  static UpdateCheckInterval fromStorageKey(String? key) {
    for (final value in UpdateCheckInterval.values) {
      if (value.storageKey == key) return value;
    }
    return UpdateCheckInterval.daily;
  }
}

/// 现在该不该提醒用户检查这张课表的更新。
///
/// [lastCheckedAt] 是课表 `data` 存档里记的上次检查时间（ISO8601），从没
/// 检查过传 null。[isAutoImported] 表示这张表是不是通过学校导入创建的——
/// 手动建的课表没有"更新"可言，学校那边根本没有对应数据。
///
/// 纯函数，[now] 显式传入以便测试。
bool shouldRemindUpdateCheck({
  required bool isAutoImported,
  required String? lastCheckedAt,
  required UpdateCheckInterval interval,
  required DateTime now,
}) {
  if (!isAutoImported) return false;

  final threshold = interval.duration;
  if (threshold == null) return false; // 用户选了"不提醒"

  // 从没检查过：这张表刚导入完就算刚检查过（导入时会写 lastCheckedAt），
  // 所以这里为 null 多半是老数据，提醒一次让它补上记录。
  if (lastCheckedAt == null || lastCheckedAt.isEmpty) return true;

  final last = DateTime.tryParse(lastCheckedAt);
  if (last == null) return true; // 时间戳坏了，当作没检查过

  // 时间戳比现在还晚：设备时钟被改过之类。不提醒也不报错，等时间走正常。
  final elapsed = now.difference(last);
  if (elapsed.isNegative) return false;

  return elapsed >= threshold;
}

/// "上次检查于 X"这句话。[lastCheckedAt] 为空表示从没查过。
String describeLastChecked(String? lastCheckedAt, DateTime now) {
  if (lastCheckedAt == null || lastCheckedAt.isEmpty) return '从未检查过更新';
  final last = DateTime.tryParse(lastCheckedAt);
  if (last == null) return '从未检查过更新';

  final elapsed = now.difference(last);
  if (elapsed.isNegative) return '刚刚检查过';
  if (elapsed.inMinutes < 1) return '刚刚检查过';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes} 分钟前检查过';
  if (elapsed.inDays < 1) return '${elapsed.inHours} 小时前检查过';
  return '${elapsed.inDays} 天前检查过';
}
