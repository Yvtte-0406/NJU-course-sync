import 'package:meta/meta.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../Models/CourseTableModel.dart';
import '../Resources/NjuConfig.dart';
import '../Utils/NjuCredentialStore.dart';
import 'BackgroundSyncGuard.dart';
import 'CourseSyncService.dart';
import 'ForegroundSyncLock.dart';
import 'NjuLoginService.dart';

/// 后台跑完整一轮课表同步：拦一道 → 登录 → 抓取 → 比对 → 落库 → 出报告。
///
/// **不许 import material.dart**，跟 [CourseSyncService]、[NjuLoginService]
/// 同一条规矩——它跑在没有界面的后台 isolate 里。
///
/// 这一层也**不发通知、不碰调度器**。它只回一个 [BackgroundSyncResult]，
/// 怎么推送、多久跑一次是绑定层的事（Android 用 WorkManager、iOS 用
/// BGAppRefreshTask、鸿蒙要自写原生）。这样换调度器不用动业务逻辑，也让
/// 这一层能在没有任何后台插件的情况下被测试。
///
/// 跑之前有三道拦截，顺序不能换：
/// 1. [BackgroundSyncGuard] —— 凭据连续失败已经停用的话，一次都不能再试，
///    否则会把统一认证账号锁掉。这道最先，因为它关乎的是伤害而不是效率。
/// 2. [ForegroundSyncLock] —— 用户正在前台改课表，跳过本轮，别撞并发写库。
/// 3. 有没有存账号密码、当前课表是不是导入来的 —— 没有的话本来就无事可做。
class BackgroundSyncRunner {
  BackgroundSyncRunner({
    CourseSyncService? syncService,
    CourseTableProvider? tableProvider,
    BackgroundSyncGuard? guard,
    ForegroundSyncLock lock = const ForegroundSyncLock(),
    NjuLoginService Function()? loginFactory,
    this.loginTimeout = const Duration(seconds: 90),
  })  : _sync = syncService ?? CourseSyncService(),
        _tables = tableProvider ?? CourseTableProvider(),
        _guard = guard ?? BackgroundSyncGuard(),
        _lock = lock,
        _loginFactory = loginFactory ?? NjuLoginService.new;

  final CourseSyncService _sync;
  final CourseTableProvider _tables;
  final BackgroundSyncGuard _guard;
  final ForegroundSyncLock _lock;
  final NjuLoginService Function() _loginFactory;

  /// 后台的登录时间预算。
  ///
  /// 比前台的 25 秒宽得多：后台是冷启动，引擎要初始化、插件要重新注册、
  /// WebView 没有预热，系统还可能限速。拿前台的数字卡后台会把正常的慢
  /// 误判成失败——而这里的"失败"是要写进保护机制计数的，误判有代价。
  final Duration loginTimeout;

  /// 当前显示的课表 id 存在这个键里，跟 widget 那边读的是同一个。
  static const _kCurrentTableKey = 'tableId';

  Future<BackgroundSyncResult> run({List<String>? log}) async {
    void say(String line) => log?.add(line);

    if (!await _guard.shouldRunRound()) {
      say('已因凭据连续失败而停用，跳过');
      return const BackgroundSyncResult._(BackgroundSyncOutcome.disabledByGuard);
    }
    if (await _lock.isHeld()) {
      say('前台正在同步，跳过本轮');
      return const BackgroundSyncResult._(BackgroundSyncOutcome.foregroundBusy);
    }

    final (username, password) = await NjuCredentialStore.read();
    if (username.isEmpty || password.isEmpty) {
      say('本地没有账号密码');
      return const BackgroundSyncResult._(BackgroundSyncOutcome.noCredentials);
    }

    final sp = await SharedPreferences.getInstance();
    await sp.reload();
    final tableId = sp.getInt(_kCurrentTableKey) ?? 0;
    final config = NjuConfig.findByPinyin(
        await _tables.getSourceSchoolPinyin(tableId));
    if (config == null) {
      // 当前这张表不是从学校导入的（手动建的，或者根本没有表）。学校那边
      // 没有对应数据，"更新"无从谈起。
      say('当前课表不是导入来的，没有可更新的数据源');
      return const BackgroundSyncResult._(BackgroundSyncOutcome.notImportedTable);
    }

    final login = _loginFactory();
    try {
      say('开始登录');
      final result = await login.login(
        username: username,
        password: password,
        config: config,
        timeout: loginTimeout,
      );

      final verdict =
          await _guard.recordLoginOutcome(failure: result.failure);
      if (!result.success) {
        say('登录失败：${result.failure!.name} -> ${verdict.name}');
        return BackgroundSyncResult._(
          BackgroundSyncOutcome.loginFailed,
          loginFailure: result.failure,
          verdict: verdict,
        );
      }
      say('登录成功，开始抓取');

      final fetch = await _sync.fetch(result.controller!, config);
      say('抓到 ${fetch.courseCount} 门课（${fetch.semesterName}）');

      final report = await _sync.compareWithTable(
        config: config,
        fetch: fetch,
        tableId: tableId,
      );

      switch (report.outcome) {
        case SyncOutcome.emptyFetch:
          // 一门课都没抓到判为抓取失败，不是"全学期停课了"。这一步
          // CourseSyncService 里已经拦住了，不会动数据。
          //
          // 学期名一定要带出去。学期之间的空档期里，教务系统当前显示的
          // 学期可能根本不是用户那张表的学期（比如八月停在暑期学期，而
          // 用户的表是秋季学期），这时候 0 门课完全正常。光说"没抓到课程"
          // 会让人以为坏了，说清楚是哪个学期就一目了然。
          say('抓到 0 门课，判为抓取失败，未改动数据');
          return BackgroundSyncResult._(
            BackgroundSyncOutcome.emptyFetch,
            semesterName: fetch.semesterName,
          );
        case SyncOutcome.noSuchTable:
          say('课表 $tableId 不存在');
          return const BackgroundSyncResult._(BackgroundSyncOutcome.notImportedTable);
        case SyncOutcome.semesterChanged:
          // 换学期要新建一张表并切过去，那是个足够大的动作，不该在用户
          // 不知情的后台悄悄做。只通知，让用户自己去导入页确认。
          say('学期变了，需要用户确认');
          return BackgroundSyncResult._(
            BackgroundSyncOutcome.semesterChanged,
            report: report,
            semesterName: fetch.semesterName,
          );
        case SyncOutcome.ok:
          // 新增和字段变更直接落库——项目目标就是"用户直接看到已经更新好
          // 的课表"，留着等确认就退化成前台那套流程了。消失的课程
          // compareWithTable 已按两轮宽限期处理过。
          await _sync.applyChanges(report);
          say('已应用变更');
          return BackgroundSyncResult._(
            BackgroundSyncOutcome.ok,
            report: report,
            semesterName: fetch.semesterName,
          );
      }
    } catch (e) {
      say('异常：$e');
      return BackgroundSyncResult._(
        BackgroundSyncOutcome.error,
        errorMessage: '$e',
      );
    } finally {
      // 脚本还活在那个 WebView 里的话，会在 isolate 存活期间继续跑。
      await login.dispose();
    }
  }
}

enum BackgroundSyncOutcome {
  /// 跑完了，变更（如有）已经落库。
  ok,

  /// 学期变了。要新建课表，得用户自己来。
  semesterChanged,

  /// 抓到 0 门课，判为抓取失败，没动数据。
  emptyFetch,

  /// 登录没成功。具体原因看 [BackgroundSyncResult.loginFailure]。
  loginFailed,

  /// 保护机制已停用后台检查，本轮根本没跑。
  disabledByGuard,

  /// 前台正在同步，本轮让路。
  foregroundBusy,

  /// 本地没存账号密码。
  noCredentials,

  /// 当前课表不是从学校导入的，没有数据源。
  notImportedTable,

  /// 抛异常了。
  error,
}

class BackgroundSyncResult {
  const BackgroundSyncResult._(
    this.outcome, {
    this.report,
    this.loginFailure,
    this.verdict,
    this.errorMessage = '',
    this.semesterName = '',
  });

  /// 只给测试用：真实的结果只能由 [BackgroundSyncRunner.run] 产出，但
  /// "该不该发通知"那两条判断得单独锁住——判错了要么天天骚扰用户，要么
  /// 真有变化时一声不吭。
  @visibleForTesting
  const BackgroundSyncResult.forTesting(
    this.outcome, {
    this.report,
    this.loginFailure,
    this.verdict,
    this.errorMessage = '',
    this.semesterName = '',
  });

  final BackgroundSyncOutcome outcome;
  final SyncReport? report;
  final NjuLoginFailure? loginFailure;

  /// 保护机制对这次登录结果的处置。只有 [BackgroundSyncOutcome.loginFailed]
  /// 时有值。
  final GuardVerdict? verdict;
  final String errorMessage;

  /// 教务系统这次返回的是哪个学期。抓取真的走通了才有值。
  ///
  /// 存在的意义是把"抓到 0 门课"讲清楚：学期之间的空档期里，教务系统当前
  /// 显示的学期可能根本不是用户那张表的学期，这时候 0 门课完全正常。没有
  /// 这个字段的话，用户只会看到一句"没抓到课程"，无从判断是坏了还是正常。
  final String semesterName;

  /// 这一轮有没有产生用户该知道的课表变化。
  ///
  /// 没变化就**不要发通知**——课表一学期只变几次，天天推一条"没有变化"
  /// 是纯粹的骚扰，用户会直接把通知关掉，然后真有变化时也收不到了。
  bool get hasChangesWorthNotifying {
    if (outcome == BackgroundSyncOutcome.semesterChanged) return true;
    if (outcome != BackgroundSyncOutcome.ok) return false;
    final r = report;
    if (r == null) return false;
    return r.hasPendingChanges || !(r.sweep?.isEmpty ?? true);
  }

  /// 要不要提醒用户"自动更新已经停了，去重新登录一下"。
  bool get needsUserAttention => verdict?.shouldNotifyUser ?? false;
}
