import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheretosleepinnju/Services/BackgroundSyncScheduler.dart';

void main() {
  group('当前的 JSON 格式', () {
    test('写出去再读回来内容不变', () {
      final original = BackgroundSyncRecord(
        at: DateTime.parse('2026-08-17T10:10:06.373422'),
        outcome: 'loginFailed',
        semesterName: '',
        loginFailure: 'invalidCredentials',
      );

      final restored =
          BackgroundSyncRecord.parse(json.encode(original.toJson()))!;

      expect(restored.at, original.at);
      expect(restored.outcome, 'loginFailed');
      expect(restored.loginFailure, 'invalidCredentials');
    });

    test('没有失败原因时不写这个字段，读回来是空串', () {
      final record = BackgroundSyncRecord(
        at: DateTime.parse('2026-08-17T10:10:06.373422'),
        outcome: 'ok',
        semesterName: '2025-2026学年第一学期',
      );

      expect(record.toJson().containsKey('failure'), isFalse);
      final restored =
          BackgroundSyncRecord.parse(json.encode(record.toJson()))!;
      expect(restored.loginFailure, isEmpty);
      expect(restored.semesterName, '2025-2026学年第一学期');
    });

    test('学期名里带竖线不再是问题', () {
      // 换成 JSON 的动机之一：旧格式靠 `|` 分段，学期名只能贪婪吃到结尾，
      // 再加字段就没位置了。
      final record = BackgroundSyncRecord(
        at: DateTime.parse('2026-08-17T10:10:06.373422'),
        outcome: 'ok',
        semesterName: 'a|b',
        loginFailure: '',
      );
      final restored =
          BackgroundSyncRecord.parse(json.encode(record.toJson()))!;
      expect(restored.semesterName, 'a|b');
    });

    test('JSON 坏掉时退回按旧格式解，不整条丢掉', () {
      final r = BackgroundSyncRecord.parse('{这不是合法 JSON');
      expect(r, isNotNull);
    });
  });

  group('解析上次同步记录（旧的分隔串格式）', () {
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

    test('旧记录没有失败原因字段，读出来是空串而不是崩', () {
      // 升级上来的用户本地存的还是分隔串，那时候还没有这个字段。
      final r = BackgroundSyncRecord.parse(
          '2026-08-17T10:10:06.373422|loginFailed|');
      expect(r!.outcome, 'loginFailed');
      expect(r.loginFailure, isEmpty);
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
