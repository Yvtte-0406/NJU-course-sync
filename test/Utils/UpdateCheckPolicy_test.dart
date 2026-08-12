import 'package:flutter_test/flutter_test.dart';
import 'package:wheretosleepinnju/Utils/UpdateCheckPolicy.dart';

final _now = DateTime(2026, 8, 12, 12, 0);

String _hoursAgo(int h) => _now.subtract(Duration(hours: h)).toIso8601String();
String _daysAgo(int d) => _now.subtract(Duration(days: d)).toIso8601String();

bool _due({
  bool isAutoImported = true,
  String? lastCheckedAt,
  UpdateCheckInterval interval = UpdateCheckInterval.daily,
}) =>
    shouldRemindUpdateCheck(
      isAutoImported: isAutoImported,
      lastCheckedAt: lastCheckedAt,
      interval: interval,
      now: _now,
    );

void main() {
  group('该不该提醒检查更新', () {
    test('刚查过不提醒，超过间隔才提醒', () {
      expect(_due(lastCheckedAt: _hoursAgo(2)), isFalse);
      expect(_due(lastCheckedAt: _daysAgo(2)), isTrue);
    });

    test('刚好到点就提醒', () {
      expect(_due(lastCheckedAt: _daysAgo(1)), isTrue);
    });

    test('手动建的课表永远不提醒', () {
      // 学校那边根本没有这张表对应的数据，没有"更新"可言。
      expect(
        _due(isAutoImported: false, lastCheckedAt: _daysAgo(30)),
        isFalse,
      );
    });

    test('选了"不提醒"就一直不提醒', () {
      expect(
        _due(
          lastCheckedAt: _daysAgo(365),
          interval: UpdateCheckInterval.manual,
        ),
        isFalse,
      );
    });

    test('"每次打开"只要是自动导入的表就提醒', () {
      expect(
        _due(
          lastCheckedAt: _now.toIso8601String(),
          interval: UpdateCheckInterval.everyLaunch,
        ),
        isTrue,
      );
    });

    test('各档间隔分别生效', () {
      expect(
        _due(
            lastCheckedAt: _daysAgo(2),
            interval: UpdateCheckInterval.everyThreeDays),
        isFalse,
      );
      expect(
        _due(
            lastCheckedAt: _daysAgo(4),
            interval: UpdateCheckInterval.everyThreeDays),
        isTrue,
      );
      expect(
        _due(lastCheckedAt: _daysAgo(5), interval: UpdateCheckInterval.weekly),
        isFalse,
      );
      expect(
        _due(lastCheckedAt: _daysAgo(8), interval: UpdateCheckInterval.weekly),
        isTrue,
      );
    });

    test('没有记录过检查时间时提醒一次，把记录补上', () {
      expect(_due(lastCheckedAt: null), isTrue);
      expect(_due(lastCheckedAt: ''), isTrue);
    });

    test('时间戳坏掉时当作没查过，不抛异常', () {
      expect(_due(lastCheckedAt: '这不是时间'), isTrue);
    });

    test('上次检查时间在未来时不提醒，不会因为改过系统时间就一直弹', () {
      expect(
        _due(lastCheckedAt: _now.add(const Duration(days: 3)).toIso8601String()),
        isFalse,
      );
    });
  });

  group('存储键', () {
    test('每个档位的键都不重复', () {
      final keys =
          UpdateCheckInterval.values.map((e) => e.storageKey).toList();
      expect(keys.toSet().length, keys.length);
    });

    test('存了能读回来', () {
      for (final value in UpdateCheckInterval.values) {
        expect(UpdateCheckIntervalX.fromStorageKey(value.storageKey), value);
      }
    });

    test('读到未知或缺失的键时退回每天', () {
      expect(UpdateCheckIntervalX.fromStorageKey(null),
          UpdateCheckInterval.daily);
      expect(UpdateCheckIntervalX.fromStorageKey('八百年一次'),
          UpdateCheckInterval.daily);
    });
  });

  group('上次检查的描述文案', () {
    test('按时间跨度换单位', () {
      expect(describeLastChecked(_hoursAgo(0), _now), '刚刚检查过');
      expect(describeLastChecked(_now.subtract(const Duration(minutes: 30)).toIso8601String(), _now),
          '30 分钟前检查过');
      expect(describeLastChecked(_hoursAgo(5), _now), '5 小时前检查过');
      expect(describeLastChecked(_daysAgo(3), _now), '3 天前检查过');
    });

    test('没查过或时间戳坏掉都说从未检查过', () {
      expect(describeLastChecked(null, _now), '从未检查过更新');
      expect(describeLastChecked('', _now), '从未检查过更新');
      expect(describeLastChecked('坏数据', _now), '从未检查过更新');
    });
  });
}
