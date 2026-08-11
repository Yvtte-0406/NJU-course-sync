import 'CourseModel.dart';
import 'dart:convert';

class ScheduleModel {
  int nowWeek;
  List<Course> courses;
  List<Course> activeCourses = [];
  List<Course> hideCourses = [];
  List<List<Course>> multiCourses = [];
  List<Course> freeCourses = [];

  //TODO: multiCourses
  // List<List<Course>> multiCourses = [
  //  List<Course> freeCourses = [
  //     new Course(0, "微积分", "[1,2,3,4,5,6,7]", 1, 7, 2, 0,
  //         color: '#8AD297', classroom: 'QAQ'),
  //     new Course(0, "还是微积分", "[1,2,3,4,5,6,7]", 1, 7, 2, 0,
  //         color: '#F9A883', classroom: 'QAQ'),
  //     new Course(0, "又是微积分", "[1,2,3,4,5,6,7]", 1, 7, 2, 0,
  //         color: '#F9A883', classroom: 'QAQ')
  //   ];
  // ];

  ScheduleModel(this.courses, this.nowWeek);

  init() {
    classify();
    deduplicate();
  }

  void classify() {
    for (Course course in courses) {
      // 学校数据里已经没有这门课了，正在两轮宽限期里等最终确认——数据还在，
      // 但先别显示。下一轮要是又抓到了，它会原样回来。
      if (course.missingRounds > 0) continue;
      List weeks = json.decode(course.weeks!);
      if (course.weekTime == 0) {
        freeCourses.add(course);
      } else if (weeks.contains(nowWeek)) {
        activeCourses.add(course);
      } else if (_isFinished(weeks)) {
        // 本学期已经全部上完的课直接不显示。灰显是留给"这周不上、但以后
        // 还会上"的课的，已经结束的课再灰着占着格子只会干扰阅读。
        continue;
      } else {
        hideCourses.add(course);
      }
    }
  }

  /// 这门课在本学期是否已经全部结束：所有周次都早于当前周。
  ///
  /// 原先只有讲座（`ADD_BY_LECTURE`）做这个判断，而且用的是
  /// `weeks[0] < nowWeek`——讲座一般只排一个周次，取第一个碰巧等价于取
  /// 全部，但普通课程的 `weeks[0]` 是开课第一周，几乎总是小于当前周，
  /// 照搬会把整学期的课全部误判成"已结束"。所以这里改成看最大周次。
  ///
  /// 取不到任何有效周次时返回 false（照常显示），宁可多显示也不要因为
  /// 数据异常把课悄悄藏起来。
  bool _isFinished(List weeks) {
    bool sawValidWeek = false;
    for (final raw in weeks) {
      final int? week = raw is int ? raw : int.tryParse(raw.toString());
      if (week == null) continue;
      sawValidWeek = true;
      if (week >= nowWeek) return false;
    }
    return sawValidWeek;
  }

  /// 把时间上互相重叠的课程归成一组挪进 [multiCourses]，并从
  /// [activeCourses]/[hideCourses] 里摘掉——这两个列表最终只剩"独占一格"
  /// 的课，渲染层可以直接整格画；成组的那些由渲染层横向平分格子并排画。
  ///
  /// 本周课和灰显课放在一起分组：两门课只要在格子上撞了就该并排显示，
  /// 跟它们各自是不是本周的没关系。
  void deduplicate() {
    // 传递分组：A 和 B 撞、B 和 C 撞，三门归成一组（哪怕 A 和 C 不直接
    // 撞）。不做传递合并的话同一门课会同时落进两个组，渲染时必然重复画。
    final List<List<Course>> groups = [];
    for (final Course course in [...activeCourses, ...hideCourses]) {
      final List<List<Course>> hit = groups
          .where((group) => group.any((c) => _checkIfOverlapping(course, c)))
          .toList();
      if (hit.isEmpty) {
        groups.add([course]);
        continue;
      }
      // 撞上多个已有组，说明这门课把它们连成了一片，合并成一组。
      final List<Course> merged = hit.first..add(course);
      for (final other in hit.skip(1)) {
        merged.addAll(other);
        groups.remove(other);
      }
    }

    multiCourses = groups.where((group) => group.length > 1).toList();
    for (final group in multiCourses) {
      _sortGroup(group);
    }

    final Set<Course> grouped = multiCourses.expand((g) => g).toSet();
    activeCourses.removeWhere((c) => grouped.contains(c));
    hideCourses.removeWhere((c) => grouped.contains(c));
  }

  /// 组内排序决定并排显示时谁在左、以及并排放不下时先牺牲谁：本周实际有
  /// 课的排前面，同为本周的按占的节次多少排——课时长的那门信息量更大，
  /// 优先占左边那一列。
  void _sortGroup(List<Course> group) {
    group.sort((a, b) {
      final int byWeek =
          (_isThisWeek(b) ? 1 : 0).compareTo(_isThisWeek(a) ? 1 : 0);
      if (byWeek != 0) return byWeek;
      return (b.timeCount ?? 0).compareTo(a.timeCount ?? 0);
    });
  }

  bool _isThisWeek(Course course) =>
      (json.decode(course.weeks!) as List).contains(nowWeek);

  bool _checkIfOverlapping(Course a, Course b) {
    bool result = a.weekTime == b.weekTime &&
        ((a.startTime! >= b.startTime! &&
                a.startTime! <= b.startTime! + b.timeCount!) ||
            (b.startTime! >= a.startTime! &&
                b.startTime! <= a.startTime! + a.timeCount!));
//    print(result);
    return result;
  }
}
