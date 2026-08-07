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

//  void deduplication(List<Course> courses, int nowWeek) {
  void deduplicate() {
    List<Course> deduplicateResult = [];
    List<Course> needToDelete = [];
    bool isOverlapped = false;
    // 分开检查的目的是保证 multiCourse 的每一个第一项有最大可能是 active 的
    for (Course course in activeCourses) {
      isOverlapped = false;
      for (List<Course> checked in multiCourses) {
        if (_checkIfOverlapping(course, checked[0])) {
          checked.add(course);
          _checkMultiCousesElement(checked);
          isOverlapped = true;
        }
      }
      if (isOverlapped) continue;
      for (Course checked in deduplicateResult) {
        if (_checkIfOverlapping(course, checked)) {
          multiCourses.add([course, checked]);
          _checkMultiCousesElement(multiCourses.last);
          deduplicateResult.remove(checked);
          needToDelete.add(checked);
          needToDelete.add(course);
          isOverlapped = true;
          break;
        }
      }
      if (!isOverlapped) deduplicateResult.add(course);
    }
    for (Course item in needToDelete) {
      activeCourses.remove(item);
    }
    needToDelete.clear();
    for (Course course in hideCourses) {
      isOverlapped = false;
      for (List<Course> checked in multiCourses) {
        if (_checkIfOverlapping(course, checked[0])) {
          checked.add(course);
          _checkMultiCousesElement(checked);
          isOverlapped = true;
          break;
        }
      }
      if (isOverlapped) continue;
      for (Course checked in deduplicateResult) {
        if (_checkIfOverlapping(course, checked)) {
          multiCourses.add([course, checked]);
          _checkMultiCousesElement(multiCourses.last);
          deduplicateResult.remove(checked);
          needToDelete.add(checked);
          needToDelete.add(course);
          isOverlapped = true;
          break;
        }
      }
      if (!isOverlapped) deduplicateResult.add(course);
    }
    for (Course item in needToDelete) {
      if (hideCourses.contains(item)) {
        activeCourses.remove(item);
      } else {
        activeCourses.remove(item);
      }
    }
  }

  bool _checkIfOverlapping(Course a, Course b) {
    bool result = a.weekTime == b.weekTime &&
        ((a.startTime! >= b.startTime! &&
                a.startTime! <= b.startTime! + b.timeCount!) ||
            (b.startTime! >= a.startTime! &&
                b.startTime! <= a.startTime! + a.timeCount!));
//    print(result);
    return result;
  }

  // TODO: Shit codes, may have bugs here.
  void _checkMultiCousesElement(List<Course> multiCoursesElement) {
    int maxCount = 0;
    int maxIndex = 0;
    for (int i = 0; i < multiCoursesElement.length; i++) {
      List weeks = json.decode(multiCoursesElement[i].weeks!);
      if (multiCoursesElement[i].timeCount! > maxCount &&
          weeks.contains(nowWeek)) {
        maxCount = multiCoursesElement[i].timeCount!;
        maxIndex = i;
      }
    }
    if (maxIndex != 0) {
      Course tmp = multiCoursesElement[maxIndex];
      multiCoursesElement[maxIndex] = multiCoursesElement[0];
      multiCoursesElement[0] = tmp;
    }
  }
}
