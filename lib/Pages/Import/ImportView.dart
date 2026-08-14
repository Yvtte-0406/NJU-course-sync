import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:scoped_model/scoped_model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../Components/Toast.dart';
import '../../Resources/NjuConfig.dart';
import '../../Services/BackgroundSyncGuard.dart';
import '../../Services/CourseSyncService.dart';
import '../../Services/ForegroundSyncLock.dart';
import '../../Services/NjuLoginService.dart';
import '../../Utils/NjuCredentialStore.dart';
import '../../Utils/States/MainState.dart';

/// 南大专属导入/登录流程。
///
/// 只有一条登录链路：拿到账号密码 -> 后台 WebView 里跑自动登录脚本
/// （填表 + 过滑块拼图，遇到图形验证码就把真实网页显示出来兜底）->
/// 复用 [NjuEhallJsonImporter] 从已认证的 WebView 读取 eHall JSON，
/// 写入现有课程表模型。
///
/// 账号密码从哪来分两种：第一次用要用户手输（[_Stage.loginForm]），
/// 之后存在 [NjuCredentialStore] 里，进来先看到三选一的入口页
/// （[_Stage.entryChoice]）：
/// - "导入课程表"：拿存的账号密码重新登录，新建一张课表（原来"自动更新"
///   的行为，名字容易让人误以为会更新已有课表，改叫这个）。
/// - "更新当前课程表"：同样重新登录，但抓完之后不新建表，而是跟
///   [MainStateModel] 当前显示的那张表做 diff、展示变更预览，用户确认后
///   再落库（逻辑跟"课表管理"里的"检查更新"一致，只是从这里发起时会带上
///   完整的自动登录链路，不依赖已有登录会话）。
/// - "新账号登录"：强制回到手输表单，换一个账号，登录成功后新建一张表。
///
/// 早期版本还有一条"快捷导入"：不输账密，直接拿 WebView 里残留的
/// Cookie 去访问目标页。实测会话保不住（系统清后台、Cookie 过期都会让
/// 它失效），失败率高到没有使用价值，已经删掉——现在"之前登录过"省掉的
/// 只是重新输账号密码，登录该走的流程一步都不少。
class ImportView extends StatefulWidget {
  const ImportView({Key? key}) : super(key: key);

  @override
  State<ImportView> createState() => _ImportViewState();
}

enum _Stage {
  checkingPriorLogin,
  entryChoice,
  loginForm,
  loggingIn,
  needManualLogin,
  fetching,
  emptyResult,
  reviewingUpdate,
  error,
}

class _ImportViewState extends State<ImportView> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _syncService = CourseSyncService();
  // 写库期间挡住后台任务，避免两个 isolate 同时开 sqflite。
  final _lock = const ForegroundSyncLock();

  _Stage _stage = _Stage.checkingPriorLogin;
  // 重试时要回到的"起始页"：之前登录过、账号密码也还在，就是三选一的
  // 入口页，否则是登录表单。
  _Stage _initialStage = _Stage.loginForm;
  String _statusText = '';
  String _errorText = '';

  WebViewController? _webViewController;
  NjuEntryConfig? _activeConfig;

  /// 当前这次登录。手动兜底时用户接手的就是它建的那个 WebView，所以登录
  /// 失败了也不能立刻扔——要等用户离开这一页或重试时才 [NjuLoginService.dispose]。
  NjuLoginService? _loginService;

  // 本次登录成功后要做什么：新建一张表，还是更新当前显示的那张表。
  // 由入口页按钮点了哪个决定，登录本身没有任何区别。
  bool _updatingCurrentTable = false;
  SyncReport? _updateReport;

  /// 抓到 0 门课时把结果留下来，展示给用户判断到底是哪一步的问题。
  FetchResult? _emptyResult;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  /// "登录成功过"跟"课表导入成功过"是两件独立的事——比如暑期没课，
  /// 抓取那一步会失败、根本不会生成课表，但登录本身是成功的。所以这里
  /// 单独存一个标记，只要登录本身通过了就记上，不依赖有没有课表。
  static const _prefsHasLoggedInKey = 'nju_has_logged_in_before';

  /// 决定进来先看到哪一页，顺便把记住的账号密码填进输入框。
  ///
  /// 两件事必须一起做：入口页的两个"重新登录"按钮都是拿存下来的账号密码
  /// 重跑一遍登录，所以"之前登录过"这个标记单独成立没用——用户手动清过
  /// 密码的话，入口页点了也没账号可用，那就跟没登录过一样直接进登录表单。
  Future<void> _bootstrap() async {
    bool hasPrior = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      hasPrior = prefs.getBool(_prefsHasLoggedInKey) ?? false;
    } catch (_) {
      hasPrior = false;
    }
    var username = '';
    var password = '';
    try {
      (username, password) = await NjuCredentialStore.read();
    } catch (_) {
      // 读不到就当没存过，退回登录表单让用户手输。
    }
    if (!mounted) return;
    setState(() {
      _usernameController.text = username;
      _passwordController.text = password;
      _initialStage = hasPrior && username.isNotEmpty && password.isNotEmpty
          ? _Stage.entryChoice
          : _Stage.loginForm;
      _stage = _initialStage;
    });
  }

  Future<void> _markLoginSucceeded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsHasLoggedInKey, true);
    } catch (_) {
      // 存不上就算了，最多下次还是从登录表单开始，不影响这次的登录本身。
    }
  }

  /// 只在 Android 上、只问一次：小米/OPPO/vivo 等厂商定制系统喜欢清后台/
  /// 清缓存，登录会话（WebView 里的 Cookie）存在系统层面，App 自己保护
  /// 不了，只能申请忽略电池优化来降低被系统当成"后台可清理进程"的概率。
  /// 这只是降低概率，不是保证；用户拒绝也不影响正常使用，所以失败/拒绝
  /// 都直接吞掉，不打断导入成功的流程。
  static const _prefsBatteryOptRequestedKey = 'nju_battery_opt_requested';

  Future<void> _maybeRequestBatteryOptimizationExemption() async {
    if (!Platform.isAndroid) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_prefsBatteryOptRequestedKey) ?? false) return;
      await prefs.setBool(_prefsBatteryOptRequestedKey, true);

      final status = await Permission.ignoreBatteryOptimizations.status;
      if (!status.isGranted) {
        await Permission.ignoreBatteryOptimizations.request();
      }
    } catch (_) {
      // 申请失败/被拒绝都无所谓，不影响导入本身。
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    // 页面都关了，脚本还在那个 WebView 里跑就纯属浪费（还会继续点登录按钮）。
    unawaited(_loginService?.dispose());
    super.dispose();
  }

  void _submitLoginForm() {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      Toast.showToast('请输入账号和密码', context);
      return;
    }
    _updatingCurrentTable = false;
    setState(() {
      _stage = _Stage.loggingIn;
      _statusText = '正在登录...';
    });
    unawaited(_runLogin(NjuConfig.loginProbe));
  }

  /// 跑一次完整的自动登录，然后按 [_updatingCurrentTable] 分流去抓取。
  ///
  /// 登录本身全在 [NjuLoginService] 里（填表、过滑块、判结果），这里只负责
  /// 三件界面的事：把 WebView 挂上去、把失败翻译成对应的页面、成功后接着抓。
  /// 手输账密和用记住的账密走的是同一个方法——区别只在账号密码从哪来。
  Future<void> _runLogin(NjuEntryConfig config) async {
    _activeConfig = config;
    await _loginService?.dispose();

    final service = NjuLoginService(
      onLog: (message, level) => debugPrint('[NjuAutoLogin][$level] $message'),
    );
    _loginService = service;

    // login() 在第一个 await 之前就把 controller 建好了，所以这里不等它
    // 返回就能拿到——WebView 得先挂进界面，手动兜底时才能立刻显示出来。
    final pending = service.login(
      username: _usernameController.text.trim(),
      password: _passwordController.text,
      config: config,
    );
    if (mounted) setState(() => _webViewController = service.controller);

    var result = await pending;
    if (!mounted) return;

    if (!result.success) {
      final handOver = await _handleLoginFailure(result);
      if (!handOver) return;
      // 页面已经交给用户了。等他自己登进去——成功之后走的是下面同一段
      // 收尾逻辑（记住账号、按分流抓取），跟自动登录成功没有区别。
      result = await service.awaitManualCompletion();
      if (!mounted) return;
      if (!result.success) {
        setState(() {
          _stage = _Stage.error;
          _errorText = '${result.failure!.message}，请重试';
        });
        return;
      }
    }

    unawaited(_markLoginSucceeded());
    // 登录真的成功了，把这次用的账号密码记住：下次进来就能直接用入口页的
    // 两个按钮，不用再输一遍。用记住的账密登录时存的就是同一份，重存无害。
    unawaited(NjuCredentialStore.save(
      _usernameController.text.trim(),
      _passwordController.text,
    ));
    // 后台检查要是因为凭据连续失败被停用过，这次成功就是解除条件——用户
    // 改完密码回来登了一次，正是"凭据已经修好了"的证明。不在这里恢复的话
    // 后台会一直沉默，而用户根本不知道还有个开关等着他打开。
    unawaited(BackgroundSyncGuard().reenable());

    if (_updatingCurrentTable) {
      await _fetchAndUpdateCurrent(config);
    } else {
      await _fetchAndImport(config);
    }
  }

  /// 登录失败的处置。返回 true 表示**页面已经交给用户手动完成**，调用方
  /// 应该接着 await [NjuLoginService.awaitManualCompletion]；返回 false
  /// 表示已经落到错误页，这一轮到此结束。
  ///
  /// 分界线是「人能不能解决」：账号密码错和网络错走错误页——用户得先去改
  /// 密码或连上网，留在这一页手动登录也是白搭；其余一律把真实网页显示
  /// 出来，这些都是「机器没过、人能过」的情况。
  Future<bool> _handleLoginFailure(NjuLoginResult result) async {
    final failure = result.failure!;

    if (failure == NjuLoginFailure.invalidCredentials) {
      // 页面上通常有一句更具体的提示（"用户名或密码错误"/"账号已锁定"…），
      // 能抓到就用它，比笼统的"账号或密码错误"有用得多。
      final scraped = await _scrapeLoginError();
      if (!mounted) return false;
      setState(() {
        _stage = _Stage.error;
        if (scraped.startsWith('[DEBUG_DUMP]')) {
          _errorText = '没能识别到明确的错误提示。\n\n'
              '下面是登录表单的 HTML 结构（长按可复制发给开发者用来调整识别逻辑）：\n\n'
              '${scraped.substring('[DEBUG_DUMP]'.length)}';
        } else {
          _errorText =
              scraped.isNotEmpty ? '登录失败：$scraped' : '${failure.message}，请检查后重试';
        }
      });
      return false;
    }

    if (failure == NjuLoginFailure.network) {
      setState(() {
        _stage = _Stage.error;
        _errorText = failure.message;
      });
      return false;
    }

    if (failure == NjuLoginFailure.sliderNoPointerSupport) {
      // 滑块对合成的 touch 和 mouse 事件都没反应，多半是组件换了实现。
      // 这是代码要跟着改的，不是用户能解决的，日志里留一句好定位。
      debugPrint('[NjuAutoLogin] 滑块对合成的 touch/mouse 事件都无反应');
    }

    final detail = failure == NjuLoginFailure.unknown && result.detail.isNotEmpty
        ? '${failure.message}：${result.detail}'
        : failure.message;
    setState(() {
      _stage = _Stage.needManualLogin;
      _statusText = '$detail，请在下方手动完成登录';
    });
    return true;
  }

  Future<String> _runJs(String js) async {
    final result = await _webViewController!.runJavaScriptReturningResult(js);
    String status = result.toString();
    if (status.startsWith('"') && status.endsWith('"')) {
      status = status.substring(1, status.length - 1);
    }
    return status;
  }

  /// 调试用：把当前页面上"看起来像验证码/滑块组件"的那块 HTML 导出，
  /// 显示在错误页里方便长按复制。不知道确切的容器选择器，所以尝试了
  /// 几种常见命名，找不到就退而求其次导出整个可见弹窗/对话框区域。
  Future<void> _dumpCaptchaHtml() async {
    const js = '''
      (function(){
        var candidates = [
          '#sliderDiv', '.sliderDiv', '[id*="slider" i]', '[class*="slider" i]',
          '[id*="captcha" i]', '[class*="captcha" i]',
          '[id*="puzzle" i]', '[class*="puzzle" i]'
        ];
        for (var i=0;i<candidates.length;i++){
          var el = document.querySelector(candidates[i]);
          if (el) {
            var rect = el.getBoundingClientRect();
            if (rect.width > 0 && rect.height > 0) {
              // 往上找到看起来像"弹窗容器"的祖先，信息更完整。
              var container = el.closest('.card, .modal, .dialog, [class*="card" i], [class*="modal" i], [class*="dialog" i]') || el;
              return container.outerHTML.substring(0, 4000);
            }
          }
        }
        // 都没找到：退而求其次，导出所有可见的 canvas/dialog 元素的父级结构。
        var canvas = document.querySelector('canvas');
        if (canvas) {
          var parent = canvas.closest('div');
          for (var j=0;j<4 && parent && parent.parentElement; j++) parent = parent.parentElement;
          return (parent || canvas).outerHTML.substring(0, 4000);
        }
        return document.body.outerHTML.substring(0, 4000);
      })();
    ''';
    final dump = await _runJs(js);
    if (!mounted) return;
    setState(() {
      _stage = _Stage.error;
      _errorText = '验证组件结构（长按可复制发给开发者）：\n\n$dump';
    });
  }

  Future<String> _scrapeLoginError() async {
    const js = '''
      (function(){
        var candidates = document.querySelectorAll('[class*="error" i], [class*="tip" i], [id*="error" i], span, div');
        for (var i=0;i<candidates.length;i++){
          var el = candidates[i];
          var text = (el.textContent||'').trim();
          if(text && (text.indexOf('密码') !== -1 || text.indexOf('账号') !== -1 || text.indexOf('用户名') !== -1 || text.indexOf('错误') !== -1 || text.indexOf('失败') !== -1)){
            var rect = el.getBoundingClientRect();
            if(rect.width>0 && rect.height>0) return text.substring(0,80);
          }
        }
        // 没找到明确的错误文案：优先把"登录按钮"那个区域的 HTML 吐出来
        // （之前的 dump 都在表单开头被截断，从没看到过按钮长什么样）。
        var pwd = document.querySelector('input[type="password"]');
        var form = pwd ? (pwd.form || pwd.closest('form')) : null;
        var btnArea = form ? form.querySelector('.ge-btn') : null;
        var dump = btnArea ? btnArea.outerHTML : (form ? form.outerHTML : document.body.innerHTML);
        return '[DEBUG_DUMP]' + dump.substring(0, 3000);
      })();
    ''';
    try {
      final result = await _webViewController!.runJavaScriptReturningResult(js);
      String text = result.toString();
      if (text.startsWith('"') && text.endsWith('"')) {
        text = text.substring(1, text.length - 1);
      }
      return text;
    } catch (e) {
      return '';
    }
  }

  Future<void> _fetchAndImport(NjuEntryConfig config) async {
    setState(() {
      _activeConfig = config;
      _stage = _Stage.fetching;
      _statusText = '正在获取课表...';
    });

    try {
      final fetch = await _syncService.fetch(_webViewController!, config);

      // 抓到 0 门课时，光看结果分不清"登录/抓取失败"和"这学期确实没排课"
      // ——两种情况都是一张空课表。所以这里不直接建表，先把抓到的东西摊开
      // 给用户看：能报出学期名称和代码，就说明登录和抓取都成功了。
      if (fetch.courseCount == 0) {
        if (!mounted) return;
        setState(() {
          _emptyResult = fetch;
          _stage = _Stage.emptyResult;
        });
        return;
      }

      await _importAsNewTable(config, fetch);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _errorText = '课表抓取失败：$e';
      });
    }
  }

  /// 新建一张课表落库，然后把它设为当前课表并收尾。
  ///
  /// 建表和写课程都在 [CourseSyncService] 里；留在这里的是必须要
  /// BuildContext 的那几件事：切换当前课表、申请电池优化白名单、提示、返回。
  Future<void> _importAsNewTable(
      NjuEntryConfig config, FetchResult fetch) async {
    // 建表期间后台任务要是醒过来，两个 isolate 会同时写同一个 sqflite 文件。
    // 持锁让后台跳过本轮，代价只是晚几小时更新。
    final tableId = await _lock
        .protect(() => _syncService.importAsNewTable(config, fetch));

    if (mounted) {
      await ScopedModel.of<MainStateModel>(context).changeclassTable(tableId);
    }
    await _maybeRequestBatteryOptimizationExemption();

    if (!mounted) return;
    Toast.showToast('导入成功', context);
    Navigator.of(context).pop(true);
  }

  /// "更新当前课程表"：抓到最新数据后不新建表，跟当前显示的那张表做比对，
  /// 进 [_Stage.reviewingUpdate] 让用户看变更预览再决定要不要应用。
  ///
  /// 比对逻辑跟"课表管理"里的"检查更新"是同一份（[CourseSyncService]），
  /// 区别只在于这里带了完整的自动登录链路，不依赖已有会话还没过期。
  Future<void> _fetchAndUpdateCurrent(NjuEntryConfig config) async {
    setState(() {
      _activeConfig = config;
      _stage = _Stage.fetching;
      _statusText = '正在获取最新课表并比对...';
    });

    try {
      final fetch = await _syncService.fetch(_webViewController!, config);
      final tableId =
          await ScopedModel.of<MainStateModel>(context).getClassTable();
      final report = await _syncService.compareWithTable(
        config: config,
        fetch: fetch,
        tableId: tableId,
      );

      switch (report.outcome) {
        case SyncOutcome.emptyFetch:
          // 跟导入路径走同一个诊断页。一句"抓取失败"是过度断言——登录成功
          // 但这学期确实没排课，跟真的抓取失败，结果都是 0 门课，得把学期
          // 信息摊出来让用户自己判断。
          if (!mounted) return;
          setState(() {
            _emptyResult = fetch;
            _stage = _Stage.emptyResult;
          });
          return;
        case SyncOutcome.noSuchTable:
          if (!mounted) return;
          setState(() {
            _stage = _Stage.error;
            _errorText = '当前没有正在显示的课表，请先用"导入课程表"建一张。';
          });
          return;
        case SyncOutcome.semesterChanged:
          // 换学期了就不是"更新"而是"换一张表"：逐条比对上学期和这学期的课
          // 没有意义（几乎全是新增 + 消失）。新建一张表切过去，旧表留作
          // 历史，手动添加的课自然不会带过来。
          await _importAsNewTable(config, fetch);
          return;
        case SyncOutcome.ok:
          if (!mounted) return;
          setState(() {
            _updateReport = report;
            _stage = _Stage.reviewingUpdate;
          });
          return;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _errorText = '课表更新失败：$e';
      });
    }
  }

  Future<void> _applyUpdateChanges() async {
    await _lock.protect(() => _syncService.applyChanges(_updateReport!));
    if (!mounted) return;
    Toast.showToast('已更新当前课程表', context);
    Navigator.of(context).pop(true);
  }

  /// 统一的"重置状态回到某个起始页"，默认回到 [_initialStage]（三选一
  /// 入口页或登录表单），也可以指定具体页面（比如"新账号登录"按钮要强制
  /// 回登录表单，不是回入口页）。
  void _retry({_Stage? stage}) {
    // 上一轮的 WebView 连同里面还在跑的脚本一起丢掉，下一轮 [_runLogin]
    // 会新建一个。不停的话它会继续在后台点登录按钮。
    unawaited(_loginService?.dispose());
    _loginService = null;
    setState(() {
      _stage = stage ?? _initialStage;
      _statusText = '';
      _errorText = '';
      _webViewController = null;
      _activeConfig = null;
      _updatingCurrentTable = false;
      _updateReport = null;
      _emptyResult = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('导入南大课表')),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (_stage) {
      case _Stage.checkingPriorLogin:
        return const Center(child: CircularProgressIndicator());
      case _Stage.entryChoice:
        return _buildEntryChoice(context);
      case _Stage.loginForm:
        return _buildLoginForm(context);
      case _Stage.loggingIn:
      case _Stage.fetching:
        return _buildProgressOverWebView(context);
      case _Stage.needManualLogin:
        return Column(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              Text(_statusText, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _dumpCaptchaHtml,
                child: const Text('（调试用）导出当前验证组件结构'),
              ),
            ]),
          ),
          Expanded(child: WebViewWidget(controller: _webViewController!)),
        ]);
      case _Stage.emptyResult:
        return _buildEmptyResult(context);
      case _Stage.reviewingUpdate:
        return _buildUpdateReview(context);
      case _Stage.error:
        return _buildError(context);
    }
  }

  /// 抓到 0 门课时的说明页。
  ///
  /// 存在的意义是把"登录/抓取失败"和"这学期确实没排课"区分开——两者的
  /// 结果都是一张空课表，光看课表分不出来。能显示出学期名称和学期代码，
  /// 就说明登录成功、接口通了、数据也解析出来了，只是内容为空。
  Widget _buildEmptyResult(BuildContext context) {
    final fetch = _emptyResult;
    final semesterName = fetch?.semesterName ?? '';
    final semesterCode = fetch?.semesterCode ?? '';
    final gotSemester = fetch?.hasSemesterInfo ?? false;

    Widget row(String label, String value, {bool ok = true}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(ok ? Icons.check_circle : Icons.help_outline,
                  size: 18,
                  color: ok ? Colors.green : Theme.of(context).hintColor),
              const SizedBox(width: 8),
              SizedBox(width: 76, child: Text(label)),
              Expanded(
                  child: SelectableText(value.isEmpty ? '（空）' : value,
                      style: const TextStyle(fontWeight: FontWeight.w600))),
            ],
          ),
        );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('抓取完成，但这个学期没有课程',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            gotSemester
                ? '登录和抓取都成功了——下面这些信息就是从教务系统读回来的。\n'
                    '课程数为 0，说明这个学期教务系统里确实还没有排课数据。'
                : '连学期信息都没读到，可能是登录状态或接口出了问题。',
            style: TextStyle(color: Theme.of(context).hintColor, height: 1.6),
          ),
          if (_updatingCurrentTable) ...[
            const SizedBox(height: 12),
            Text(
              '本轮更新已跳过，你的课表没有任何改动。\n'
              '（抓到 0 门课时如果照常比对，现有课程会全部被判成"消失"，'
              '所以这种情况一律不动数据。）',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.primary, height: 1.6),
            ),
          ],
          const SizedBox(height: 20),
          row('登录', '成功（已到达课表页）'),
          row('学期名称', semesterName, ok: semesterName.isNotEmpty),
          row('学期代码', semesterCode, ok: semesterCode.isNotEmpty),
          row('课程数', '0', ok: false),
          const SizedBox(height: 20),
          Text('原始返回数据', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              _previewJson(fetch?.raw ?? const <String, dynamic>{}),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('返回'),
              ),
            ),
            // 更新路径下没有"建表"这回事，本来就没动数据，只需要返回。
            if (!_updatingCurrentTable) ...[
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: () async {
                    final config = _activeConfig;
                    if (config == null || fetch == null) return;
                    setState(() => _stage = _Stage.fetching);
                    await _importAsNewTable(config, fetch);
                  },
                  child: const Text('仍然创建空课表'),
                ),
              ),
            ],
          ]),
        ],
      ),
    );
  }

  /// 原始返回数据的预览。太长会把页面撑爆，截断即可——这里只是给人眼
  /// 确认"确实拿到东西了"，不是完整日志。
  String _previewJson(Map<String, dynamic> map) {
    try {
      final text = const JsonEncoder.withIndent('  ').convert(map);
      return text.length > 1500 ? '${text.substring(0, 1500)}\n…（已截断）' : text;
    } catch (e) {
      return '无法序列化：$e\n\n$map';
    }
  }

  /// 登录/抓取过程中的转圈界面。
  ///
  /// WebView 铺在底下、被不透明遮罩盖住，是为了**手动兜底能立刻接上**：滑块
  /// 没过时要把同一个页面交给用户，页面已经在树上就只是掀掉遮罩，不用重新
  /// 加载一遍登录页。
  ///
  /// 注意这里**不是**为了让 `requestAnimationFrame` 跑起来。曾经以为轨迹回放
  /// 依赖 WebView 参与合成，实验证明相反：不挂进视图树的 WebView 反而跑满
  /// 60fps，挂上去的因为要参与合成只有 8fps。后台任务能成立就是靠这个结论。
  Widget _buildProgressOverWebView(BuildContext context) {
    final progress = Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(_statusText),
        ],
      ),
    );
    final controller = _webViewController;
    if (controller == null) return progress;
    return Stack(
      children: [
        Positioned.fill(child: WebViewWidget(controller: controller)),
        Positioned.fill(
          child: Container(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: progress,
          ),
        ),
      ],
    );
  }

  Widget _buildEntryChoice(BuildContext context) {
    final maskedUsername = _maskUsername(_usernameController.text.trim());
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('已记住账号 $maskedUsername', style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            const Text(
              '都会用记住的账号密码重新登录一次；只有在出现图形验证码的时候\n'
              '才会把登录页显示出来让你手动完成。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _startNewImport,
              icon: const Icon(Icons.add),
              label: const Text('导入课程表'),
            ),
            const SizedBox(height: 4),
            const Text('抓取最新课表，新建一张课表',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _startUpdateCurrent,
              icon: const Icon(Icons.sync),
              label: const Text('更新当前课程表'),
            ),
            const SizedBox(height: 4),
            const Text('抓取最新课表，跟当前 App 里显示的这张表比对，\n预览变更后再决定是否应用',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => _retry(stage: _Stage.loginForm),
              icon: const Icon(Icons.person_outline),
              label: const Text('新账号登录'),
            ),
            const SizedBox(height: 4),
            const Text('换一个账号登录，新建一张课表',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  /// 学号中间打码，只是让用户确认"是不是这个账号"，不用把完整学号亮在
  /// 屏幕上。太短的就整个遮掉，免得反而暴露。
  static String _maskUsername(String username) {
    if (username.length <= 4) return '*' * username.length;
    return '${username.substring(0, 2)}'
        '${'*' * (username.length - 4)}'
        '${username.substring(username.length - 2)}';
  }

  /// 拿存下来的账号密码重跑一遍完整登录，跟手输账密走的是同一条链路
  /// （[_runLogin] -> [NjuLoginService] 填表过滑块 -> 命中目标页抓取），
  /// 区别只是用户不用再输一遍。[updateCurrent] 决定登录成功后是新建一张表
  /// 还是更新当前显示的那张。
  void _startWithSavedCredentials({required bool updateCurrent}) {
    if (_usernameController.text.trim().isEmpty ||
        _passwordController.text.isEmpty) {
      // [_bootstrap] 已经挡过一次，正常进不来；真进来了就当没登录过。
      _retry(stage: _Stage.loginForm);
      return;
    }
    _updatingCurrentTable = updateCurrent;
    setState(() {
      _stage = _Stage.loggingIn;
      _statusText = '正在用记住的账号自动登录...';
    });
    unawaited(_runLogin(NjuConfig.loginProbe));
  }

  void _startNewImport() =>
      _startWithSavedCredentials(updateCurrent: false);

  void _startUpdateCurrent() =>
      _startWithSavedCredentials(updateCurrent: true);

  Widget _buildLoginForm(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('南京大学统一身份认证', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 24),
          TextField(
            controller: _usernameController,
            decoration: const InputDecoration(labelText: '学号/工号', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passwordController,
            obscureText: true,
            decoration: const InputDecoration(labelText: '密码', border: OutlineInputBorder()),
            onSubmitted: (_) => _submitLoginForm(),
          ),
          const SizedBox(height: 24),
          ElevatedButton(onPressed: _submitLoginForm, child: const Text('登录')),
          if (_usernameController.text.isNotEmpty ||
              _passwordController.text.isNotEmpty) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: () async {
                await NjuCredentialStore.clear();
                if (!mounted) return;
                setState(() {
                  _usernameController.clear();
                  _passwordController.clear();
                  // 账号密码没了，自动更新就没得可用，重试的落点也要跟着
                  // 改回登录表单，不然会弹回一个点了就跳走的选择页。
                  _initialStage = _Stage.loginForm;
                });
                Toast.showToast('已清除记住的账号密码', context);
              },
              child: const Text('清除已记住的账号密码'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(onPressed: _retry, child: const Text('重试')),
              // 自动更新失败最常见的原因就是密码在学校那边改过了，重试
              // 多少次都是同样的结果，得给一条换账号密码的出路。
              if (_initialStage == _Stage.entryChoice) ...[
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: () => _retry(stage: _Stage.loginForm),
                  child: const Text('重新输入账号密码'),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SelectableText(
              _errorText,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ),
      ],
    );
  }

  /// "更新当前课程表"的变更预览：新增和字段变更列出来等用户点应用；
  /// 消失的课程已经按两轮宽限期自动处理过了（[sweepMissingCourses]），
  /// 这里只是把处理结果告诉用户，不需要他再确认一次。
  Widget _buildUpdateReview(BuildContext context) {
    final diff = _updateReport!.diff!;
    final sweepSummary = _updateReport?.sweep?.summary;
    if (diff.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(sweepSummary ?? '没有检测到课表变化。',
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('完成'),
              ),
            ],
          ),
        ),
      );
    }

    final items = <Widget>[];

    if (sweepSummary != null) {
      items.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(sweepSummary,
            style: TextStyle(color: Theme.of(context).colorScheme.primary)),
      ));
    }

    if (diff.addedCourses.isNotEmpty) {
      items.add(_updateSectionTitle('新增课程'));
      for (final entry in diff.addedCourses.entries) {
        for (final c in entry.value) {
          items.add(ListTile(
            title:
                Text(c.name ?? '', style: const TextStyle(color: Colors.green)),
            subtitle: Text('${c.teacher ?? ''} · ${c.classroom ?? ''}'),
          ));
        }
      }
    }

    if (diff.removedCourses.isNotEmpty) {
      items.add(_updateSectionTitle('学校数据里没找到（已从课表隐藏）'));
      for (final entry in diff.removedCourses.entries) {
        for (final c in entry.value) {
          items.add(ListTile(
            title: Text(c.name ?? '', style: const TextStyle(color: Colors.red)),
            subtitle: Text('${c.teacher ?? ''} · ${c.classroom ?? ''}'),
          ));
        }
      }
    }

    if (diff.changedSlots.isNotEmpty) {
      items.add(_updateSectionTitle('信息变更'));
      for (final change in diff.changedSlots) {
        final fieldNames = {
          'classroom': '教室',
          'info': '备注',
          'weekTime': '星期',
          'startTime': '起始节次',
          'timeCount': '节次跨度',
          'weeks': '周次',
        };
        final desc = change.changedFields.entries
            .map((e) =>
                '${fieldNames[e.key] ?? e.key}：${e.value.key ?? ''} → ${e.value.value ?? ''}')
            .join('\n');
        items.add(ListTile(
          title: Text(change.oldSlot.name ?? ''),
          subtitle: Text(desc),
        ));
      }
    }

    if (diff.addedSlots.isNotEmpty) {
      items.add(_updateSectionTitle('新增时间段'));
      for (final c in diff.addedSlots) {
        items.add(ListTile(
          title:
              Text(c.name ?? '', style: const TextStyle(color: Colors.green)),
          subtitle:
              Text('星期${c.weekTime} 第${c.startTime}节 · ${c.classroom ?? ''}'),
        ));
      }
    }

    if (diff.removedSlots.isNotEmpty) {
      items.add(_updateSectionTitle('取消的时间段（已从课表隐藏）'));
      for (final c in diff.removedSlots) {
        items.add(ListTile(
          title: Text(c.name ?? '', style: const TextStyle(color: Colors.red)),
          subtitle:
              Text('星期${c.weekTime} 第${c.startTime}节 · ${c.classroom ?? ''}'),
        ));
      }
    }

    return Column(children: [
      Expanded(child: ListView(children: items)),
      Padding(
        padding: const EdgeInsets.all(12),
        child: ElevatedButton(
          onPressed: _applyUpdateChanges,
          child: const Text('应用新增与变更'),
        ),
      ),
    ]);
  }

  Widget _updateSectionTitle(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(title,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      );
}
