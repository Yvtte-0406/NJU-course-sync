import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:scoped_model/scoped_model.dart';
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
  loginForm,
  loggingIn,
  needManualLogin,
  choosingProgram,
  fetching,
  error,
}

class _ImportViewState extends State<ImportView> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _courseTableProvider = CourseTableProvider();
  final _courseProvider = CourseProvider();

  _Stage _stage = _Stage.loginForm;
  String _statusText = '';
  String _errorText = '';

  WebViewController? _webViewController;
  NjuEntryConfig? _activeConfig;
  bool _autofillAttempted = false;
  Timer? _loginTimeoutTimer;

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
    setState(() {
      _stage = _Stage.loggingIn;
      _statusText = '正在登录...';
    });
    _beginLogin(NjuConfig.loginProbe);
  }

  void _beginLogin(NjuEntryConfig config) {
    _activeConfig = config;
    _autofillAttempted = false;
    _loginTimeoutTimer?.cancel();
    _loginTimeoutTimer = Timer(const Duration(seconds: 25), () {
      if (mounted && (_stage == _Stage.loggingIn)) {
        setState(() {
          _stage = _Stage.needManualLogin;
          _statusText = '自动登录超时，请在下方手动完成登录';
        });
      }
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
      if (_stage == _Stage.choosingProgram || _stage == _Stage.fetching) {
        // 已经在选择/抓取阶段，避免重复触发。
        return;
      }
      setState(() {
        _stage = _Stage.choosingProgram;
        _statusText = '登录成功';
      });
      return;
    }

    // 还停在登录页：第一次尝试自动填表提交，之后如果又回到登录页，
    // 说明提交失败（账号密码错误，或者过了验证码兜底页又失败一次）。
    final isLoginPage = url.contains('authserver.nju.edu.cn/authserver/login');
    if (!isLoginPage) return;
    if (_stage != _Stage.loggingIn && _stage != _Stage.needManualLogin) return;

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

  void _choosePrograms(bool isGraduate) {
    if (!isGraduate) {
      // 探测阶段用的就是本科配置，已经在目标页上了，直接抓取。
      _fetchAndImport(NjuConfig.undergraduate);
    } else {
      setState(() {
        _stage = _Stage.loggingIn;
        _statusText = '正在切换到研究生教务系统...';
      });
      _beginLogin(NjuConfig.graduate);
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

  void _retry() {
    setState(() {
      _stage = _Stage.loginForm;
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
            child: Text(_statusText, textAlign: TextAlign.center),
          ),
          Expanded(child: WebViewWidget(controller: _webViewController!)),
        ]);
      case _Stage.choosingProgram:
        return _buildProgramChoice(context);
      case _Stage.error:
        return _buildError(context);
    }
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

  Widget _buildProgramChoice(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('登录成功，请选择身份', style: TextStyle(fontSize: 16)),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () => _choosePrograms(false),
            child: const Text('本科生'),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => _choosePrograms(true),
            child: const Text('研究生'),
          ),
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
