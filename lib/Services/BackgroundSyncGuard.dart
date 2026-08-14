import 'package:shared_preferences/shared_preferences.dart';

import 'NjuLoginService.dart';

/// 后台自动更新的失败保护：连续用错的凭据登录会把统一认证账号锁掉，
/// 这个类的存在就是为了不让那件事发生。
///
/// 危险长这样：用户在学校改了密码，本地存的还是旧的。后台每天拿旧密码登
/// 一次，几天下来账号被锁——而用户毫不知情，只会发现某天邮箱、图书馆、成绩
/// 系统一起登不上了。**这是整个自动更新功能唯一可能对用户造成实际伤害的
/// 地方**，所以规则定得很硬：连续 2 次凭据失败就彻底停用，等用户自己回来
/// 登录成功才恢复，中间一次都不再试。
///
/// 关键在于**哪些失败该计数**。只有 [NjuLoginFailure.invalidCredentials]
/// 算数。滑块没过、出图形验证码这些 [NjuLoginFailureX.needsHuman] 的失败跟
/// 密码对不对毫无关系，混进来数会让"连续两次就停用"被滑块误触发，把好端端
/// 的自动更新关掉；网络错误和超时同理。这个区分是 [NjuLoginService] 把失败
/// 分成两个独立维度的直接原因。
class BackgroundSyncGuard {
  BackgroundSyncGuard({this.maxCredentialFailures = 2});

  /// 连续多少次凭据失败就停用。
  ///
  /// 取 2 而不是 1，是留给"密码刚好在这一轮改了"这种单次意外；取 2 而不是
  /// 更大，是因为每多试一次就多一分锁号风险，而代价只是用户晚一天收到通知。
  final int maxCredentialFailures;

  static const _kFailuresKey = 'nju_bg_sync_credential_failures';
  static const _kDisabledKey = 'nju_bg_sync_disabled';
  static const _kDisabledAtKey = 'nju_bg_sync_disabled_at';

  /// 读当前状态。
  ///
  /// 每次都 `reload()`：后台任务跑在独立 isolate 里，跟前台各有一份
  /// SharedPreferences 的内存副本。用户刚在前台重新登录成功、把停用标记
  /// 清掉了，后台不重读磁盘的话会拿到过期的"已停用"，白白跳过一轮。
  Future<GuardState> read() async {
    final sp = await SharedPreferences.getInstance();
    await sp.reload();
    return GuardState(
      consecutiveCredentialFailures: sp.getInt(_kFailuresKey) ?? 0,
      disabled: sp.getBool(_kDisabledKey) ?? false,
      disabledAt: sp.getString(_kDisabledAtKey),
    );
  }

  /// 这一轮该不该跑。停用之后一律不跑——不是"少跑几次"，是一次都不跑。
  Future<bool> shouldRunRound() async => !(await read()).disabled;

  /// 记一次登录结果，返回该怎么处置。[failure] 为 null 表示登录成功。
  ///
  /// 注意传进来的是**登录**的结果，不是整轮同步的结果：抓取失败说明不了
  /// 凭据有问题，登录成功就足以证明密码是对的，计数该清零。
  Future<GuardVerdict> recordLoginOutcome({
    NjuLoginFailure? failure,
    DateTime? now,
  }) async {
    final sp = await SharedPreferences.getInstance();
    await sp.reload();

    if (failure == null) {
      // 登录成功 = 凭据没问题。计数清零，并且把之前的停用也解除掉——用户
      // 可能是在前台改好密码后跑通的这一轮。
      await sp.setInt(_kFailuresKey, 0);
      await sp.setBool(_kDisabledKey, false);
      await sp.remove(_kDisabledAtKey);
      return GuardVerdict.ok;
    }

    if (failure != NjuLoginFailure.invalidCredentials) {
      // 跟凭据无关的失败：本轮放弃，但计数一动不动。滑块没过就把自动更新
      // 关掉的话，这个功能基本活不过一周。
      return GuardVerdict.ignored;
    }

    final failures = (sp.getInt(_kFailuresKey) ?? 0) + 1;
    await sp.setInt(_kFailuresKey, failures);

    if (failures < maxCredentialFailures) return GuardVerdict.counted;

    await sp.setBool(_kDisabledKey, true);
    await sp.setString(
        _kDisabledAtKey, (now ?? DateTime.now()).toIso8601String());
    return GuardVerdict.disabled;
  }

  /// 用户在前台重新登录成功之后调这个，恢复后台检查。
  ///
  /// 跟 [recordLoginOutcome] 传 null 是同一件事，单独给个名字是因为调用方
  /// 不一样：那个在后台任务里调，这个在 [ImportView] 登录成功时调。
  Future<void> reenable() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kFailuresKey, 0);
    await sp.setBool(_kDisabledKey, false);
    await sp.remove(_kDisabledAtKey);
  }
}

/// 保护机制的当前状态。
class GuardState {
  const GuardState({
    required this.consecutiveCredentialFailures,
    required this.disabled,
    this.disabledAt,
  });

  final int consecutiveCredentialFailures;
  final bool disabled;

  /// 什么时候被停用的，ISO8601。没停用就是 null。
  final String? disabledAt;
}

/// 记完一次登录结果之后，调用方该做什么。
enum GuardVerdict {
  /// 登录成功，计数已清零。照常往下走。
  ok,

  /// 跟凭据无关的失败（滑块、验证码、网络、超时）。放弃本轮，不通知用户
  /// ——这种事偶尔发生很正常，为它推送等于骚扰。
  ignored,

  /// 凭据失败但还没到阈值。放弃本轮，先不惊动用户，可能只是个意外。
  counted,

  /// 凭据连续失败到阈值，后台检查**已停用**。必须发通知告诉用户去重新
  /// 登录，否则他永远不知道课表为什么不更新了。
  disabled,
}

extension GuardVerdictX on GuardVerdict {
  /// 要不要给用户推一条通知。只有停用那一下推，其余都安静处理。
  bool get shouldNotifyUser => this == GuardVerdict.disabled;
}
