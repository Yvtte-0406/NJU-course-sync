import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:scoped_model/scoped_model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../Components/Toast.dart';
import '../../Models/CourseModel.dart';
import '../../Models/CourseTableModel.dart';
import '../../Resources/NjuConfig.dart';
import '../../Utils/CourseImportCodec.dart';
import '../../Utils/States/MainState.dart';
import 'ImportFromBEView.dart';

/// 南大专属导入/登录流程。
///
/// 三段式：原生登录表单 -> 后台 WebView 自动登录（探测到验证码就把
/// 真实网页显示出来兜底）-> 本科/研究生选择 -> 复用
/// [ImportFromBEView.fetchCourseTableMap] 抓取课表并写库。
class ImportView extends StatefulWidget {
  const ImportView({Key? key}) : super(key: key);

  @override
  State<ImportView> createState() => _ImportViewState();
}

enum _Stage {
  checkingPriorLogin,
  quickImportChoice,
  loginForm,
  loggingIn,
  needManualLogin,
  fetching,
  error,
}

class _ImportViewState extends State<ImportView> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _courseTableProvider = CourseTableProvider();
  final _courseProvider = CourseProvider();

  _Stage _stage = _Stage.checkingPriorLogin;
  // 重试时要回到的"起始页"：检测到之前登录过就是快捷导入选择页，
  // 否则是普通登录表单。
  _Stage _initialStage = _Stage.loginForm;
  String _statusText = '';
  String _errorText = '';

  WebViewController? _webViewController;
  NjuEntryConfig? _activeConfig;
  bool _autofillAttempted = false;
  Timer? _loginTimeoutTimer;
  // 快捷导入和普通登录共用同一套 _beginLogin/_onPageFinished 机制，
  // 靠这个标记区分行为：快捷导入模式下落回登录页直接算失败，不会像
  // 普通登录那样尝试自动填表/弹出真实页面手动兜底。
  bool _quickImportMode = false;

  @override
  void initState() {
    super.initState();
    _checkPriorLogin();
  }

  /// "登录成功过"跟"课表导入成功过"是两件独立的事——比如暑期没课，
  /// 抓取那一步会失败、根本不会生成课表，但登录本身是成功的。所以这里
  /// 单独存一个标记，只要曾经真正走到过"选本科/研究生"那一步（意味着
  /// 登录本身通过了），就认为"之前登录过"，不依赖有没有课表。
  static const _prefsHasLoggedInKey = 'nju_has_logged_in_before';

  Future<void> _checkPriorLogin() async {
    bool hasPrior = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      hasPrior = prefs.getBool(_prefsHasLoggedInKey) ?? false;
    } catch (_) {
      hasPrior = false;
    }
    if (!mounted) return;
    setState(() {
      _initialStage = hasPrior ? _Stage.quickImportChoice : _Stage.loginForm;
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

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _loginTimeoutTimer?.cancel();
    super.dispose();
  }

  String _jsStringEscape(String s) {
    return s
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '');
  }

  void _submitLoginForm() {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      Toast.showToast('请输入账号和密码', context);
      return;
    }
    _quickImportMode = false;
    setState(() {
      _stage = _Stage.loggingIn;
      _statusText = '正在登录...';
    });
    _beginLogin(NjuConfig.loginProbe);
  }

  /// 快捷导入和普通登录唯一的区别就是超时时长和"落回登录页算什么"——
  /// 后者的判断在 [_onPageFinished] 里按 [_quickImportMode] 分支，
  /// WebViewController 的创建、导航、超时计时器都是同一套，不重复实现。
  void _beginLogin(NjuEntryConfig config, {int timeoutSeconds = 25}) {
    _activeConfig = config;
    _autofillAttempted = false;
    _loginTimeoutTimer?.cancel();
    _loginTimeoutTimer = Timer(Duration(seconds: timeoutSeconds), () {
      if (!mounted || _stage != _Stage.loggingIn) return;
      setState(() {
        if (_quickImportMode) {
          _stage = _Stage.error;
          _errorText = '快捷导入超时，无法确认登录状态是否有效，请改用"新账号登录"。';
        } else {
          _stage = _Stage.needManualLogin;
          _statusText = '自动登录超时，请在下方手动完成登录';
        }
      });
    });

    if (_webViewController == null) {
      _webViewController = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0x00000000))
        ..setNavigationDelegate(NavigationDelegate(
          onPageFinished: _onPageFinished,
          onWebResourceError: (error) {
            if (!mounted) return;
            _loginTimeoutTimer?.cancel();
            setState(() {
              _stage = _Stage.error;
              _errorText = '网络错误，请检查网络连接（如需要请先连接南京大学 VPN）';
            });
          },
        ))
        ..loadRequest(Uri.parse(config.initialUrl));
    } else {
      _webViewController!.loadRequest(Uri.parse(config.initialUrl));
    }
  }

  Future<void> _onPageFinished(String url) async {
    if (!mounted || _activeConfig == null) return;
    final config = _activeConfig!;

    if (url.startsWith(config.targetUrl)) {
      _loginTimeoutTimer?.cancel();
      if (_stage == _Stage.fetching) {
        // 已经在抓取阶段，避免重复触发。
        return;
      }
      unawaited(_markLoginSucceeded());
      await _fetchAndImport(config);
      return;
    }

    final isLoginPage = url.contains('authserver.nju.edu.cn/authserver/login');
    if (!isLoginPage) return;
    if (_stage != _Stage.loggingIn && _stage != _Stage.needManualLogin) return;

    if (_quickImportMode) {
      // 快捷导入模式：落回登录页就是失败，不自动填表、不弹真实页面
      // 手动兜底——这些都是"需要账号密码"的动作，快捷导入的前提就是
      // 不需要用户再输一遍。
      _loginTimeoutTimer?.cancel();
      setState(() {
        _stage = _Stage.error;
        _errorText = '快捷导入失败：保存的登录状态已失效或不存在，请改用"新账号登录"重新登录一次。';
      });
      return;
    }

    // 还停在登录页：第一次尝试自动填表提交，之后如果又回到登录页，
    // 说明提交失败（账号密码错误，或者过了验证码兜底页又失败一次）。
    if (!_autofillAttempted) {
      _autofillAttempted = true;
      final status = await _attemptAutoFill();
      if (!mounted) return;
      if (status != 'submitted') {
        _loginTimeoutTimer?.cancel();
        setState(() {
          _stage = _Stage.needManualLogin;
          _statusText = '需要验证码或无法自动识别登录框，请在下方手动完成登录';
        });
      }
      // 状态是 submitted 的话，什么都不做，等下一次 onPageFinished。
      return;
    }

    // 已经尝试过自动填表，又回到了登录页 -> 大概率是账号密码错误。
    if (_stage == _Stage.loggingIn) {
      _loginTimeoutTimer?.cancel();
      final errorMessage = await _scrapeLoginError();
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        if (errorMessage.startsWith('[DEBUG_DUMP]')) {
          _errorText = '没能识别到明确的错误提示。\n\n'
              '下面是登录表单的 HTML 结构（长按可复制发给开发者用来调整识别逻辑）：\n\n'
              '${errorMessage.substring('[DEBUG_DUMP]'.length)}';
        } else {
          _errorText = errorMessage.isNotEmpty
              ? '登录失败：$errorMessage'
              : '账号或密码错误，请检查后重试';
        }
      });
    }
  }

  Future<String> _runJs(String js) async {
    final result = await _webViewController!.runJavaScriptReturningResult(js);
    String status = result.toString();
    if (status.startsWith('"') && status.endsWith('"')) {
      status = status.substring(1, status.length - 1);
    }
    return status;
  }

  /// 模拟真实打字：逐字符 dispatch keydown/keypress/input/keyup，而不是
  /// 一次性设置整段 value——南大登录页的密码框会实时按键计算加密/加盐后
  /// 的值写进另一个隐藏字段，只补发一个 input 事件触发不了这个逻辑。
  static String _simulateTypingJs(String targetVar, String text) {
    final escaped = text;
    return '''
      (function(){
        var s = "$escaped";
        for (var k = 0; k < s.length; k++) {
          var ch = s[k];
          $targetVar.value = s.substring(0, k+1);
          var opts = {bubbles: true, key: ch, char: ch, charCode: ch.charCodeAt(0), keyCode: ch.charCodeAt(0), which: ch.charCodeAt(0)};
          $targetVar.dispatchEvent(new KeyboardEvent('keydown', opts));
          $targetVar.dispatchEvent(new KeyboardEvent('keypress', opts));
          $targetVar.dispatchEvent(new Event('input', {bubbles:true}));
          $targetVar.dispatchEvent(new KeyboardEvent('keyup', opts));
        }
      })();
    ''';
  }

  /// 第一阶段：只填用户名，然后触发失焦（南大页面用户名框绑了
  /// onfocusout="checkUserCaptcha()"，会按需显示验证码框，可能是异步的，
  /// 所以填完之后不立刻判断，交给 Dart 侧等一下再查）。
  Future<String> _fillUsernameAndBlur() async {
    final username = _jsStringEscape(_usernameController.text.trim());
    final js = '''
      (function(){
        try {
          var pwd = document.querySelector('input[type="password"]');
          if(!pwd) return 'no_password_field';
          var form = pwd.form || pwd.closest('form');
          if(!form) return 'no_password_field';
          var user = form.querySelector('input[type="text"], input[type="tel"], input:not([type]):not([type="hidden"]):not([type="submit"]):not([type="button"]):not([type="password"])');
          if(!user) return 'no_username_field';
          window.__njuUser = user;
          window.__njuPwd = pwd;
          window.__njuForm = form;
          user.focus();
          user.value = "$username";
          user.dispatchEvent(new Event('input', {bubbles:true}));
          user.dispatchEvent(new Event('change', {bubbles:true}));
          user.dispatchEvent(new Event('blur', {bubbles:true}));
          user.dispatchEvent(new Event('focusout', {bubbles:true}));
          return 'filled';
        } catch(e) {
          return 'js_error';
        }
      })();
    ''';
    return _runJs(js);
  }

  /// 第二阶段：查一下验证码框有没有被 checkUserCaptcha() 显示出来；
  /// 没有的话再逐字符"打"密码并提交。
  Future<String> _checkCaptchaAndFillPassword() async {
    final password = _jsStringEscape(_passwordController.text);
    final typingJs = _simulateTypingJs('window.__njuPwd', password);
    final js = '''
      (function(){
        try {
          var pwd = window.__njuPwd;
          var form = window.__njuForm;
          if (!pwd || !form) return 'no_password_field';

          // 除了账号/密码之外，表单里只要还有其他可见的、需要填的输入框
          // （图片验证码、动态码，或任何我们没预料到的字段），一律交给
          // 用户在真实网页里手动完成，不冒险瞎填。
          var allInputs = form.querySelectorAll('input');
          for (var i=0;i<allInputs.length;i++){
            var el = allInputs[i];
            if (el === window.__njuUser || el === pwd) continue;
            var t = (el.type||'text').toLowerCase();
            if (t === 'hidden' || t === 'submit' || t === 'button' || t === 'checkbox' || t === 'radio') continue;
            var r = el.getBoundingClientRect();
            if (r.width > 0 && r.height > 0) return 'captcha_required';
          }

          pwd.removeAttribute('readonly');
          pwd.focus();
          $typingJs
          pwd.dispatchEvent(new Event('change', {bubbles:true}));
          pwd.dispatchEvent(new Event('blur', {bubbles:true}));
          pwd.dispatchEvent(new Event('focusout', {bubbles:true}));

          // 注意：form.submit() 会跳过页面自己绑定的 submit 事件监听器
          // （这很可能是密码加密/加盐逻辑真正执行的地方），必须找到真实
          // 可点击的登录控件去点它，不能退回到 form.submit()。南大页面
          // 验证码刷新用的是 <a onclick=...>，登录按钮大概率也不是标准
          // <button>，所以选择器要放宽。
          var submitEl = form.querySelector(
            'button[type="submit"], input[type="submit"], button, ' +
            '[class*="submit" i], [class*="login-btn" i], [class*="btn-login" i], ' +
            '.ge-btn a, .ge-btn [onclick], .ge-btn button, [onclick*="login" i], [onclick*="submit" i]'
          );
          if (!submitEl) return 'no_submit_button';
          submitEl.click();
          return 'submitted';
        } catch(e) {
          return 'js_error';
        }
      })();
    ''';
    return _runJs(js);
  }

  Future<String> _attemptAutoFill() async {
    try {
      final fillStatus = await _fillUsernameAndBlur();
      if (fillStatus != 'filled') return fillStatus;
      await Future.delayed(const Duration(milliseconds: 900));
      return await _checkCaptchaAndFillPassword();
    } catch (e) {
      return 'js_error';
    }
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
      final courseTableMap = await ImportFromBEView.fetchCourseTableMap(
          _webViewController!, config.toConfigMap());

      Iterable courses;
      final rawCourses = courseTableMap['courses'];
      if (rawCourses.runtimeType != String) {
        courses = rawCourses;
      } else if (json.decode(rawCourses).runtimeType != String) {
        courses = json.decode(rawCourses);
      } else {
        courses = json.decode(json.decode(rawCourses));
      }
      final coursesMap = List<Map<String, dynamic>>.from(courses);

      final courseTable = await _courseTableProvider
          .insert(CourseTable(courseTableMap['name']));
      final tableId = courseTable.id!;

      if (mounted) {
        await ScopedModel.of<MainStateModel>(context).changeclassTable(tableId);
      }

      for (final courseMap in coursesMap) {
        final dbMap =
            CourseImportCodec.onlineCourseToDbMap(courseMap, tableId: tableId);
        final course = Course.fromMap(dbMap);
        await _courseProvider.insert(course);
      }

      await _courseTableProvider.updateCheckUpdateInfo(
        tableId,
        sourceSchoolPinyin: config.pinyin,
        lastSnapshot: json.encode(coursesMap),
        lastCheckedAt: DateTime.now().toIso8601String(),
      );

      if (!mounted) return;
      Toast.showToast('导入成功', context);
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _errorText = '课表抓取失败：$e';
      });
    }
  }

  /// 统一的"重置状态回到某个起始页"，默认回到 [_initialStage]（快捷导入
  /// 选择页或登录表单），也可以指定具体页面（比如"新账号登录"按钮要强制
  /// 回登录表单，不是回快捷导入选择页）。
  void _retry({_Stage? stage}) {
    setState(() {
      _stage = stage ?? _initialStage;
      _statusText = '';
      _errorText = '';
      _webViewController = null;
      _activeConfig = null;
      _autofillAttempted = false;
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
      case _Stage.quickImportChoice:
        return _buildQuickImportChoice(context);
      case _Stage.loginForm:
        return _buildLoginForm(context);
      case _Stage.loggingIn:
      case _Stage.fetching:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(_statusText),
            ],
          ),
        );
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
      case _Stage.error:
        return _buildError(context);
    }
  }

  Widget _buildQuickImportChoice(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('检测到之前登录过南大账号', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            const Text(
              '"快捷导入"会尝试直接复用上次的登录状态，不需要重新输入账号密码；\n'
              '如果登录状态已经失效，会提示失败原因，再用"新账号登录"重新登录即可。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _tryQuickImport,
              icon: const Icon(Icons.flash_on),
              label: const Text('快捷导入'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                _quickImportMode = false;
                _retry(stage: _Stage.loginForm);
              },
              icon: const Icon(Icons.person_outline),
              label: const Text('新账号登录'),
            ),
          ],
        ),
      ),
    );
  }

  /// 不填账号密码，直接拿之前登录时留下的 WebView 会话去访问登录地址——
  /// 如果 Cookie 还有效，统一认证会跳过登录表单直接放行；如果已经失效，
  /// 会被弹回登录页，[_onPageFinished] 在 [_quickImportMode] 下会明确
  /// 报错，不自动退化成完整登录流程。跟普通登录共用同一套底层机制。
  void _tryQuickImport() {
    _quickImportMode = true;
    setState(() {
      _stage = _Stage.loggingIn;
      _statusText = '正在尝试复用登录状态...';
    });
    _beginLogin(NjuConfig.loginProbe, timeoutSeconds: 15);
  }

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
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: ElevatedButton(onPressed: _retry, child: const Text('重试')),
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
}
