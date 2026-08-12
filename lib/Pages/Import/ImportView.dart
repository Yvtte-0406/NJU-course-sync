import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:scoped_model/scoped_model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../Components/Toast.dart';
import '../../Models/CourseModel.dart';
import '../../Models/CourseTableModel.dart';
import '../../Resources/NjuConfig.dart';
import '../../Utils/ColorUtil.dart';
import '../../Utils/CourseDiff.dart';
import '../../Utils/CourseImportCodec.dart';
import '../../Utils/MissingCourseSweeper.dart';
import '../../Utils/NjuAutoLoginScript.dart';
import '../../Utils/NjuCredentialStore.dart';
import '../../Utils/NjuEhallJsonImporter.dart';
import '../../Utils/SemesterCode.dart';
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
  final _courseTableProvider = CourseTableProvider();
  final _courseProvider = CourseProvider();

  _Stage _stage = _Stage.checkingPriorLogin;
  // 重试时要回到的"起始页"：之前登录过、账号密码也还在，就是三选一的
  // 入口页，否则是登录表单。
  _Stage _initialStage = _Stage.loginForm;
  String _statusText = '';
  String _errorText = '';

  WebViewController? _webViewController;
  NjuEntryConfig? _activeConfig;
  bool _autofillAttempted = false;
  Timer? _loginTimeoutTimer;

  // 本次登录成功后要做什么：新建一张表，还是更新当前显示的那张表。
  // 由入口页按钮点了哪个决定，登录本身没有任何区别。
  bool _updatingCurrentTable = false;
  int? _updateTableId;
  CourseDiffResult? _updateDiff;
  MissingSweepResult? _updateSweep;

  /// 抓到 0 门课时把原始结果留下来，展示给用户判断到底是哪一步的问题。
  Map<String, dynamic>? _emptyResultMap;

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
    _loginTimeoutTimer?.cancel();
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
    _beginLogin(NjuConfig.loginProbe);
  }

  /// 打开后台 WebView 加载登录页，等 [_onPageFinished] 接手注入自动登录
  /// 脚本。自动更新和手输账密走的是同一个方法——两者的区别只在账号密码
  /// 从哪来（存的 / 刚输的），登录本身没有任何差别。
  void _beginLogin(NjuEntryConfig config, {int timeoutSeconds = 25}) {
    _activeConfig = config;
    _autofillAttempted = false;
    _loginTimeoutTimer?.cancel();
    _loginTimeoutTimer = Timer(Duration(seconds: timeoutSeconds), () {
      if (!mounted || _stage != _Stage.loggingIn) return;
      // 走 _fallBackToManualLogin 而不是直接改 stage：超时的时候自动登录
      // 脚本多半还在跑，必须先把它停掉再把表单交给用户。
      _fallBackToManualLogin('自动登录超时，请在下方手动完成登录');
    });

    final url = Uri.parse(config.initialUrl);
    if (_webViewController == null) {
      _webViewController = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0x00000000))
        ..addJavaScriptChannel(
          NjuAutoLoginScript.channelName,
          onMessageReceived: _onAutoLoginMessage,
        )
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
        ..loadRequest(url);
    } else {
      _webViewController!.loadRequest(url);
    }
  }

  Future<void> _onPageFinished(String url) async {
    if (!mounted || _activeConfig == null) return;
    final config = _activeConfig!;

    if (url.startsWith(config.targetUrl)) {
      _loginTimeoutTimer?.cancel();
      if (_stage == _Stage.fetching || _stage == _Stage.emptyResult) {
        // 已经在抓取或结果展示阶段，避免重复触发。
        return;
      }
      unawaited(_markLoginSucceeded());
      // 登录真的成功了，把这次用的账号密码记住：下次进来就能直接
      // "自动更新"，不用再输一遍。自动更新路径下存的就是同一份，
      // 重存一次没有副作用。
      unawaited(NjuCredentialStore.save(
        _usernameController.text.trim(),
        _passwordController.text,
      ));
      if (_updatingCurrentTable) {
        await _fetchAndUpdateCurrent(config);
      } else {
        await _fetchAndImport(config);
      }
      return;
    }

    final isLoginPage = url.contains('authserver.nju.edu.cn/authserver/login');
    if (!isLoginPage) return;
    if (_stage != _Stage.loggingIn && _stage != _Stage.needManualLogin) return;

    // 还停在登录页：第一次注入自动登录脚本，之后如果又回到登录页，
    // 说明提交失败（账号密码错误，或者过了验证码兜底页又失败一次）。
    if (!_autofillAttempted) {
      _autofillAttempted = true;
      await _startAutoLoginScript();
      // 脚本是异步跑的（填表、过滑块、提交都要时间），结果通过
      // JavaScriptChannel 回到 [_onAutoLoginMessage]，成功则由下一次
      // onPageFinished 命中 targetUrl 接手，这里不再等它的返回值。
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

  /// 把 `assets/scripts/auto_auth_login.js` 注入登录页跑起来。填表、按需
  /// 刷新验证码、过滑块、提交、判断结果全在那个脚本里，这边只负责启动它
  /// 和接收它回传的消息（[_onAutoLoginMessage]）。
  Future<void> _startAutoLoginScript() async {
    try {
      await NjuAutoLoginScript.inject(
        _webViewController!,
        username: _usernameController.text.trim(),
        password: _passwordController.text,
      );
    } catch (e) {
      _fallBackToManualLogin('自动登录脚本启动失败（$e），请在下方手动完成登录');
    }
  }

  /// 自动登录脚本通过 JavaScriptChannel 回传的消息。
  void _onAutoLoginMessage(JavaScriptMessage message) {
    if (!mounted) return;
    final event = NjuAutoLoginScript.decode(message.message);
    switch (event.type) {
      case 'log':
        debugPrint('[NjuAutoLogin][${event.level}] ${event.message}');
        return;
      case 'solveCaptcha':
        // 图形验证码识别在扩展里是丢给 background 跑 ONNX 模型的，App 里
        // 没有推理运行时，识别不了。halt 掉脚本（不然它会一直刷验证码跟
        // 用户抢输入框），把真实页面交还给用户手动填。
        _fallBackToManualLogin('出现了图形验证码，请在下方手动完成登录');
        return;
      case 'loginComplete':
        if (event.success) {
          // 成功不在这里收口：还要等 WebView 真的跳到目标页，
          // 由 [_onPageFinished] 命中 targetUrl 之后接手抓取。
          return;
        }
        _handleAutoLoginFailure(event.message);
        return;
    }
  }

  /// 脚本抛上来的失败原因分两类：账号密码错这种再试也没用，直接报错；
  /// 滑块/表单没搞定这种是「机器没过、人能过」，退回手动登录。
  void _handleAutoLoginFailure(String reason) {
    if (_stage != _Stage.loggingIn) return;
    if (reason.contains('NJU_INVALID_CREDENTIALS')) {
      _loginTimeoutTimer?.cancel();
      unawaited(NjuAutoLoginScript.halt(_webViewController!));
      setState(() {
        _stage = _Stage.error;
        _errorText = '账号或密码错误，请检查后重试';
      });
      return;
    }
    if (reason.contains('NJU_SLIDER_FAILED_TWICE')) {
      _fallBackToManualLogin('滑块验证连续失败，请在下方手动完成登录');
      return;
    }
    if (reason.contains('NJU_SLIDER_NO_POINTER_SUPPORT')) {
      // 触摸和鼠标两种合成事件页面都没接住——多半是滑块组件换了实现
      // （比如改用 Pointer Events）。这种是代码要跟着改的，不是用户能
      // 解决的，日志里留一句好定位。
      debugPrint('[NjuAutoLogin] 滑块对合成的 touch/mouse 事件都无反应');
      _fallBackToManualLogin('无法自动完成滑块验证，请在下方手动滑动');
      return;
    }
    _fallBackToManualLogin(
        reason.isEmpty ? '自动登录失败，请在下方手动完成登录' : '自动登录失败：$reason\n请在下方手动完成登录');
  }

  /// 把页面交还给用户手动登录。必须先 halt 脚本：它还在跑的话会继续改
  /// 输入框、刷验证码、点登录按钮，跟用户抢同一个表单。
  void _fallBackToManualLogin(String statusText) {
    if (_stage != _Stage.loggingIn) return;
    _loginTimeoutTimer?.cancel();
    final controller = _webViewController;
    if (controller != null) unawaited(NjuAutoLoginScript.halt(controller));
    setState(() {
      _stage = _Stage.needManualLogin;
      _statusText = statusText;
    });
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
      final courseTableMap = await NjuEhallJsonImporter.fetchCourseTableMap(
        _webViewController!,
        pinyin: config.pinyin,
      );

      // 抓到 0 门课时，光看结果分不清"登录/抓取失败"和"这学期确实没排课"
      // ——两种情况都是一张空课表。所以这里不直接建表，先把抓到的东西摊开
      // 给用户看：能报出学期名称和代码，就说明登录和抓取都成功了。
      if (_courseCountOf(courseTableMap) == 0) {
        if (!mounted) return;
        setState(() {
          _emptyResultMap = courseTableMap;
          _stage = _Stage.emptyResult;
        });
        return;
      }

      await _saveCourseTableMap(config, courseTableMap);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _errorText = '课表抓取失败：$e';
      });
    }
  }

  /// 抓取结果里有多少门课。解析不出来返回 -1（区别于"确实是 0 门"）。
  int _courseCountOf(Map<String, dynamic> courseTableMap) {
    try {
      return _decodeCourses(courseTableMap).length;
    } catch (_) {
      return -1;
    }
  }

  /// `courses` 这个字段在不同来源下可能是列表、JSON 字符串、甚至被编码了
  /// 两次的字符串，统一在这里剥开。
  List<Map<String, dynamic>> _decodeCourses(
      Map<String, dynamic> courseTableMap) {
    Iterable courses;
    final rawCourses = courseTableMap['courses'];
    if (rawCourses.runtimeType != String) {
      courses = rawCourses;
    } else if (json.decode(rawCourses).runtimeType != String) {
      courses = json.decode(rawCourses);
    } else {
      courses = json.decode(json.decode(rawCourses));
    }
    return List<Map<String, dynamic>>.from(courses);
  }

  /// 把抓到的课表数据落库。
  Future<void> _saveCourseTableMap(
      NjuEntryConfig config, Map<String, dynamic> courseTableMap) async {
    final coursesMap = _decodeCourses(courseTableMap);

    final courseTable =
        await _courseTableProvider.insert(CourseTable(courseTableMap['name']));
    final tableId = courseTable.id!;

    if (mounted) {
      await ScopedModel.of<MainStateModel>(context).changeclassTable(tableId);
    }

    final inserted = <Course>[];
    for (final courseMap in coursesMap) {
      final dbMap =
          CourseImportCodec.onlineCourseToDbMap(courseMap, tableId: tableId);
      final course = Course.fromMap(dbMap);
      inserted.add(await _courseProvider.insert(course));
    }
    await _recordCourseColors(tableId, inserted);

    await _courseTableProvider.updateCheckUpdateInfo(
      tableId,
      sourceSchoolPinyin: config.pinyin,
      semesterCode: (courseTableMap['semesterCode'] ?? '').toString(),
      lastSnapshot: json.encode(coursesMap),
      lastCheckedAt: DateTime.now().toIso8601String(),
    );

    await _maybeRequestBatteryOptimizationExemption();

    if (!mounted) return;
    Toast.showToast('导入成功', context);
    Navigator.of(context).pop(true);
  }

  /// "更新当前课程表"：抓到最新数据后不新建表，跟 [MainStateModel] 当前
  /// 显示的那张表做 diff，进 [_Stage.reviewingUpdate] 让用户看变更预览再
  /// 决定要不要应用——跟"课表管理"里的"检查更新"是同一套比对逻辑
  /// （[diffCourseLists]），只是这里带了完整的自动登录链路，不依赖
  /// 已有登录会话还没过期。
  Future<void> _fetchAndUpdateCurrent(NjuEntryConfig config) async {
    setState(() {
      _activeConfig = config;
      _stage = _Stage.fetching;
      _statusText = '正在获取最新课表并比对...';
    });

    try {
      final courseTableMap = await NjuEhallJsonImporter.fetchCourseTableMap(
        _webViewController!,
        pinyin: config.pinyin,
      );

      Iterable courses;
      final rawCourses = courseTableMap['courses'];
      if (rawCourses.runtimeType != String) {
        courses = rawCourses;
      } else if (json.decode(rawCourses).runtimeType != String) {
        courses = json.decode(rawCourses);
      } else {
        courses = json.decode(json.decode(rawCourses));
      }
      final newCoursesMap = List<Map<String, dynamic>>.from(courses);

      // 一门课都没抓到 = 这次抓取失败，不是"全学期停课了"。这种情况下每门
      // 课都会被判成消失，两轮下来会全部删光，宽限期防不住，只能整轮拦掉。
      if (newCoursesMap.isEmpty) {
        if (!mounted) return;
        setState(() {
          _stage = _Stage.error;
          _errorText = '这次没有抓到任何课程，判定为抓取失败，已跳过本轮更新，'
              '你的课表没有任何改动。\n请稍后重试。';
        });
        return;
      }

      final tableId =
          await ScopedModel.of<MainStateModel>(context).getClassTable();
      final currentTable = await _courseTableProvider.getCourseTable(tableId);
      if (currentTable == null) {
        if (!mounted) return;
        setState(() {
          _stage = _Stage.error;
          _errorText = '当前没有正在显示的课表，请先用"导入课程表"建一张。';
        });
        return;
      }

      final fetchedSemester = (courseTableMap['semesterCode'] ?? '').toString();
      final verdict = compareSemesterCode(
        await _courseTableProvider.getSemesterCode(tableId),
        fetchedSemester,
      );
      if (verdict == SemesterVerdict.changed) {
        // 换学期了就不是"更新"而是"换一张表"：逐条比对上学期和这学期的课
        // 没有意义（几乎全是新增 + 消失）。新建一张表切过去，旧表留作历史，
        // 手动添加的课自然不会带过来。
        await _saveCourseTableMap(config, courseTableMap);
        return;
      }

      final newCourses = newCoursesMap
          .map((m) => Course.fromMap(
              CourseImportCodec.onlineCourseToDbMap(m, tableId: tableId)))
          .toList();

      final oldCoursesRaw = await _courseProvider.getAllCourses(tableId);
      final oldCourses = oldCoursesRaw
          .map((m) => Course.fromMap(Map<String, dynamic>.from(m)))
          .toList();

      final diff = diffCourseLists(oldCourses, newCourses);

      // 消失的课不等用户确认，当场按两轮宽限期处理：第一轮从课表上隐藏但
      // 留着数据，连续两轮没抓到才真删。结果会在下面的预览页告诉用户。
      final sweep = await sweepMissingCourses(
        provider: _courseProvider,
        oldCourses: oldCourses,
        diff: diff,
      );

      await _courseTableProvider.updateCheckUpdateInfo(
        tableId,
        sourceSchoolPinyin: config.pinyin,
        semesterCode: fetchedSemester,
        lastSnapshot: json.encode(newCoursesMap),
        lastCheckedAt: DateTime.now().toIso8601String(),
      );

      if (!mounted) return;
      setState(() {
        _updateTableId = tableId;
        _updateDiff = diff;
        _updateSweep = sweep;
        _stage = _Stage.reviewingUpdate;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _errorText = '课表更新失败：$e';
      });
    }
  }

  Future<void> _applyUpdateChanges() async {
    final diff = _updateDiff!;
    final tableId = _updateTableId!;

    for (final change in diff.changedSlots) {
      final updated = change.oldSlot;
      updated.classroom = change.newSlot.classroom;
      updated.info = change.newSlot.info;
      updated.weekTime = change.newSlot.weekTime;
      updated.startTime = change.newSlot.startTime;
      updated.timeCount = change.newSlot.timeCount;
      updated.weeks = change.newSlot.weeks;
      await _courseProvider.update(updated);
    }

    final inserted = <Course>[];
    for (final slot in diff.addedSlots) {
      slot.tableId = tableId;
      inserted.add(await _courseProvider.insert(slot));
    }
    for (final group in diff.addedCourses.values) {
      for (final slot in group) {
        slot.tableId = tableId;
        inserted.add(await _courseProvider.insert(slot));
      }
    }
    await _recordCourseColors(tableId, inserted);

    if (!mounted) return;
    Toast.showToast('已更新当前课程表', context);
    Navigator.of(context).pop(true);
  }

  /// 把新写进来的课程按色板算出的颜色固定到课表级映射里。已经记过的课程
  /// 不会被覆盖，所以同一门课在后续更新中被删掉又加回来时颜色不变。
  Future<void> _recordCourseColors(int tableId, List<Course> courses) async {
    if (courses.isEmpty) return;
    final pool = await ColorPool.getActivePool();
    await _courseTableProvider.mergeCourseColors(
        tableId, paletteColorEntries(courses, pool));
  }

  /// 统一的"重置状态回到某个起始页"，默认回到 [_initialStage]（三选一
  /// 入口页或登录表单），也可以指定具体页面（比如"新账号登录"按钮要强制
  /// 回登录表单，不是回入口页）。
  void _retry({_Stage? stage}) {
    setState(() {
      _stage = stage ?? _initialStage;
      _statusText = '';
      _errorText = '';
      _webViewController = null;
      _activeConfig = null;
      _autofillAttempted = false;
      _updatingCurrentTable = false;
      _updateTableId = null;
      _updateDiff = null;
      _updateSweep = null;
      _emptyResultMap = null;
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
    final map = _emptyResultMap ?? const <String, dynamic>{};
    final semesterName = (map['name'] ?? '').toString();
    final semesterCode = (map['semesterCode'] ?? '').toString();
    final gotSemester = semesterName.isNotEmpty || semesterCode.isNotEmpty;

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
              _previewJson(map),
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
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: () async {
                  final config = _activeConfig;
                  final map = _emptyResultMap;
                  if (config == null || map == null) return;
                  setState(() => _stage = _Stage.fetching);
                  await _saveCourseTableMap(config, map);
                },
                child: const Text('仍然创建空课表'),
              ),
            ),
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
  /// WebView 是铺在底下、被不透明遮罩盖住的，不是多余的：自动登录脚本回放
  /// 滑块轨迹用的是 `requestAnimationFrame`，而 rAF 只有在 WebView 真的挂进
  /// 视图树、参与合成的时候才会触发。要是这里只挂一个转圈指示器、把 WebView
  /// 留在树外，轨迹回放会一直卡住，直到 [_beginLogin] 的超时把流程推走。
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
  /// （[_beginLogin] -> 注入脚本填表过滑块 -> 命中目标页抓取），区别
  /// 只是用户不用再输一遍。[updateCurrent] 决定登录成功后是新建一张表
  /// 还是更新当前显示的那张（[_onPageFinished] 里据此分流）。
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
    _beginLogin(NjuConfig.loginProbe);
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
    final diff = _updateDiff!;
    final sweepSummary = _updateSweep?.summary;
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
