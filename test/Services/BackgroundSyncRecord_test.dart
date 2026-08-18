import 'package:flutter_test/flutter_test.dart';
import 'package:wheretosleepinnju/Services/BackgroundSyncScheduler.dart';

void main() {
  group('解析上次同步记录', () {
    test('三段式：时间、结果、学期名', () {
      final r = BackgroundSyncRecord.parse(
          '2026-08-17T10:10:06.373422|emptyFetch|2025-2026学年 暑期');
      expect(r, isNotNull);
      expect(r!.at, DateTime.parse('2026-08-17T10:10:06.373422'));
      expect(r.outcome, 'emptyFetch');
      expect(r.semesterName, '2025-2026学年 暑期');
    });

    test('两段式的旧记录仍然读得出来', () {
      // 学期名是后加的字段。已经装了这个 App 的用户本地存的还是两段式，
      // 按三段硬切会拿到错的值或者直接崩——升级路径必须留。
      final r = BackgroundSyncRecord.parse('2026-08-17T10:10:06.373422|ok');
      expect(r, isNotNull);
      expect(r!.outcome, 'ok');
      expect(r.semesterName, isEmpty);
    });

    test('学期名为空的三段式', () {
      final r = BackgroundSyncRecord.parse('2026-08-17T10:10:06.373422|error|');
      expect(r!.outcome, 'error');
      expect(r.semesterName, isEmpty);
    });

    test('学期名里带竖线时不会被截断', () {
      final r = BackgroundSyncRecord.parse('2026-08-17T10:10:06.373422|ok|a|b');
      expect(r!.semesterName, 'a|b');
    });

    test('没跑过返回 null', () {
      expect(BackgroundSyncRecord.parse(null), isNull);
      expect(BackgroundSyncRecord.parse(''), isNull);
    });

    test('时间戳坏掉时 at 为 null，但结果还读得出来', () {
      // 记录坏了不该让整页崩掉——结果本身仍然有展示价值。
      final r = BackgroundSyncRecord.parse('这不是时间|ok|秋季学期');
      expect(r, isNotNull);
      expect(r!.at, isNull);
      expect(r.outcome, 'ok');
      expect(r.semesterName, '秋季学期');
    });
  });
}
