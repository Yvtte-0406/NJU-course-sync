import 'package:flutter/material.dart';

import '../../Components/Toast.dart';
import '../../Services/BackgroundSyncGuard.dart';
import '../../Services/BackgroundSyncScheduler.dart';
import '../../Services/SyncNotifier.dart';

/// 后台自动更新的开关与状态。
///
/// 除了开关本身，这一页还要回答用户两个必然会问的问题：**它到底跑没跑过**，
/// 以及**为什么突然不更新了**。后者尤其重要——凭据失效导致的自动停用如果
/// 不摆在明面上，用户只会觉得"这功能坏了"。
class BackgroundSyncSettingsView extends StatefulWidget {
  const BackgroundSyncSettingsView({Key? key}) : super(key: key);

  @override
  State<BackgroundSyncSettingsView> createState() =>
      _BackgroundSyncSettingsViewState();
}

class _BackgroundSyncSettingsViewState
    extends State<BackgroundSyncSettingsView> {
  static const _scheduler = BackgroundSyncScheduler();
  static const _notifier = SyncNotifier();

  bool _enabled = false;
  bool _loading = true;
  GuardState? _guard;
  BackgroundSyncRecord? _lastRun;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await _scheduler.isEnabled();
    final guard = await BackgroundSyncGuard().read();
    final lastRun = await _scheduler.lastRun();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _guard = guard;
      _lastRun = lastRun;
      _loading = false;
    });
  }

  Future<void> _toggle(bool value) async {
    setState(() => _enabled = value);
    if (value) {
      // 在这里申请通知权限，而不是 App 一启动就弹：打开这个开关本身就表示
      // "我想收到课表更新"，此时弹权限框用户知道是为了什么；不用这个功能的
      // 人则完全不会被打扰。
      //
      // 被拒绝也照常开启后台更新——课表还是会自动更新好，只是少了提醒。
      // 唯一的代价是"自动更新被暂停"这类消息推不出去，所以下面会说明一句。
      final granted = await _notifier.requestPermission();
      await _scheduler.enable();
      if (mounted && !granted && _notifier.isSupported) {
        Toast.showToast('没有通知权限，课表仍会自动更新，但更新和异常都不会提醒你', context);
      }
    } else {
      await _scheduler.disable();
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('后台自动更新')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: _buildItems(context)),
    );
  }

  List<Widget> _buildItems(BuildContext context) {
    if (!_scheduler.isSupported) {
      return [
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('这个平台暂不支持后台自动更新'),
          subtitle: Text(
            '课表更新仍然可以用：到「导入南大课表」点「更新当前课程表」，'
            '走的是同一套抓取和比对逻辑，只是需要你自己点一下。',
          ),
          isThreeLine: true,
        ),
      ];
    }

    return [
      SwitchListTile(
        title: const Text('每天自动检查课表更新'),
        subtitle: const Text('大约每 24 小时在后台登录一次并抓取最新课表，'
            '有变化会直接更新到你的课表上'),
        value: _enabled,
        onChanged: _toggle,
        isThreeLine: true,
      ),
      if (_enabled) ...[
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.schedule),
          title: const Text('上次后台同步'),
          subtitle: Text(_describeLastRun()),
          // 这两类的说明都不止一行：一句是"哪个学期没课"，一句是"失败了
          // 该怎么办"，挤成一行会被截断，正好把最要紧的建议截没。
          isThreeLine: _lastRun?.outcome == 'emptyFetch' ||
              _lastRun?.outcome == 'loginFailed',
        ),
        ListTile(
          leading: const Icon(Icons.play_circle_outline),
          title: const Text('立刻试跑一次'),
          // 周期任务第一次执行的时机由系统决定，可能要等很久。没有这个按钮
          // 的话，用户打开开关之后一整天看不到任何反馈，只能怀疑是不是坏了。
          subtitle: const Text('约 5 秒后在后台执行一轮，用来确认功能正常'),
          onTap: () async {
            await _scheduler.runOnceNow();
            if (!mounted) return;
            Toast.showToast('已排队，稍后回到这一页看结果', context);
          },
        ),
      ],
      const Divider(height: 1),
      if (_guard?.disabled ?? false) _buildDisabledWarning(context),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(
          '说明',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Text(
          '· 后台更新需要用到你保存的账号密码，每次都会重新登录一次。\n'
          '· 课表有变化时会发一条通知，没有变化就不打扰你。\n'
          '· 连续两次登录失败（密码错误）会自动停用，避免统一认证账号被锁定。'
          '重新登录成功后会自动恢复。\n'
          '· 厂商系统的省电策略可能推迟甚至阻止后台任务，这不是 App 能控制的。'
          '把本应用加入电池优化白名单可以降低概率。',
          style: TextStyle(height: 1.7),
        ),
      ),
    ];
  }

  /// 凭据失效导致的自动停用必须显眼——用户不会主动来这一页找原因，
  /// 但一旦来了，得让他一眼看到发生了什么、该做什么。
  Widget _buildDisabledWarning(BuildContext context) {
    final at = DateTime.tryParse(_guard?.disabledAt ?? '');
    final when = at == null ? '' : '（${at.month} 月 ${at.day} 日）';
    return Container(
      color: Theme.of(context).colorScheme.errorContainer,
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded,
              color: Theme.of(context).colorScheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '自动更新已暂停$when\n'
              '连续两次登录失败，多半是你在学校改过密码。请到「导入南大课表」'
              '用新密码登录一次，自动更新会随之恢复。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _describeLastRun() {
    final record = _lastRun;
    if (record == null) return '还没有跑过';
    final at = record.at;
    final when = at == null
        ? ''
        : '${at.month}-${at.day} ${at.hour.toString().padLeft(2, '0')}:'
            '${at.minute.toString().padLeft(2, '0')} · ';
    if (record.outcome == 'loginFailed') {
      return '$when${_loginFailureLabel(record.loginFailure)}';
    }
    return '$when${_outcomeLabel(record.outcome, record.semesterName)}';
  }

  /// 「登录失败」四个字对用户没用——这几种失败要做的事完全不同，得直接
  /// 说清楚下一步该干嘛。
  String _loginFailureLabel(String failure) {
    switch (failure) {
      case 'invalidCredentials':
        return '账号或密码不对。到「导入南大课表」用新密码登录一次即可恢复。';
      case 'imageCaptcha':
        return '出现了图形验证码，需要你手动登录一次。';
      case 'network':
        return '网络不通。校外访问教务系统需要先连上南京大学 VPN。';
      case 'sliderFailed':
        return '滑块验证没过。这种偶尔会发生，下一轮多半就好了，不用管。';
      case 'sliderNoPointerSupport':
        return '滑块验证方式变了，需要开发者适配。麻烦到反馈群里说一声。';
      case 'scriptFailed':
        return '登录脚本没能启动。重装一次 App 试试，还不行请反馈。';
      case 'timeout':
        return '登录超时。可能是网络慢或教务系统繁忙，下一轮会再试。';
      case '':
        // 旧版本存的记录没有这个字段，只能说到这一步。
        return '登录失败';
      default:
        return '登录失败（$failure）';
    }
  }

  String _outcomeLabel(String outcome, String semester) {
    final inSemester = semester.isEmpty ? '' : '（$semester）';
    switch (outcome) {
      case 'ok':
        return '已检查，课表是最新的$inSemester';
      case 'semesterChanged':
        return '教务系统已经是$semester了，需要新建课表';
      case 'emptyFetch':
        // 这句是这次改动的重点。空档期里教务系统停在上一个学期是很常见的，
        // 而那时候 0 门课完全正常——光说"没抓到课程"会让人以为功能坏了，
        // 把学期名摆出来就一眼看懂。
        return semester.isEmpty
            ? '没抓到课程，已跳过（未改动课表）'
            : '教务系统当前显示的是$semester，\n你在这个学期没有课程，已跳过（未改动课表）';
      // loginFailed 不在这里处理——它要按具体失败原因给建议，_describeLastRun
      // 会先拦下来交给 _loginFailureLabel。
      case 'disabledByGuard':
        return '已暂停，未执行';
      case 'foregroundBusy':
        return '当时你正在手动更新，已跳过';
      case 'noCredentials':
        return '没有保存的账号密码';
      case 'notImportedTable':
        return '当前课表不是导入来的';
      case 'error':
        return '出错了';
      default:
        return outcome;
    }
  }

}
