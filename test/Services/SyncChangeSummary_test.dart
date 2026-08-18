import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheretosleepinnju/Models/CourseModel.dart';
import 'package:wheretosleepinnju/Services/SyncChangeSummary.dart';
import 'package:wheretosleepinnju/Utils/CourseDiff.dart';
import 'package:wheretosleepinnju/Utils/MissingCourseSweeper.dart';

Course _course({
  required String name,
  String? classNumber,
  String? teacher,
  String? classroom,
  int weekTime = 1,
  int startTime = 1,
}) =>
    Course(1, name, '[1,2,3]', weekTime, startTime, 1, 1,
        classNumber: classNumber, teacher: teacher, classroom: classroom);

final _at = DateTime(2026, 8, 15, 6, 0);

SyncChangeSummary? _build({
  CourseDiffResult? diff,
  MissingSweepResult? sweep,
}) =>
    SyncChangeSummary.build(
      tableName: '2025-2026学年第一学期',
      at: _at,
      diff: diff,
      sweep: sweep,
    );

void main() {
  group('生成摘要', () {
    test('没有任何变化时返回 null，不弹空窗', () {
      expect(_build(), isNull);
      expect(
        _build(
          diff: diffCourseLists(const [], const []),
          sweep: const MissingSweepResult(),
        ),
        isNull,
      );
    });

    test('字段变更写成 旧值 → 新值', () {
      final diff = diffCourseLists(
        [_course(name: '高等数学', classNumber: 'M1', classroom: '仙Ⅰ-101')],
        [_course(name: '高等数学', classNumber: 'M1', classroom: '仙Ⅰ-202')],
      );

      final summary = _build(diff: diff)!;

      expect(summary.entries.length, 1);
      expect(summary.entries.first.kind, SyncChangeKind.changed);
      expect(summary.entries.first.name, '高等数学');
      expect(summary.entries.first.detail, contains('教室：仙Ⅰ-101 → 仙Ⅰ-202'));
    });

    test('空值显示成（空）而不是空白，免得看起来像少了一截', () {
      final diff = diffCourseLists(
        [_course(name: '高等数学', classNumber: 'M1', classroom: '')],
        [_course(name: '高等数学', classNumber: 'M1', classroom: '仙Ⅰ-202')],
      );

      expect(_build(diff: diff)!.entries.first.detail, contains('（空）'));
    });

    test('新增课程带上时间地点', () {
      final diff = diffCourseLists(
        const [],
        [
          _course(
              name: '大学英语',
              classNumber: 'E1',
              weekTime: 3,
              startTime: 5,
              classroom: '仙Ⅱ-305')
        ],
      );

      final entry = _build(diff: diff)!.entries.single;
      expect(entry.kind, SyncChangeKind.added);
      expect(entry.name, '大学英语');
      expect(entry.detail, contains('星期3'));
      expect(entry.detail, contains('第5 节'));
      expect(entry.detail, contains('仙Ⅱ-305'));
    });

    test('消失处理按数量汇总成三条', () {
      final summary = _build(
        sweep: const MissingSweepResult(hidden: 2, deleted: 1, restored: 3),
      )!;

      expect(summary.entries.length, 3);
      expect(summary.entries.map((e) => e.kind), [
        SyncChangeKind.hidden,
        SyncChangeKind.deleted,
        SyncChangeKind.restored,
      ]);
      expect(summary.entries[0].name, contains('2 门课'));
      expect(summary.entries[1].name, contains('1 门课'));
      expect(summary.entries[2].name, contains('3 门课'));
    });

    test('比对变化和消失处理会合并进同一份摘要', () {
      final diff = diffCourseLists(
        [_course(name: '高等数学', classNumber: 'M1', classroom: 'A')],
        [_course(name: '高等数学', classNumber: 'M1', classroom: 'B')],
      );

      final summary = _build(
        diff: diff,
        sweep: const MissingSweepResult(hidden: 1),
      )!;

      expect(summary.entries.length, 2);
    });
  });

  group('存取往返', () {
    test('编码再解码内容不变', () {
      final original = _build(
        sweep: const MissingSweepResult(hidden: 1, restored: 2),
      )!;

      final restored =
          SyncChangeSummary.fromJson(json.decode(json.encode(original.toJson())))!;

      expect(restored.at, original.at);
      expect(restored.tableName, original.tableName);
      expect(restored.entries.length, original.entries.length);
      expect(restored.entries.first.kind, original.entries.first.kind);
      expect(restored.entries.first.name, original.entries.first.name);
      expect(restored.entries.first.detail, original.entries.first.detail);
    });

    test('坏数据一律解成 null，不让弹窗把课表页带崩', () {
      expect(SyncChangeSummary.fromJson(null), isNull);
      expect(SyncChangeSummary.fromJson('不是对象'), isNull);
      expect(SyncChangeSummary.fromJson({'entries': []}), isNull);
      expect(SyncChangeSummary.fromJson({'at': '不是时间'}), isNull);
      // 有时间但一条有效条目都没有
      expect(
        SyncChangeSummary.fromJson({
          'at': _at.toIso8601String(),
          'entries': [
            {'kind': '未来版本才有的类型', 'name': 'x', 'detail': 'y'}
          ]
        }),
        isNull,
      );
    });

    test('认不出的条目类型被跳过，其余照常显示', () {
      final restored = SyncChangeSummary.fromJson({
        'at': _at.toIso8601String(),
        'tableName': 'T',
        'entries': [
          {'kind': '未来版本才有的类型', 'name': 'x', 'detail': 'y'},
          {'kind': 'added', 'name': '大学英语', 'detail': '新增课程'},
        ],
      })!;

      expect(restored.entries.length, 1);
      expect(restored.entries.single.name, '大学英语');
    });
  });
}
