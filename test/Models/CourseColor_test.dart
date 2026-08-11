import 'package:flutter_test/flutter_test.dart';
import 'package:wheretosleepinnju/Models/CourseModel.dart';
import 'package:wheretosleepinnju/Utils/ColorUtil.dart';

const _palette = ['#AA0000', '#00BB00', '#0000CC', '#DDDD00'];

/// 洗牌顺序取恒等，测试里就能直接按 courseId 推出该拿哪个颜色。
final _pool = ActiveColorPool(const [0, 1, 2, 3], _palette);

Course _course({
  String name = '高等数学',
  String? classNumber,
  String? teacher,
  String? color,
  int? courseId,
}) =>
    Course(1, name, '[1]', 1, 1, 1, 1,
        classNumber: classNumber,
        teacher: teacher,
        color: color,
        courseId: courseId);

void main() {
  group('课程标识', () {
    test('有课程编号时用编号', () {
      expect(_course(classNumber: 'MATH101', teacher: '张三').groupKey,
          'no:MATH101');
    });

    test('没有课程编号时退回 课名 + 教师', () {
      expect(_course(name: '高等数学', teacher: '张三').groupKey, 'nt:高等数学|张三');
    });

    test('课程编号只有空白字符时也算没有', () {
      expect(_course(classNumber: '   ', teacher: '张三').groupKey, 'nt:高等数学|张三');
    });
  });

  group('取色优先级', () {
    test('没有任何指定时按色板分配', () {
      expect(_course(courseId: 2).getColor(_pool), '#0000CC');
    });

    test('课表级映射盖过色板', () {
      final pool = _pool.withTableColors({'no:MATH101': '#123456'});
      final course = _course(classNumber: 'MATH101', courseId: 2);

      expect(course.getColor(pool), '#123456');
      // 色板本来会给的颜色仍然算得出来，写映射时要用它。
      expect(course.paletteColor(pool), '#0000CC');
    });

    test('用户单独指定的颜色盖过课表级映射', () {
      final pool = _pool.withTableColors({'no:MATH101': '#123456'});
      final course =
          _course(classNumber: 'MATH101', courseId: 2, color: '#ABCDEF');

      expect(course.getColor(pool), '#ABCDEF');
    });

    test('映射里的值不是合法颜色时退回色板，不会把脏数据画到课表上', () {
      final pool = _pool.withTableColors({'no:MATH101': '不是颜色'});
      expect(_course(classNumber: 'MATH101', courseId: 1).getColor(pool),
          '#00BB00');
    });

    test('单独指定的颜色不合法时同样退回，且不会误用映射', () {
      final pool = _pool.withTableColors({'no:MATH101': '#123456'});
      final course =
          _course(classNumber: 'MATH101', courseId: 1, color: 'zzz');

      expect(course.getColor(pool), '#123456');
    });

    test('没有井号的十六进制也认，补上井号返回', () {
      expect(_course(courseId: 0, color: 'A1B2C3').getColor(_pool), '#A1B2C3');
    });

    test('映射为空时行为与从前完全一致', () {
      expect(_course(courseId: 1).getColor(_pool), '#00BB00');
    });
  });

  group('写入映射的条目', () {
    test('按课程标识收集色板颜色', () {
      final entries = paletteColorEntries([
        _course(classNumber: 'MATH101', courseId: 1),
        _course(name: '大学英语', teacher: '李四', courseId: 2),
      ], _pool);

      expect(entries, {'no:MATH101': '#00BB00', 'nt:大学英语|李四': '#0000CC'});
    });

    test('同一门课的多个时间段只记一条', () {
      final entries = paletteColorEntries([
        _course(classNumber: 'MATH101', courseId: 1),
        _course(classNumber: 'MATH101', courseId: 1),
      ], _pool);

      expect(entries.length, 1);
    });
  });
}
