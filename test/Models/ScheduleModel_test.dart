import 'package:flutter_test/flutter_test.dart';
import 'package:wheretosleepinnju/Models/CourseModel.dart';
import 'package:wheretosleepinnju/Models/ScheduleModel.dart';
import 'package:wheretosleepinnju/Resources/Constant.dart';

Course _course({
  String name = '高等数学',
  required String weeks,
  int weekTime = 1,
  int startTime = 1,
  int timeCount = 1,
  int importType = Constant.ADD_BY_IMPORT,
}) {
  return Course(1, name, weeks, weekTime, startTime, timeCount, importType);
}

/// 覆盖 [ScheduleModel.classify] 的三分类（重点是"本学期已经全部上完的课
/// 不再灰显"这条规则——它原先只对讲座生效，现在扩展到所有课程类型），
/// 以及 [ScheduleModel.deduplicate] 的重叠分组。
void main() {
  test('本周有课的课程进 activeCourses', () {
    final model = ScheduleModel([_course(weeks: '[3,4,5]')], 4);
    model.init();

    expect(model.activeCourses.length, 1);
    expect(model.hideCourses, isEmpty);
  });

  test('本周没课但以后还会上的课程灰显', () {
    final model = ScheduleModel([_course(weeks: '[3,4,5]')], 2);
    model.init();

    expect(model.activeCourses, isEmpty);
    expect(model.hideCourses.length, 1);
  });

  test('本学期已经全部上完的课程既不激活也不灰显', () {
    final model = ScheduleModel([_course(weeks: '[1,2,3]')], 8);
    model.init();

    expect(model.activeCourses, isEmpty);
    expect(model.hideCourses, isEmpty);
    expect(model.freeCourses, isEmpty);
  });

  test('整学期的课在学期中段仍然灰显，不会因为首周已过被误判成已结束', () {
    // 这是老逻辑 `weeks[0] < nowWeek` 的坑：weeks[0] 是开课第一周，
    // 几乎总是小于当前周，照搬到普通课程会把整学期的课全藏掉。
    final model = ScheduleModel([_course(weeks: '[1,2,3,4,5,6,7,8]')], 5);
    model.init();

    // 第 5 周本身有课，所以是 active；把当前周挪到没排课的位置再验一次。
    expect(model.activeCourses.length, 1);

    final gapModel = ScheduleModel([_course(weeks: '[1,2,3,7,8]')], 5);
    gapModel.init();
    expect(gapModel.activeCourses, isEmpty);
    expect(gapModel.hideCourses.length, 1);
  });

  test('已经办完的讲座不显示，未到的讲座灰显', () {
    final past = ScheduleModel(
        [_course(weeks: '[5]', importType: Constant.ADD_BY_LECTURE)], 9);
    past.init();
    expect(past.activeCourses, isEmpty);
    expect(past.hideCourses, isEmpty);

    final upcoming = ScheduleModel(
        [_course(weeks: '[5]', importType: Constant.ADD_BY_LECTURE)], 3);
    upcoming.init();
    expect(upcoming.hideCourses.length, 1);
  });

  test('weeks 为空时照常显示，不因数据异常把课悄悄藏起来', () {
    final model = ScheduleModel([_course(weeks: '[]')], 5);
    model.init();

    expect(model.hideCourses.length, 1);
  });

  test('weekTime 为 0 的自由时间课程不受结束判断影响', () {
    final model =
        ScheduleModel([_course(weeks: '[1,2]', weekTime: 0)], 10);
    model.init();

    expect(model.freeCourses.length, 1);
  });

  group('重叠分组', () {
    test('不重叠的课程各自独立，不产生分组', () {
      final model = ScheduleModel([
        _course(name: 'A', weeks: '[1]', startTime: 1, timeCount: 1),
        _course(name: 'B', weeks: '[1]', startTime: 5, timeCount: 1),
      ], 1);
      model.init();

      expect(model.multiCourses, isEmpty);
      expect(model.activeCourses.length, 2);
    });

    test('不同星期的同节次课程不算重叠', () {
      final model = ScheduleModel([
        _course(name: 'A', weeks: '[1]', weekTime: 1, startTime: 1),
        _course(name: 'B', weeks: '[1]', weekTime: 3, startTime: 1),
      ], 1);
      model.init();

      expect(model.multiCourses, isEmpty);
      expect(model.activeCourses.length, 2);
    });

    test('两门课重叠时归为一组，并从 activeCourses 里摘掉', () {
      final model = ScheduleModel([
        _course(name: 'A', weeks: '[1]', startTime: 1, timeCount: 1),
        _course(name: 'B', weeks: '[1]', startTime: 2, timeCount: 1),
      ], 1);
      model.init();

      expect(model.multiCourses.length, 1);
      expect(model.multiCourses.first.length, 2);
      // 摘干净了才不会既画一个整格块、又画一个分栏块。
      expect(model.activeCourses, isEmpty);
    });

    test('部分重叠（只压住一节）也算重叠', () {
      final model = ScheduleModel([
        _course(name: 'A', weeks: '[1]', startTime: 1, timeCount: 2),
        _course(name: 'B', weeks: '[1]', startTime: 3, timeCount: 2),
      ], 1);
      model.init();

      expect(model.multiCourses.length, 1);
      expect(model.multiCourses.first.length, 2);
    });

    test('传递重叠合并成一组：A 撞 B、B 撞 C，三门归一组', () {
      // 老实现会让 C 同时留在 activeCourses 和分组里，渲染时重复画。
      final model = ScheduleModel([
        _course(name: 'A', weeks: '[1]', startTime: 1, timeCount: 1),
        _course(name: 'B', weeks: '[1]', startTime: 2, timeCount: 1),
        _course(name: 'C', weeks: '[1]', startTime: 3, timeCount: 1),
      ], 1);
      model.init();

      expect(model.multiCourses.length, 1);
      expect(model.multiCourses.first.length, 3);
      expect(model.activeCourses, isEmpty);
    });

    test('灰显课参与分组后也要从 hideCourses 里摘掉', () {
      // 老实现的 if/else 两个分支代码一样，灰显课进了组却没被移除。
      final model = ScheduleModel([
        _course(name: '本周有', weeks: '[1]', startTime: 1, timeCount: 1),
        _course(name: '本周无', weeks: '[2]', startTime: 1, timeCount: 1),
      ], 1);
      model.init();

      expect(model.multiCourses.length, 1);
      expect(model.multiCourses.first.length, 2);
      expect(model.activeCourses, isEmpty);
      expect(model.hideCourses, isEmpty);
    });

    test('组内本周有课的排在前面，同为本周的按节次跨度排', () {
      final model = ScheduleModel([
        _course(name: '灰显', weeks: '[2]', startTime: 1, timeCount: 3),
        _course(name: '本周短', weeks: '[1]', startTime: 1, timeCount: 0),
        _course(name: '本周长', weeks: '[1]', startTime: 1, timeCount: 2),
      ], 1);
      model.init();

      final names = model.multiCourses.first.map((c) => c.name).toList();
      expect(names, ['本周长', '本周短', '灰显']);
    });

    test('同一天同起点、长度不同的两门课要分到一组（5-7 节 vs 5-9 节）', () {
      // timeCount = endTime - startTime，所以 5-7 节是 (5, 2)、5-9 节是 (5, 4)。
      final model = ScheduleModel([
        _course(
            name: '5-7节',
            weeks: '[1,2,3]',
            weekTime: 3,
            startTime: 5,
            timeCount: 2),
        _course(
            name: '5-9节',
            weeks: '[1,2,3]',
            weekTime: 3,
            startTime: 5,
            timeCount: 4,
            importType: Constant.ADD_MANUALLY),
      ], 2);
      model.init();

      expect(model.multiCourses.length, 1);
      expect(model.multiCourses.first.length, 2);
      expect(model.activeCourses, isEmpty);
      // 跨度长的排前面，占左边那一列。
      expect(model.multiCourses.first.first.name, '5-9节');
    });

    test('每门课最多只属于一个分组', () {
      final model = ScheduleModel([
        _course(name: 'A', weeks: '[1]', startTime: 1, timeCount: 1),
        _course(name: 'B', weeks: '[1]', startTime: 2, timeCount: 1),
        _course(name: 'C', weeks: '[1]', startTime: 8, timeCount: 1),
        _course(name: 'D', weeks: '[1]', startTime: 9, timeCount: 1),
      ], 1);
      model.init();

      expect(model.multiCourses.length, 2);
      final grouped = model.multiCourses.expand((g) => g).toList();
      expect(grouped.length, 4);
      expect(grouped.toSet().length, 4, reason: '同一门课不该出现在多个组里');
    });
  });
}
