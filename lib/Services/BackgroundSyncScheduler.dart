import 'dart:io' show Platform;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'BackgroundSyncRunner.dart';
import 'SyncChangeSummary.dart';

/// 后台定时同步的**调度器绑定层**：什么时候唤醒、怎么唤醒。
///
/// 这是整条链路里唯一碰平台插件的地方，业务逻辑全在
/// [BackgroundSyncRunner] 里。分开的好处很实在：换调度器不用动业务，
/// 业务能在没有任何后台插件的环境里被单元测试，而这一层薄到一眼能看完。
///
/// ## 平台支持
///
/// `workmanager` 只声明了 android / ios 两个平台实现。鸿蒙上插件根本不会被
/// 注册，调用它会抛 `MissingPluginException`——**能编译，一调用就炸**。所以
/// 所有调用都收口在这个类里，由 [isSupported] 挡住，鸿蒙降级为用户手动点
/// 「更新当前课程表」。将来鸿蒙要自动更新，得自写原生调度接进这一层。
///
/// iOS 暂时也关着：`workmanager` 的 iOS 侧走 `BGAppRefreshTask`，需要在
/// `Info.plist` 里登记 `BGTaskSchedulerPermittedIdentifiers`、在 AppDelegate
/// 里注册标识符，缺一样就是**静默不执行**——比明确不支持更糟，用户以为开着
/// 其实从没跑过。等那部分配好并在真机上验过再打开。
class BackgroundSyncScheduler {
  const BackgroundSyncScheduler();

  /// WorkManager 里这个周期任务的唯一名字。改它等于换一个任务，旧的会
  /// 留在系统里继续跑，所以**不要改**。
  static const String taskName = 'njuCourseSync';
  static const String _uniqueName = 'njuCourseSyncPeriodic';

  /// 用户有没有打开后台自动更新。
  static const String prefsEnabledKey = 'nju_bg_sync_enabled';

  /// 上一轮后台任务的结果摘要，给设置页显示「上次同步：…」用。
  static const String prefsLastRunKey = 'nju_bg_sync_last_run';

  /// 多久跑一次。
  ///
  /// Android WorkManager 的最小周期是 15 分钟，但课表一学期只变几次，跑那么
  /// 勤没有意义，还要多担一份账号锁定的风险（每一轮都是一次真实登录）。
  /// 24 小时是「变更最多晚一天被发现」和「尽量少打扰教务系统」之间的取舍。
  static const Duration interval = Duration(hours: 24);

  /// 这个平台能不能做后台自动更新。
  bool get isSupported => Platform.isAndroid;

  /// 用户是否已开启（未开启或平台不支持都返回 false）。
  Future<bool> isEnabled() async {
    if (!isSupported) return false;
    final sp = await SharedPreferences.getInstance();
    await sp.reload();
    return sp.getBool(prefsEnabledKey) ?? false;
  }

  /// App 启动时调一次：把用户之前的选择恢复成真正的系统任务。
  ///
  /// 必须做——WorkManager 的任务在应用被卸载重装、或者某些厂商 ROM 清数据
  /// 之后会消失，只靠「用户当初打开过开关」这个标记是不够的。重复注册同一个
  /// unique name 是安全的（走 [ExistingWorkPolicy.keep]，已经排上的不会被
  /// 重置周期）。
  Future<void> restoreOnLaunch() async {
    if (!isSupported) return;
    if (!await isEnabled()) return;
    await enable();
  }

  Future<void> enable() async {
    if (!isSupported) return;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(prefsEnabledKey, true);

    await Workmanager().initialize(
      backgroundSyncDispatcher,
      isInDebugMode: kDebugMode,
    );
    await Workmanager().registerPeriodicTask(
      _uniqueName,
      taskName,
      frequency: interval,
      // 没网的时候唤醒纯属浪费电，而且会白白记一次失败。
      constraints: Constraints(networkType: NetworkType.connected),
      // keep：已经排上的就别动。用 replace 的话每次启动 App 都会把周期重置，
      // 用户天天开 App 就等于永远等不到第一次执行。
      existingWorkPolicy: ExistingWorkPolicy.keep,
    );
  }

  Future<void> disable() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(prefsEnabledKey, false);
    if (!isSupported) return;
    await Workmanager().cancelByUniqueName(_uniqueName);
  }

  /// 立刻排一轮，用来让用户当场确认这东西是不是真的在工作。
  ///
  /// 周期任务第一次执行可能要等很久（WorkManager 自己决定时机），没有这个
  /// 按钮的话用户打开开关之后一天都看不到任何反馈，只能怀疑是不是坏了。
  Future<void> runOnceNow({Duration delay = const Duration(seconds: 5)}) async {
    if (!isSupported) return;
    await Workmanager().initialize(
      backgroundSyncDispatcher,
      isInDebugMode: kDebugMode,
    );
    await Workmanager().registerOneOffTask(
      // 换个唯一名字，否则会被当成重复任务丢掉。
      '$_uniqueName-once-${DateTime.now().millisecondsSinceEpoch}',
      taskName,
      initialDelay: delay,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  /// 读上一轮的结果。没跑过返回 null。
  Future<BackgroundSyncRecord?> lastRun() async {
    final sp = await SharedPreferences.getInstance();
    await sp.reload();
    return BackgroundSyncRecord.parse(sp.getString(prefsLastRunKey));
  }
}

/// 上一轮后台同步的记录。
class BackgroundSyncRecord {
  const BackgroundSyncRecord({
    required this.at,
    required this.outcome,
    required this.semesterName,
  });

  /// 什么时候跑的。时间戳坏掉时为 null。
  final DateTime? at;

  /// [BackgroundSyncOutcome] 的名字。
  final String outcome;

  /// 教务系统当时返回的学期名，抓取没走到那一步就是空。
  final String semesterName;

  /// 解析存下来的那行字符串。
  ///
  /// 要兼容**两段式的旧记录**：学期名是后加的字段，已经装了这个 App 的
  /// 用户本地存的还是 `时间|结果`，按三段切会直接崩或者拿到错的值。
  static BackgroundSyncRecord? parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.split('|');
    return BackgroundSyncRecord(
      at: DateTime.tryParse(parts.first),
      outcome: parts.length > 1 ? parts[1] : '',
      // 学期名里万一带了 `|`，剩下的整段都算它的，不要只取第 3 段。
      semesterName: parts.length > 2 ? parts.sublist(2).join('|') : '',
    );
  }
}

/// 后台任务入口。
///
/// 必须是**顶层函数**并标注 `vm:entry-point`，否则 release 构建会把它当成
/// 没人引用的代码裁掉——那样后台任务会静默地永远不执行，且 debug 构建下
/// 完全正常，极难排查。
@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    // 后台 isolate 不会自动做这两件事，插件全都用不了。
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();

    final log = <String>[];
    try {
      final result = await BackgroundSyncRunner().run(log: log);
      await _recordLastRun(result.outcome.name,
          semesterName: result.semesterName);
      await _savePendingSummary(result);

      // TODO: 通知还没接。现在的行为是「静默更新好课表」——这本身符合项目
      // 目标（用户直接看到已经更新好的课表），但 needsUserAttention 那条
      // （凭据失效、后台已停用）必须能推送出去，否则用户永远不知道自动更新
      // 停了。接通知是下一步。
      debugPrint('[BgSync] ${result.outcome.name} '
          'changes=${result.hasChangesWorthNotifying} '
          'attention=${result.needsUserAttention}');
    } catch (e) {
      // 后台任务抛异常会被 WorkManager 当成失败并按自己的策略重试，而我们
      // 的重试策略在 BackgroundSyncGuard 里。吞掉异常、返回成功，让调度权
      // 留在自己手上。
      log.add('dispatcher 异常：$e');
      await _recordLastRun('error');
    }
    for (final line in log) {
      debugPrint('[BgSync] $line');
    }
    return true;
  });
}

/// 把这一轮改了什么留下来，等用户下次打开 App 时弹窗告诉他。
///
/// 只在 [BackgroundSyncOutcome.ok] 时存：其余结果要么没动数据（抓取失败、
/// 表不存在），要么是"需要用户去确认"而不是"已经改好了"（换学期），
/// 那些属于通知的范畴，不该混进"课表已自动更新"这个弹窗。
Future<void> _savePendingSummary(BackgroundSyncResult result) async {
  if (result.outcome != BackgroundSyncOutcome.ok) return;
  final report = result.report;
  if (report == null) return;
  final summary = SyncChangeSummary.build(
    tableName: result.semesterName,
    at: DateTime.now(),
    diff: report.diff,
    sweep: report.sweep,
  );
  if (summary == null) return; // 没有值得说的变化就不留，免得弹空窗
  await SyncChangeSummaryStore.save(summary);
}

/// 存成 `时间|结果|学期名` 三段。
///
/// 学期名里不会出现 `|`，所以用它分隔是安全的；真出现了也只影响这一行显示，
/// [BackgroundSyncRecord.parse] 那边按最多 3 段切，多的会留在学期名里。
Future<void> _recordLastRun(String outcome, {String semesterName = ''}) async {
  try {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      BackgroundSyncScheduler.prefsLastRunKey,
      '${DateTime.now().toIso8601String()}|$outcome|$semesterName',
    );
  } catch (_) {
    // 记不上就算了，不值得为它把整轮判成失败。
  }
}
