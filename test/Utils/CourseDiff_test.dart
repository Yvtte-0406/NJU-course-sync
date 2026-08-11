import 'package:flutter_test/flutter_test.dart';
import 'package:wheretosleepinnju/Models/CourseModel.dart';
import 'package:wheretosleepinnju/Resources/Constant.dart';
import 'package:wheretosleepinnju/Utils/CourseDiff.dart';

Course _course({
  required String name,
  String? classNumber,
  String? teacher,
  String? classroom,
  String? info,
  int weekTime = 1,
  int startTime = 1,
  int timeCount = 1,
  String weeks = '[1,2,3]',
  int importType = Constant.ADD_BY_IMPORT,
}) {
  return Course(1, name, weeks, weekTime, startTime, timeCount, importType,
      classNumber: classNumber, teacher: teacher, classroom: classroom, info: info);
}

void main() {
  test('courseGroupKey prefers classNumber, falls back to name+teacher', () {
    final withNumber = _course(name: '高等数学', classNumber: 'MATH101', teacher: '张三');
    final withoutNumber = _course(name: '高等数学', classNumber: '', teacher: '张三');

    expect(courseGroupKey(withNumber), 'no:MATH101');
    expect(courseGroupKey(withoutNumber), 'nt:高等数学|张三');
  });

  test('classroom change on same weekday is detected as changedSlots', () {
    final oldList = [
      _course(name: '高等数学', classNumber: 'MATH101', teacher: '张三', classroom: '仙Ⅰ-101'),
    ];
    final newList = [
      _course(name: '高等数学', classNumber: 'MATH101', teacher: '张三', classroom: '仙Ⅰ-202'),
    ];

    final diff = diffCourseLists(oldList, newList);

    expect(diff.addedCourses, isEmpty);
    expect(diff.removedCourses, isEmpty);
    expect(diff.changedSlots.length, 1);
    expect(diff.changedSlots.first.changedFields['classroom']?.key, '仙Ⅰ-101');
    expect(diff.changedSlots.first.changedFields['classroom']?.value, '仙Ⅰ-202');
  });

  test('no changes yields empty diff', () {
    final list = [
      _course(name: '高等数学', classNumber: 'MATH101', teacher: '张三', classroom: '仙Ⅰ-101'),
    ];
    final diff = diffCourseLists(list, List.of(list));
    expect(diff.isEmpty, isTrue);
  });

  test('whole course group added/removed', () {
    final oldList = [
      _course(name: '高等数学', classNumber: 'MATH101', teacher: '张三'),
    ];
    final newList = [
      _course(name: '大学物理', classNumber: 'PHYS101', teacher: '李四'),
    ];

    final diff = diffCourseLists(oldList, newList);

    expect(diff.removedCourses.containsKey('no:MATH101'), isTrue);
    expect(diff.addedCourses.containsKey('no:PHYS101'), isTrue);
    expect(diff.changedSlots, isEmpty);
  });

  test('new time slot added within same course group', () {
    final oldList = [
      _course(name: '高等数学', classNumber: 'MATH101', teacher: '张三', weekTime: 1),
    ];
    final newList = [
      _course(name: '高等数学', classNumber: 'MATH101', teacher: '张三', weekTime: 1),
      _course(name: '高等数学', classNumber: 'MATH101', teacher: '张三', weekTime: 3),
    ];

    final diff = diffCourseLists(oldList, newList);

    expect(diff.addedCourses, isEmpty);
    expect(diff.removedCourses, isEmpty);
    expect(diff.addedSlots.length, 1);
    expect(diff.addedSlots.first.weekTime, 3);
    expect(diff.removedSlots, isEmpty);
  });

  test('time slot removed within same course group', () {
    final oldList = [
      _course(name: '高等数学', classNumber: 'MATH101', teacher: '张三', weekTime: 1),
      _course(name: '高等数学', classNumber: 'MATH101', teacher: '张三', weekTime: 3),
    ];
    final newList = [
      _course(name: '高等数学', classNumber: 'MATH101', teacher: '张三', weekTime: 1),
    ];

    final diff = diffCourseLists(oldList, newList);

    expect(diff.removedSlots.length, 1);
    expect(diff.removedSlots.first.weekTime, 3);
  });

  group('只比对系统导入的课程', () {
    test('手动添加的课不会被判成消失', () {
      // 这是过滤之前的真实 bug：手动加的课在学校数据里当然找不到，
      // 每次更新都会被报成"课程消失"要用户确认。
      final oldList = [
        _course(name: '高等数学', classNumber: 'MATH101', teacher: '张三'),
        _course(name: '社团活动', importType: Constant.ADD_MANUALLY),
      ];
      final newList = [
        _course(name: '高等数学', classNumber: 'MATH101', teacher: '张三'),
      ];

      final diff = diffCourseLists(oldList, newList);

      expect(diff.isEmpty, isTrue, reason: '只有手动添加的课不在学校数据里，不算变化');
    });

    test('讲座添加的课同样不参与比对', () {
      final oldList = [
        _course(name: '某某讲座', importType: Constant.ADD_BY_LECTURE),
      ];

      final diff = diffCourseLists(oldList, const []);

      expect(diff.removedCourses, isEmpty);
      expect(diff.isEmpty, isTrue);
    });

    test('手动添加的课与系统课程同名时，也不会干扰系统课程的比对', () {
      // 同名会落进同一个分组键，过滤没做干净的话会污染时间段配对。
      final oldList = [
        _course(name: '高等数学', teacher: '张三', classroom: '仙Ⅰ-101'),
        _course(
            name: '高等数学',
            teacher: '张三',
            classroom: '我自己记的教室',
            importType: Constant.ADD_MANUALLY),
      ];
      final newList = [
        _course(name: '高等数学', teacher: '张三', classroom: '仙Ⅰ-202'),
      ];

      final diff = diffCourseLists(oldList, newList);

      expect(diff.changedSlots.length, 1);
      expect(diff.changedSlots.first.changedFields['classroom']?.key, '仙Ⅰ-101');
      expect(diff.changedSlots.first.changedFields['classroom']?.value, '仙Ⅰ-202');
      expect(diff.removedSlots, isEmpty, reason: '手动那条不该被算成多出来的时间段');
    });
  });
}
