import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:wheretosleepinnju/Services/BackgroundSyncGuard.dart';
import 'package:wheretosleepinnju/Services/BackgroundSyncRunner.dart';
import 'package:wheretosleepinnju/Services/SyncNotifier.dart';

void main() {
  const notifier = SyncNotifier();

  group('平台守卫', () {
    // 这组测试跑在桌面上（非 Android），正好等价于鸿蒙那种"插件没被注册"的
    // 环境。`flutter_local_notifications` 只声明了 android / ios，在别的平台
    // 上调用会抛 MissingPluginException——守卫就是为了拦住它。
    test('非 Android 平台上报告不支持', () {
      expect(Platform.isAndroid, isFalse, reason: '这组测试的前提是宿主不是 Android');
      expect(notifier.isSupported, isFalse);
    });

    test('不支持的平台上发通知是安静的空操作，不抛异常', () async {
      // 从后台 isolate 调用，抛出去会把整轮同步带崩，而那时候课表数据已经
      // 落库了——白跑一轮还丢结论。
      await expectLater(
        notifier.notifyResult(
          const BackgroundSyncResult.forTesting(BackgroundSyncOutcome.ok),
        ),
        completes,
      );
      await expectLater(
        notifier.notifyResult(
          const BackgroundSyncResult.forTesting(
            BackgroundSyncOutcome.loginFailed,
            verdict: GuardVerdict.disabled,
          ),
        ),
        completes,
      );
    });

    test('不支持的平台上申请权限返回 false 而不是抛异常', () async {
      expect(await notifier.requestPermission(), isFalse);
    });
  });

  group('通知正文', () {
    test('普通更新说已经更新好了', () {
      final body = notifier.changesBody(
        const BackgroundSyncResult.forTesting(BackgroundSyncOutcome.ok),
      );
      expect(body, contains('已经帮你更新好了'));
    });

    test('换学期要说明是哪个学期、需要用户自己动手', () {
      // 换学期不是"已经更新好了"——得用户去导入页新建一张表，正文必须
      // 说清楚，否则用户点开发现课表没变会以为坏了。
      final body = notifier.changesBody(
        const BackgroundSyncResult.forTesting(
          BackgroundSyncOutcome.semesterChanged,
          semesterName: '2025-2026学年第二学期',
        ),
      );
      expect(body, contains('2025-2026学年第二学期'));
      expect(body, contains('新建'));
    });

    test('换学期但没拿到学期名时也能说人话', () {
      final body = notifier.changesBody(
        const BackgroundSyncResult.forTesting(
          BackgroundSyncOutcome.semesterChanged,
        ),
      );
      expect(body, contains('新的学期'));
      expect(body, isNot(contains('null')));
    });
  });
}
