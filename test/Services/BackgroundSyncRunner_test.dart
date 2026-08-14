import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wheretosleepinnju/Models/CourseTableModel.dart';
import 'package:wheretosleepinnju/Services/BackgroundSyncGuard.dart';
import 'package:wheretosleepinnju/Services/BackgroundSyncRunner.dart';
import 'package:wheretosleepinnju/Services/ForegroundSyncLock.dart';
import 'package:wheretosleepinnju/Services/NjuLoginService.dart';

/// 这里测的是**跑之前的三道拦截**，以及**该不该发通知**。
///
/// 登录和抓取本身不在这里测：那要真的建 WebView、连南大的服务器，属于集成
/// 测试（spike 分支上那个探针就是干这个的，真机跑了 10 轮 100%）。但拦截
/// 必须单测锁死——它们的作用恰恰是"在还没碰网络之前就停下来"，一旦漏掉，
/// 后果是拿失效凭据反复登录把账号锁掉，或者跟前台并发写库。
class _NoTableProvider extends CourseTableProvider {
  /// 当前课表不是从学校导入的（手动建的表，或者压根没有表）。
  @override
  Future<String?> getSourceSchoolPinyin(int id) async => null;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// 让前置条件全部满足，好让每条用例只破坏它想测的那一个。
  Future<void> givenReadyToSync() async {
    SharedPreferences.setMockInitialValues({
      'nju_saved_username': '201220000',
      'nju_saved_password': 'pw',
      'tableId': 1,
    });
  }

  group('跑之前的拦截', () {
    test('保护机制已停用时，连账号密码都不读就返回', () async {
      await givenReadyToSync();
      final guard = BackgroundSyncGuard();
      await guard.recordLoginOutcome(
          failure: NjuLoginFailure.invalidCredentials);
      await guard.recordLoginOutcome(
          failure: NjuLoginFailure.invalidCredentials);

      final result = await BackgroundSyncRunner(guard: guard).run();

      expect(result.outcome, BackgroundSyncOutcome.disabledByGuard);
    });

    test('前台正在同步时让路', () async {
      await givenReadyToSync();
      const lock = ForegroundSyncLock();
      await lock.acquire();

      final result = await BackgroundSyncRunner().run();

      expect(result.outcome, BackgroundSyncOutcome.foregroundBusy);
    });

    test('前台的锁过期了就不再让路', () async {
      // 防的是"前台持锁时被杀掉，后台从此永远跳过"。
      await givenReadyToSync();
      const lock = ForegroundSyncLock();
      await lock.acquire(
          now: DateTime.now().subtract(const Duration(minutes: 30)));

      // 用假 provider 让它在读数据库之前就停下——这条测的是"有没有被锁拦住"，
      // 不是后面的流程。真去开 sqflite 的话单测环境里没有 databaseFactory。
      final result =
          await BackgroundSyncRunner(tableProvider: _NoTableProvider()).run();

      expect(result.outcome, BackgroundSyncOutcome.notImportedTable,
          reason: '越过了前台锁这一关，说明过期判断生效了');
    });

    test('没存账号密码时不往下走', () async {
      SharedPreferences.setMockInitialValues({'tableId': 1});

      final result = await BackgroundSyncRunner().run();

      expect(result.outcome, BackgroundSyncOutcome.noCredentials);
    });

    test('当前课表不是导入来的就没得更新', () async {
      await givenReadyToSync();

      final result = await BackgroundSyncRunner(
        tableProvider: _NoTableProvider(),
      ).run();

      expect(result.outcome, BackgroundSyncOutcome.notImportedTable);
    });

    test('拦截顺序：保护机制排在前台锁之前', () async {
      // 两个条件同时成立时，必须报 disabledByGuard。原因不是好看——
      // 前台锁只是效率问题（晚几小时更新），保护机制关乎的是会不会把用户的
      // 统一认证账号锁掉。日志里报错了原因，排查方向完全不同。
      await givenReadyToSync();
      final guard = BackgroundSyncGuard();
      await guard.recordLoginOutcome(
          failure: NjuLoginFailure.invalidCredentials);
      await guard.recordLoginOutcome(
          failure: NjuLoginFailure.invalidCredentials);
      await const ForegroundSyncLock().acquire();

      final result = await BackgroundSyncRunner(guard: guard).run();

      expect(result.outcome, BackgroundSyncOutcome.disabledByGuard);
    });

    test('拦截时会往日志里写一句，排查时不至于两眼一抹黑', () async {
      await givenReadyToSync();
      await const ForegroundSyncLock().acquire();
      final log = <String>[];

      await BackgroundSyncRunner().run(log: log);

      expect(log, isNotEmpty);
      expect(log.join(), contains('前台'));
    });
  });

  group('该不该发通知', () {
    test('没有变化就不发——天天推"没有变化"用户会把通知关掉', () {
      const result =
          BackgroundSyncResult.forTesting(BackgroundSyncOutcome.ok);
      expect(result.hasChangesWorthNotifying, isFalse);
    });

    test('学期变了要通知：这一步得用户自己去导入页确认', () {
      const result = BackgroundSyncResult.forTesting(
          BackgroundSyncOutcome.semesterChanged);
      expect(result.hasChangesWorthNotifying, isTrue);
    });

    test('被拦下来的几轮都不该发通知', () {
      for (final outcome in [
        BackgroundSyncOutcome.disabledByGuard,
        BackgroundSyncOutcome.foregroundBusy,
        BackgroundSyncOutcome.noCredentials,
        BackgroundSyncOutcome.notImportedTable,
        BackgroundSyncOutcome.emptyFetch,
        BackgroundSyncOutcome.error,
      ]) {
        expect(
          BackgroundSyncResult.forTesting(outcome).hasChangesWorthNotifying,
          isFalse,
          reason: '$outcome 不该打扰用户',
        );
      }
    });

    test('只有保护机制真的停用了才提醒用户去重新登录', () {
      expect(
        const BackgroundSyncResult.forTesting(
          BackgroundSyncOutcome.loginFailed,
          verdict: GuardVerdict.disabled,
        ).needsUserAttention,
        isTrue,
      );
      // 还没到阈值、或者根本是滑块没过，都安静处理。
      expect(
        const BackgroundSyncResult.forTesting(
          BackgroundSyncOutcome.loginFailed,
          verdict: GuardVerdict.counted,
        ).needsUserAttention,
        isFalse,
      );
      expect(
        const BackgroundSyncResult.forTesting(
          BackgroundSyncOutcome.loginFailed,
          verdict: GuardVerdict.ignored,
        ).needsUserAttention,
        isFalse,
      );
    });
  });
}
