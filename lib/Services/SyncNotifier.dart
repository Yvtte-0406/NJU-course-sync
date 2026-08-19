import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'BackgroundSyncRunner.dart';

/// 后台同步完成后给用户发的本地通知。
///
/// 只发两种，各自解决一个问题：
/// - **课表变了**：静默更新好本来就是目标，但用户至少该知道发生过；点开
///   进 App，课表页会把变更摘要弹出来（摘要已经落在本地，不需要通知携带
///   任何数据，也就不需要做深链接路由）。
/// - **自动更新停了**：这条比上一条重要得多。凭据失效会让自动更新被守卫
///   停用，不告诉用户的话，他会一直以为在自动更新，直到某天发现课表是旧的。
///
/// 平台策略与 [BackgroundSyncScheduler] 一致：
/// - 鸿蒙上插件不会被注册，一调用就是 `MissingPluginException`，所以全部
///   调用收口在这里由 [isSupported] 拦掉。
/// - iOS 暂时也关着，但**原因不同**：插件支持 iOS，只是通知权限要单独申请、
///   前台展示行为也要另配，没配好就是发了不响。等那部分做完并在真机验过
///   再打开——半通不通的通知比明确没有更糟。
class SyncNotifier {
  const SyncNotifier();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// 通道 id 一旦发布就不能改：Android 把用户对这个通道的设置（是否允许、
  /// 提示音、重要性）跟 id 绑在一起，换 id 等于新建一个通道，用户之前
  /// 关掉过的设置会失效、又开始弹。
  static const String _channelId = 'nju_course_sync';
  static const String _channelName = '课表自动更新';
  static const String _channelDescription = '后台检查到课表变化，或自动更新被暂停时提醒';

  /// 两条通知用不同 id，这样"课表变了"不会把"自动更新已暂停"顶掉。
  static const int _changesNotificationId = 1001;
  static const int _attentionNotificationId = 1002;

  bool get isSupported => Platform.isAndroid;

  Future<bool> _ensureInitialized() async {
    if (!isSupported) return false;
    try {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      return true;
    } catch (e) {
      debugPrint('[SyncNotifier] 初始化失败：$e');
      return false;
    }
  }

  /// 申请通知权限。Android 13 起通知需要运行时授权，13 以前直接返回 true。
  ///
  /// 调用时机在用户打开「自动更新」开关的时候——那个动作本身就表示"我想
  /// 收到更新"，比 App 一启动就弹自然，也不会打扰不用这个功能的人。
  Future<bool> requestPermission() async {
    if (!await _ensureInitialized()) return false;
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await android?.requestNotificationsPermission() ?? false;
    } catch (e) {
      debugPrint('[SyncNotifier] 申请权限失败：$e');
      return false;
    }
  }

  /// 按这一轮的结果决定发什么。什么都不该发时安静返回。
  ///
  /// 从后台 isolate 调用，所以绝不能抛异常——通知发不出去是小事，把整轮
  /// 同步带崩就白跑了（课表数据那时候已经落库）。
  Future<void> notifyResult(BackgroundSyncResult result) async {
    try {
      if (result.needsUserAttention) {
        await _show(
          id: _attentionNotificationId,
          title: '课表自动更新已暂停',
          body: '连续两次登录失败，多半是密码改过了。打开 App 重新登录一次即可恢复。',
        );
        return;
      }
      if (result.hasChangesWorthNotifying) {
        await _show(
          id: _changesNotificationId,
          title: '课表有变化',
          body: _changesBody(result),
        );
      }
    } catch (e) {
      debugPrint('[SyncNotifier] 发通知失败：$e');
    }
  }

  /// 通知正文。只说"有变化、进来看"，不铺开具体改了什么——通知栏里塞不下，
  /// 而且用户点进来就能看到完整的变更弹窗。
  @visibleForTesting
  String changesBody(BackgroundSyncResult result) => _changesBody(result);

  String _changesBody(BackgroundSyncResult result) {
    if (result.outcome == BackgroundSyncOutcome.semesterChanged) {
      final semester = result.semesterName;
      final which = semester.isEmpty ? '新的学期' : semester;
      return '教务系统已经是$which了，打开 App 新建一张课表。';
    }
    return '已经帮你更新好了，打开 App 看看改了什么。';
  }

  Future<void> _show({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!await _ensureInitialized()) return;
    await _plugin.show(
      id,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          // 课表变化不是紧急事，用默认重要性：会出现在通知栏，但不横幅弹出、
          // 不打断用户正在做的事。
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          // 正文可能比一行长，展开后要能看全。
          styleInformation: BigTextStyleInformation(''),
        ),
      ),
    );
  }
}
