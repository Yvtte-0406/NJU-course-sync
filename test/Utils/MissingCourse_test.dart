import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheretosleepinnju/Models/CourseModel.dart';
import 'package:wheretosleepinnju/Models/ScheduleModel.dart';
import 'package:wheretosleepinnju/Utils/MissingCourseSweeper.dart';

Course _course({String name = '高等数学', String weeks = '[1,2,3]'}) =>
    Course(1, name, weeks, 1, 1, 1, 1);

void main() {
  group('缺失轮次的存取', () {
    test('默认是 0', () {
      expect(_course().missingRounds, 0);
    });

    test('标记后写进 data 列，并记下第一次缺失的时间', () {
      final course = _course()..missingRounds = 1;

      expect(course.missingRounds, 1);
      final decoded = json.decode(course.data!) as Map;
      expect(decoded['missing_rounds'], 1);
      expect(decoded['missing_since'], isNotNull);
    });

    test('累加轮次时不覆盖第一次缺失的时间', () {
      final course = _course()..missingRounds = 1;
      final firstSeen = (json.decode(course.data!) as Map)['missing_since'];

      course.missingRounds = 2;

      expect((json.decode(course.data!) as Map)['missing_since'], firstSeen);
    });

    test('清零后 data 列整个清空，不留空壳 JSON', () {
      final course = _course()..missingRounds = 2;
      course.missingRounds = 0;

      expect(course.missingRounds, 0);
      expect(course.data, isNull);
    });

    test('经过 toMap / fromMap 往返仍然保留', () {
      final course = _course()..missingRounds = 1;
      final restored = Course.fromMap(Map<String, dynamic>.from(course.toMap()));

      expect(restored.missingRounds, 1);
    });

    test('data 列里是非 JSON 的历史脏数据时当作 0，不抛异常', () {
      final course = _course()..data = '这不是 JSON';
      expect(course.missingRounds, 0);
    });

    test('负数按 0 处理', () {
      final course = _course()..data = json.encode({'missing_rounds': -3});
      expect(course.missingRounds, 0);
    });
  });

  group('缺失的课不参与课表渲染', () {
    test('标记过的课既不激活也不灰显', () {
      final course = _course()..missingRounds = 1;
      final model = ScheduleModel([course], 2);
      model.init();

      expect(model.activeCourses, isEmpty);
      expect(model.hideCourses, isEmpty);
      expect(model.freeCourses, isEmpty);
    });

    test('没标记的课照常显示', () {
      final model = ScheduleModel([_course()], 2);
      model.init();

      expect(model.activeCourses.length, 1);
    });

    test('恢复（清零）之后重新显示', () {
      final course = _course()..missingRounds = 1;
      course.missingRounds = 0;

      final model = ScheduleModel([course], 2);
      model.init();

      expect(model.activeCourses.length, 1);
    });
  });

  group('给用户的汇报文案', () {
    test('什么都没发生时不打扰用户', () {
      expect(const MissingSweepResult().summary, isNull);
      expect(const MissingSweepResult().isEmpty, isTrue);
    });

    test('分别说明隐藏、删除、恢复', () {
      expect(const MissingSweepResult(hidden: 2).summary, contains('暂时隐藏'));
      expect(const MissingSweepResult(deleted: 1).summary, contains('已删除'));
      expect(const MissingSweepResult(restored: 3).summary, contains('恢复显示'));
    });

    test('同时发生时一句话讲完', () {
      final summary =
          const MissingSweepResult(hidden: 1, deleted: 2, restored: 3).summary!;

      expect(summary, contains('3 门课重新出现'));
      expect(summary, contains('1 门课'));
      expect(summary, contains('2 门课'));
    });
  });

  test('宽限期是两轮', () {
    // 改这个常量等于改产品行为，值得单独钉一下。
    expect(kMissingRoundsBeforeDelete, 2);
  });
}
