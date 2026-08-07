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

/// 覆盖 [ScheduleModel.classify] 的三分类，重点是"本学期已经全部上完的课
/// 不再灰显"这条规则——它原先只对讲座生效，现在扩展到所有课程类型。
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
}
