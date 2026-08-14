import 'dart:async';
import 'dart:ui' show Color;

import 'package:webview_flutter/webview_flutter.dart';

import '../Resources/NjuConfig.dart';
import '../Utils/NjuAutoLoginScript.dart';

/// 统一身份认证的自动登录：账号密码进去，一个**已登录的**
/// [WebViewController] 出来。
///
/// **这个文件不允许 import material.dart。** 跟 [CourseSyncService] 同一条
/// 规矩——它要能在没有界面的后台 isolate 里跑。原先这套逻辑长在
/// `ImportView` 里，由 `setState` 驱动、以「把 WebView 交还给用户」收尾，
/// 那个收尾动作在后台根本没有意义。抽出来之后，登录结果变成
/// [NjuLoginResult] 这个返回值，怎么处置由调用方决定：
///
/// - 前台：需要人工介入的失败 -> 把 WebView 显示出来让用户自己完成
/// - 后台：需要人工介入的失败 -> 放弃本轮；账号密码错 -> 停用后台检查并通知
///
/// 之所以能在后台跑，前提是两个实验的结论：`requestAnimationFrame`
/// （滑块轨迹回放依赖它）在不挂进视图树的 WebView 里照样触发，且
/// WorkManager 唤醒的 isolate 里可以创建 WebView。**不是**因为界面无关紧要。
class NjuLoginService {
  NjuLoginService({this.onLog});

  /// 进度日志。前台可以拿它更新状态文案，后台可以攒起来写进诊断记录。
  final void Function(String message, String level)? onLog;

  /// 登录页 URL 的判定依据。CAS 在提交前后会在这个地址上来回跳，
  /// 所以「当前还在这个地址」等价于「还没登录进去」。
  static const String _loginPageMarker =
      'authserver.nju.edu.cn/authserver/login';

  WebViewController? _controller;
  Completer<NjuLoginResult>? _completer;
  Timer? _timeoutTimer;
  NjuEntryConfig? _config;
  bool _scriptInjected = false;

  /// 是否已经把页面交给真人了（[awaitManualCompletion]）。
  ///
  /// 这个模式下「又回到登录页」不再意味着账号密码错——用户可能刚滑错一次
  /// 拼图、页面重载了，正准备再滑一次。只认「走到目标页」这一个成功信号。
  bool _manualMode = false;

  /// 这次登录用的 WebView。成功时它就是已认证的会话，直接交给
  /// [CourseSyncService.fetch]；失败且需要人工介入时，前台要把它挂进
  /// [WebViewWidget] 让用户接手，所以失败了也不销毁。
  WebViewController? get controller => _controller;

  /// 跑一次完整的自动登录。
  ///
  /// 全程只 settle 一次：要么脚本报成功且页面确实到了 [NjuEntryConfig.targetUrl]，
  /// 要么落到某一类失败，要么 [timeout] 到了。重复调用同一个实例的行为未定义
  /// ——一个实例服务一次登录，前台重试时新建一个。
  Future<NjuLoginResult> login({
    required String username,
    required String password,
    NjuEntryConfig? config,
    Duration timeout = const Duration(seconds: 25),
  }) {
    final entry = config ?? NjuConfig.loginProbe;
    _config = entry;
    _scriptInjected = false;
    final completer = Completer<NjuLoginResult>();
    _completer = completer;

    _timeoutTimer = Timer(timeout, () {
      // 超时的时候脚本多半还在跑，必须先停掉它再收口：不停的话它会继续改
      // 输入框、刷验证码、点登录按钮，前台交还给用户后会跟用户抢同一个表单。
      _finish(NjuLoginFailure.timeout, '自动登录超时');
    });

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel(
        NjuAutoLoginScript.channelName,
        onMessageReceived: (message) =>
            _onScriptMessage(message.message, username, password),
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) => _onPageFinished(url, username, password),
        onWebResourceError: (error) {
          _finish(NjuLoginFailure.network, error.description);
        },
      ))
      ..loadRequest(Uri.parse(entry.initialUrl));

    return completer.future;
  }

  /// 自动登录没过、把页面交给真人之后，继续盯着同一个 WebView，等它走到
  /// 目标页。用户自己滑完拼图或填完验证码、登录成功，这个 Future 就 settle，
  /// 调用方接着走抓取——跟自动登录成功后的路径完全一样。
  ///
  /// 只有前台用得上。后台没有「真人」，遇到需要人工的失败就该放弃本轮。
  ///
  /// [timeout] 给得比自动登录宽得多：人滑拼图、找手机验证码都慢，25 秒根本
  /// 不够，超时了用户还在操作反而更糟。
  Future<NjuLoginResult> awaitManualCompletion({
    Duration timeout = const Duration(minutes: 5),
  }) {
    _timeoutTimer?.cancel();
    _manualMode = true;
    final completer = Completer<NjuLoginResult>();
    _completer = completer;
    _timeoutTimer = Timer(timeout, () {
      _finish(NjuLoginFailure.timeout, '等待手动登录超时');
    });
    return completer.future;
  }

  /// 把这次登录彻底停掉并释放脚本。前台在用户手动接手之前、或者放弃这次
  /// 登录时调用；后台每轮结束都该调，免得脚本在 isolate 存活期间继续跑。
  Future<void> dispose() async {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    final controller = _controller;
    if (controller != null) await NjuAutoLoginScript.halt(controller);
  }

  // ------------------------------------------------------------ 事件处理

  Future<void> _onPageFinished(
      String url, String username, String password) async {
    final entry = _config;
    if (entry == null || _isSettled) return;

    if (url.startsWith(entry.targetUrl)) {
      // 到了目标页就是真的登进去了。脚本此时可能还在跑收尾逻辑，一并停掉。
      _finishSuccess();
      return;
    }

    if (!url.contains(_loginPageMarker)) return;

    // 已经交给真人了：登录页反复重载是正常的（滑错一次拼图就会重来一遍），
    // 不能当成失败，也绝不能再注入脚本跟用户抢表单。只等目标页。
    if (_manualMode) return;

    // 还停在登录页。第一次到这儿就注入脚本；之后**再次**回到登录页说明提交
    // 失败了——CAS 校验不过会把你打回同一个地址，账号密码错误是最常见的原因。
    if (!_scriptInjected) {
      _scriptInjected = true;
      _log('登录页已加载，注入自动登录脚本', 'info');
      try {
        await NjuAutoLoginScript.inject(
          _controller!,
          username: username,
          password: password,
        );
      } catch (e) {
        _finish(NjuLoginFailure.scriptFailed, '$e');
      }
      // 脚本是异步跑的（填表、过滑块、提交都要时间），结果走
      // JavaScriptChannel 回到 [_onScriptMessage]；成功由下一次
      // onPageFinished 命中 targetUrl 收口，这里不等它的返回值。
      return;
    }

    _finish(NjuLoginFailure.invalidCredentials, '提交后又回到了登录页');
  }

  void _onScriptMessage(String raw, String username, String password) {
    if (_isSettled) return;
    final event = NjuAutoLoginScript.decode(raw);
    if (event.type == 'log') {
      _log(event.message, event.level);
      return;
    }
    // 交给真人之后脚本已经 halt 了，但 halt 之前发出的消息可能还在路上。
    // 让它们把「等用户手动登录」这个 Future 判成失败就荒唐了。
    if (_manualMode) return;
    switch (event.type) {
      case 'solveCaptcha':
        // 图形验证码在原扩展里是丢给 background 跑 ONNX 模型认的，App 里没有
        // 推理运行时，认不了。必须当场收口：脚本会一直等这个响应，不收口它就
        // 卡在那儿，前台的用户也会看到一个自己不断刷新的验证码。
        _finish(NjuLoginFailure.imageCaptcha, '出现图形验证码，需要人工识别');
        return;
      case 'loginComplete':
        if (event.success) {
          // 成功不在这里收口：脚本说「提交成功」不等于会话已经建立，还要等
          // WebView 真的跳到目标页，由 [_onPageFinished] 接手。
          return;
        }
        _finish(classifyFailure(event.message), event.message);
        return;
    }
  }

  /// 把脚本抛上来的失败原因翻译成 [NjuLoginFailure]。
  ///
  /// 分类的意义全在调用方的处置上：账号密码错再试一百次也是同样结果，后台
  /// 必须**立刻停用**并通知用户（继续重试会把统一认证账号锁掉，而那个账号
  /// 同时是邮箱、图书馆、成绩系统的入口）；滑块没过是「机器没过、人能过」，
  /// 换个时间重试是有意义的。
  static NjuLoginFailure classifyFailure(String reason) {
    if (reason.contains('NJU_INVALID_CREDENTIALS')) {
      return NjuLoginFailure.invalidCredentials;
    }
    if (reason.contains('NJU_SLIDER_FAILED_TWICE')) {
      return NjuLoginFailure.sliderFailed;
    }
    if (reason.contains('NJU_SLIDER_NO_POINTER_SUPPORT')) {
      return NjuLoginFailure.sliderNoPointerSupport;
    }
    return NjuLoginFailure.unknown;
  }

  // -------------------------------------------------------------- 收口

  bool get _isSettled => _completer?.isCompleted ?? true;

  void _finishSuccess() {
    if (_isSettled) return;
    _timeoutTimer?.cancel();
    _log('登录成功，已到达目标页', 'success');
    _completer!.complete(NjuLoginResult._success(_controller!));
  }

  void _finish(NjuLoginFailure failure, String detail) {
    if (_isSettled) return;
    _timeoutTimer?.cancel();
    _log('登录失败（${failure.name}）：$detail', 'error');
    // 先停脚本再 complete：调用方拿到结果后可能立刻把 WebView 挂进界面交给
    // 用户，脚本还活着的话会跟用户抢表单。halt 是尽力而为，不等它。
    final controller = _controller;
    if (controller != null) {
      unawaited(NjuAutoLoginScript.halt(controller));
    }
    _completer!.complete(NjuLoginResult._failure(failure, detail, controller));
  }

  void _log(String message, String level) => onLog?.call(message, level);
}

/// 登录失败的原因。分类的依据是**调用方该怎么办**，不是错在哪一层。
enum NjuLoginFailure {
  /// 账号密码不对。重试无意义，后台必须停用并通知用户。
  invalidCredentials,

  /// 出现图形验证码。App 内没有识别能力，只能让人来。
  imageCaptcha,

  /// 滑块连续两次没过。人能过，换个时间重试有意义。
  sliderFailed,

  /// 滑块对合成的 touch 和 mouse 事件都没反应——多半是组件换了实现
  /// （比如改用 Pointer Events）。这是代码要跟着改，用户解决不了。
  sliderNoPointerSupport,

  /// 注入脚本本身就失败了（assets 读不到之类）。
  scriptFailed,

  /// 网络错误，包括没连校园网 / VPN。
  network,

  /// 到点了还没走到目标页，也没有明确的失败信号。
  timeout,

  /// 脚本报了失败但原因不认识。
  unknown,
}

extension NjuLoginFailureX on NjuLoginFailure {
  /// 这类失败是不是「换个时间再来可能就成了」。
  ///
  /// [invalidCredentials] 和 [sliderNoPointerSupport] 不在其列：前者重试会
  /// 撞账号锁定，后者是代码问题，重试一万次也一样。
  bool get isWorthRetrying {
    switch (this) {
      case NjuLoginFailure.sliderFailed:
      case NjuLoginFailure.network:
      case NjuLoginFailure.timeout:
      case NjuLoginFailure.unknown:
        return true;
      case NjuLoginFailure.invalidCredentials:
      case NjuLoginFailure.imageCaptcha:
      case NjuLoginFailure.sliderNoPointerSupport:
      case NjuLoginFailure.scriptFailed:
        return false;
    }
  }

  /// 需不需要真人坐在屏幕前才能过。后台遇到这类只能放弃本轮，但**不该**
  /// 计入账号锁定的失败计数——它跟凭据对不对没关系。
  bool get needsHuman {
    switch (this) {
      case NjuLoginFailure.imageCaptcha:
      case NjuLoginFailure.sliderFailed:
      case NjuLoginFailure.sliderNoPointerSupport:
        return true;
      case NjuLoginFailure.invalidCredentials:
      case NjuLoginFailure.network:
      case NjuLoginFailure.timeout:
      case NjuLoginFailure.scriptFailed:
      case NjuLoginFailure.unknown:
        return false;
    }
  }

  /// 失败原因，一句话，不带任何「接下来该怎么办」。
  ///
  /// 后续动作前后台不一样（前台是「请在下方手动完成登录」，后台是「已暂停
  /// 自动更新」），所以这里只给原因，由调用方自己接下半句。
  String get message {
    switch (this) {
      case NjuLoginFailure.invalidCredentials:
        return '账号或密码错误';
      case NjuLoginFailure.imageCaptcha:
        return '出现了图形验证码';
      case NjuLoginFailure.sliderFailed:
        return '滑块验证连续失败';
      case NjuLoginFailure.sliderNoPointerSupport:
        return '无法自动完成滑块验证';
      case NjuLoginFailure.scriptFailed:
        return '自动登录脚本启动失败';
      case NjuLoginFailure.network:
        return '网络错误，请检查网络连接（如需要请先连接南京大学 VPN）';
      case NjuLoginFailure.timeout:
        return '自动登录超时';
      case NjuLoginFailure.unknown:
        return '自动登录失败';
    }
  }
}

/// 一次登录的结果。
class NjuLoginResult {
  const NjuLoginResult._({
    required this.success,
    this.controller,
    this.failure,
    this.detail = '',
  });

  factory NjuLoginResult._success(WebViewController controller) =>
      NjuLoginResult._(success: true, controller: controller);

  factory NjuLoginResult._failure(
    NjuLoginFailure failure,
    String detail,
    WebViewController? controller,
  ) =>
      NjuLoginResult._(
        success: false,
        failure: failure,
        detail: detail,
        controller: controller,
      );

  final bool success;

  /// 成功时是已认证的会话，可以直接喂给 [CourseSyncService.fetch]。
  /// 失败时也可能非空——前台要用它把页面显示给用户手动接手。
  final WebViewController? controller;

  final NjuLoginFailure? failure;

  /// 原始失败信息，给日志和诊断用，不直接展示给用户。
  final String detail;
}
