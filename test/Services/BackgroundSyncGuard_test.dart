import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wheretosleepinnju/Services/BackgroundSyncGuard.dart';
import 'package:wheretosleepinnju/Services/NjuLoginService.dart';

/// 这组测试锁的是**唯一可能真正伤害到用户的那条路径**：后台拿着失效的
/// 凭据反复登录，把统一认证账号锁掉——而那个账号同时是邮箱、图书馆、成绩
/// 系统的入口，用户毫不知情。
///
/// 所以这里测得比别处细：不只测"到阈值会停用"，还专门测"哪些失败**不该**
/// 计数"。后者判错的后果同样严重，只是方向相反——滑块偶尔没过就把自动更新
/// 关掉，这个功能活不过一周。
void main() {
  setUp(() {
    // 每条用例一份干净的存储，避免互相污染。
    SharedPreferences.setMockInitialValues({});
  });

  group('凭据失败计数', () {
    test('连续两次凭据失败就停用', () async {
      final guard = BackgroundSyncGuard();

      expect(
        await guard.recordLoginOutcome(
            failure: NjuLoginFailure.invalidCredentials),
        GuardVerdict.counted,
        reason: '第一次只计数，先不惊动用户——可能只是个意外',
      );
      expect(await guard.shouldRunRound(), isTrue, reason: '还没到阈值，下轮照跑');

      expect(
        await guard.recordLoginOutcome(
            failure: NjuLoginFailure.invalidCredentials),
        GuardVerdict.disabled,
      );
      expect(await guard.shouldRunRound(), isFalse, reason: '停用后一次都不许再跑');
    });

    test('停用之后再也不跑，不是"少跑几次"', () async {
      final guard = BackgroundSyncGuard();
      await guard.recordLoginOutcome(
          failure: NjuLoginFailure.invalidCredentials);
      await guard.recordLoginOutcome(
          failure: NjuLoginFailure.invalidCredentials);

      // 连查 5 轮都必须是 false。这条要是松了，就等于"降低频率继续试"，
      // 账号照样会被锁，只是慢一点。
      for (var i = 0; i < 5; i++) {
        expect(await guard.shouldRunRound(), isFalse);
      }
    });

    test('停用时记下时间，用户才知道是什么时候断的', () async {
      final guard = BackgroundSyncGuard();
      final at = DateTime(2026, 8, 14, 3, 30);
      await guard.recordLoginOutcome(
          failure: NjuLoginFailure.invalidCredentials);
      await guard.recordLoginOutcome(
          failure: NjuLoginFailure.invalidCredentials, now: at);

      final state = await guard.read();
      expect(state.disabled, isTrue);
      expect(state.disabledAt, at.toIso8601String());
    });

    test('阈值可配，取 1 时一次就停', () async {
      final guard = BackgroundSyncGuard(maxCredentialFailures: 1);
      expect(
        await guard.recordLoginOutcome(
            failure: NjuLoginFailure.invalidCredentials),
        GuardVerdict.disabled,
      );
    });
  });

  group('哪些失败不该计数', () {
    // 这一组是防"误关自动更新"的。滑块识别本来就有失败率，把它算进凭据
    // 失败的话，跑不了几天就会自己把功能关掉，而密码根本没问题。
    for (final failure in [
      NjuLoginFailure.sliderFailed,
      NjuLoginFailure.imageCaptcha,
      NjuLoginFailure.sliderNoPointerSupport,
      NjuLoginFailure.network,
      NjuLoginFailure.timeout,
      NjuLoginFailure.scriptFailed,
      NjuLoginFailure.unknown,
    ]) {
      test('${failure.name} 反复失败也不会停用', () async {
        final guard = BackgroundSyncGuard();
        for (var i = 0; i < 10; i++) {
          expect(await guard.recordLoginOutcome(failure: failure),
              GuardVerdict.ignored);
        }
        expect(await guard.shouldRunRound(), isTrue);
        expect((await guard.read()).consecutiveCredentialFailures, 0);
      });
    }

    test('非凭据失败夹在中间，不会打断凭据失败的连续计数', () async {
      // 真实场景：第一天密码错，第二天网络不好，第三天密码还是错。
      // 中间那次网络问题不该把计数清零——密码从头到尾就是错的。
      final guard = BackgroundSyncGuard();
      await guard.recordLoginOutcome(
          failure: NjuLoginFailure.invalidCredentials);
      await guard.recordLoginOutcome(failure: NjuLoginFailure.network);
      expect(
        await guard.recordLoginOutcome(
            failure: NjuLoginFailure.invalidCredentials),
        GuardVerdict.disabled,
        reason: '两次凭据失败就该停，中间的网络错误不算数也不清零',
      );
    });
  });

  group('恢复', () {
    test('登录成功清零计数', () async {
      final guard = BackgroundSyncGuard();
      await guard.recordLoginOutcome(
          failure: NjuLoginFailure.invalidCredentials);
      expect((await guard.read()).consecutiveCredentialFailures, 1);

      expect(await guard.recordLoginOutcome(), GuardVerdict.ok);
      expect((await guard.read()).consecutiveCredentialFailures, 0);
    });

    test('计数清零后要重新攒够两次才停用', () async {
      final guard = BackgroundSyncGuard();
      await guard.recordLoginOutcome(
          failure: NjuLoginFailure.invalidCredentials);
      await guard.recordLoginOutcome(); // 成功，清零

      expect(
        await guard.recordLoginOutcome(
            failure: NjuLoginFailure.invalidCredentials),
        GuardVerdict.counted,
        reason: '清零之后这是第一次，不该直接停用',
      );
    });

    test('用户在前台重新登录成功，后台检查自动恢复', () async {
      final guard = BackgroundSyncGuard();
      await guard.recordLoginOutcome(
          failure: NjuLoginFailure.invalidCredentials);
      await guard.recordLoginOutcome(
          failure: NjuLoginFailure.invalidCredentials);
      expect(await guard.shouldRunRound(), isFalse);

      await guard.reenable();

      final state = await guard.read();
      expect(state.disabled, isFalse);
      expect(state.consecutiveCredentialFailures, 0);
      expect(state.disabledAt, isNull);
      expect(await guard.shouldRunRound(), isTrue);
    });

    test('后台自己跑通一轮也能解除停用', () async {
      // 用户在前台改好了密码但没走导入页（比如只是打开 App 让凭据同步过），
      // 下一轮后台登录成功，就该自己恢复，不必非等前台那条路径。
      final guard = BackgroundSyncGuard();
      await guard.recordLoginOutcome(
          failure: NjuLoginFailure.invalidCredentials);
      await guard.recordLoginOutcome(
          failure: NjuLoginFailure.invalidCredentials);

      expect(await guard.recordLoginOutcome(), GuardVerdict.ok);
      expect(await guard.shouldRunRound(), isTrue);
    });
  });

  group('通知时机', () {
    test('只有停用那一下才推通知', () async {
      // 每次滑块没过都推一条通知等于骚扰；停用了不推，用户永远不知道
      // 课表为什么不更新了。只有这一个时刻两者都不占。
      expect(GuardVerdict.disabled.shouldNotifyUser, isTrue);
      expect(GuardVerdict.counted.shouldNotifyUser, isFalse);
      expect(GuardVerdict.ignored.shouldNotifyUser, isFalse);
      expect(GuardVerdict.ok.shouldNotifyUser, isFalse);
    });
  });

  group('全新安装', () {
    test('没有任何记录时是启用的', () async {
      final guard = BackgroundSyncGuard();
      final state = await guard.read();
      expect(state.disabled, isFalse);
      expect(state.consecutiveCredentialFailures, 0);
      expect(state.disabledAt, isNull);
      expect(await guard.shouldRunRound(), isTrue);
    });
  });
}
