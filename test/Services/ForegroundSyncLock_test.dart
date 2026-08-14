import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wheretosleepinnju/Services/ForegroundSyncLock.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const lock = ForegroundSyncLock();

  test('没人持锁时后台照跑', () async {
    expect(await lock.isHeld(), isFalse);
  });

  test('前台持锁期间后台该跳过', () async {
    await lock.acquire();
    expect(await lock.isHeld(), isTrue);
  });

  test('解锁之后立刻恢复', () async {
    await lock.acquire();
    await lock.release();
    expect(await lock.isHeld(), isFalse);
  });

  group('过期', () {
    // 这一组防的是"前台持锁时被杀掉，后台从此再也不跑且毫无征兆"。
    final acquiredAt = DateTime(2026, 8, 14, 10, 0);

    test('还没到过期时间，锁仍然有效', () async {
      await lock.acquire(now: acquiredAt);
      expect(
        await lock.isHeld(now: acquiredAt.add(const Duration(minutes: 4))),
        isTrue,
      );
    });

    test('超过过期时间就当没人持有', () async {
      await lock.acquire(now: acquiredAt);
      expect(
        await lock.isHeld(now: acquiredAt.add(const Duration(minutes: 6))),
        isFalse,
        reason: '持锁的前台多半已经被杀掉了，再等下去等于把后台检查废掉',
      );
    });

    test('时间戳坏掉当作没锁，不能因此永久卡死', () async {
      SharedPreferences.setMockInitialValues(
          {'nju_foreground_sync_started_at': '这不是时间'});
      expect(await lock.isHeld(), isFalse);
    });

    test('时间戳在未来（设备时钟被改过）时保守处理，当作持有', () async {
      await lock.acquire(now: acquiredAt);
      expect(
        await lock.isHeld(now: acquiredAt.subtract(const Duration(hours: 1))),
        isTrue,
        reason: '算不准的时候跳过一轮，比撞上并发写库安全',
      );
    });
  });

  group('protect', () {
    test('正常路径进出都对', () async {
      var ran = false;
      await lock.protect(() async {
        ran = true;
        expect(await lock.isHeld(), isTrue, reason: '执行期间应当持锁');
      });
      expect(ran, isTrue);
      expect(await lock.isHeld(), isFalse);
    });

    test('抛异常也会解锁——这正是 protect 存在的理由', () async {
      await expectLater(
        lock.protect(() async => throw StateError('抓取炸了')),
        throwsStateError,
      );
      expect(await lock.isHeld(), isFalse,
          reason: '失败路径不解锁的话，后台要白等 5 分钟');
    });

    test('把返回值原样传出来', () async {
      expect(await lock.protect(() async => 42), 42);
    });
  });
}
