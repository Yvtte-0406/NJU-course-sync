import 'package:shared_preferences/shared_preferences.dart';

/// 前台正在写课表时，让后台这一轮直接跳过。
///
/// 前台和后台是两个 isolate，各自打开同一个 sqflite 文件。同时写就会撞
/// `database is locked`——用户正在导入页点"应用变更"，后台任务恰好醒来开始
/// 覆盖数据，轻则报错重则写坏。
///
/// 没有用 WAL 而是用这把锁，是因为两者解决的问题不一样：WAL 能让并发**不
/// 报错**，但解决不了"两边同时改同一批课程，最后谁赢"。跳过一轮的代价只是
/// 晚几小时更新——反正下一轮还会来——而语义是明确的：以用户当下的操作为准。
///
/// ## 为什么带过期时间
///
/// 前台在持锁期间被杀掉（用户划掉 App、系统清后台、崩溃）是很常见的，那样
/// 标记就永远留在那儿，后台从此再也不跑，而且**没有任何征兆**。所以锁记的是
/// 时间戳而不是布尔值，超过 [staleAfter] 一律当作没人持有。宁可偶尔并发一次
/// （后台跳过是软保护，不是数据完整性的最后防线），也不能悄悄把功能废掉。
class ForegroundSyncLock {
  const ForegroundSyncLock();

  static const _kStartedAtKey = 'nju_foreground_sync_started_at';

  /// 超过这么久就认为持锁的前台已经死了。
  ///
  /// 取 5 分钟：一次完整的前台同步（登录 + 抓取 + 用户看变更预览 + 应用）
  /// 撑死也就一两分钟，5 分钟足够宽松；同时又短到用户下次打开 App 之前
  /// 就能自己解开，不至于卡掉一整天的后台检查。
  static const Duration staleAfter = Duration(minutes: 5);

  /// 前台开始同步前调用。
  Future<void> acquire({DateTime? now}) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
        _kStartedAtKey, (now ?? DateTime.now()).toIso8601String());
  }

  /// 前台同步结束后调用。必须放在 `finally` 里——失败路径不解锁的话，
  /// 后台要白等 [staleAfter] 那么久。
  Future<void> release() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kStartedAtKey);
  }

  /// 现在有没有前台正在同步。
  ///
  /// 每次都 `reload()`：后台在独立 isolate 里读，不重读磁盘会拿到自己那份
  /// 过期的内存副本，看不见前台刚写下的标记——那样这把锁等于不存在。
  Future<bool> isHeld({DateTime? now}) async {
    final sp = await SharedPreferences.getInstance();
    await sp.reload();
    final raw = sp.getString(_kStartedAtKey);
    if (raw == null || raw.isEmpty) return false;

    final startedAt = DateTime.tryParse(raw);
    if (startedAt == null) return false; // 时间戳坏了，当作没锁

    final elapsed = (now ?? DateTime.now()).difference(startedAt);
    // 时间戳比现在还晚（设备时钟被改过）也当作有效持有：这时候宁可保守，
    // 跳过一轮比撞上并发好。
    if (elapsed.isNegative) return true;
    return elapsed < staleAfter;
  }

  /// 包一段前台同步，保证异常路径也会解锁。
  Future<T> protect<T>(Future<T> Function() action) async {
    await acquire();
    try {
      return await action();
    } finally {
      await release();
    }
  }
}
