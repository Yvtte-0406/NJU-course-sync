import 'package:flutter_test/flutter_test.dart';
import 'package:wheretosleepinnju/Services/NjuLoginService.dart';

/// 这里测的是登录层里**不需要 WebView 的那部分**：把脚本抛上来的失败原因
/// 翻译成分类，以及每个分类的处置策略。
///
/// 为什么只测这些：`login()` 要真的建 WebView、加载南大的登录页、跑注入的
/// JS，那是集成测试的活，单元测试里没有 WebView 平台实现。而恰恰是这部分
/// 纯逻辑最需要锁住——后台任务要靠这个分类决定「停用并通知用户」还是
/// 「本轮放弃、下次再来」，判错的代价是把用户的统一认证账号锁掉。
void main() {
  group('失败原因分类', () {
    test('认得出脚本抛的三种具名错误码', () {
      expect(
        NjuLoginService.classifyFailure('NJU_INVALID_CREDENTIALS'),
        NjuLoginFailure.invalidCredentials,
      );
      expect(
        NjuLoginService.classifyFailure('NJU_SLIDER_FAILED_TWICE'),
        NjuLoginFailure.sliderFailed,
      );
      expect(
        NjuLoginService.classifyFailure('NJU_SLIDER_NO_POINTER_SUPPORT'),
        NjuLoginFailure.sliderNoPointerSupport,
      );
    });

    test('错误码被包在别的文字里也认得出', () {
      // 脚本实际抛的是 `Error: ...` 之类，原因码只是其中一段。
      expect(
        NjuLoginService.classifyFailure('登录失败: NJU_INVALID_CREDENTIALS at step 3'),
        NjuLoginFailure.invalidCredentials,
      );
    });

    test('不认识的原因归到 unknown，不冒充成账号密码错', () {
      // 这条是防呆用的：unknown 会被当成"可以重试"，而 invalidCredentials
      // 会触发停用+通知。把没见过的错误默认成后者会天天误报，默认成前者
      // 最多多试一轮。
      expect(
        NjuLoginService.classifyFailure('Timed out while loading slider captcha'),
        NjuLoginFailure.unknown,
      );
      expect(NjuLoginService.classifyFailure(''), NjuLoginFailure.unknown);
    });
  });

  group('处置策略', () {
    test('账号密码错绝不重试——后台重试会撞统一认证的账号锁定', () {
      expect(NjuLoginFailure.invalidCredentials.isWorthRetrying, isFalse);
    });

    test('滑块没过可以重试：机器没过，人能过，换个时间可能就成了', () {
      expect(NjuLoginFailure.sliderFailed.isWorthRetrying, isTrue);
      expect(NjuLoginFailure.network.isWorthRetrying, isTrue);
      expect(NjuLoginFailure.timeout.isWorthRetrying, isTrue);
    });

    test('滑块组件换实现了不该重试——那是代码要改，重试一万次也一样', () {
      expect(NjuLoginFailure.sliderNoPointerSupport.isWorthRetrying, isFalse);
    });

    test('需要真人的失败不计入凭据失败——它跟密码对不对无关', () {
      expect(NjuLoginFailure.imageCaptcha.needsHuman, isTrue);
      expect(NjuLoginFailure.sliderFailed.needsHuman, isTrue);
      // 账号密码错不需要"真人在场"，需要的是用户去改密码，两回事。
      expect(NjuLoginFailure.invalidCredentials.needsHuman, isFalse);
      expect(NjuLoginFailure.network.needsHuman, isFalse);
      expect(NjuLoginFailure.timeout.needsHuman, isFalse);
    });

    test('每个分类都有非空文案，且不含"接下来怎么办"', () {
      for (final failure in NjuLoginFailure.values) {
        expect(failure.message, isNotEmpty, reason: '$failure 缺文案');
        // 后续动作前后台不一样（前台"请在下方手动完成登录"、后台"已暂停
        // 自动更新"），所以文案里不能预设其中一种。
        expect(failure.message, isNot(contains('在下方')), reason: '$failure');
      }
    });

    test('两个维度是独立的，不能互相推导', () {
      // 用一个真实的反例锁住：imageCaptcha 需要真人，但不值得重试；
      // network 不需要真人，却值得重试。谁要是想把两个 getter 合并成
      // 一个，这条会红。
      expect(NjuLoginFailure.imageCaptcha.needsHuman, isTrue);
      expect(NjuLoginFailure.imageCaptcha.isWorthRetrying, isFalse);
      expect(NjuLoginFailure.network.needsHuman, isFalse);
      expect(NjuLoginFailure.network.isWorthRetrying, isTrue);
    });
  });
}
