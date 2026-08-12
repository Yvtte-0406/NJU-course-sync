import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheretosleepinnju/Services/CourseSyncService.dart';

void main() {
  group('服务层不能依赖界面', () {
    // 这是整个重构的核心约束：CourseSyncService 要能在没有界面的后台
    // isolate 里跑。写在注释里靠不住，用测试钉死——有人图省事 import 了
    // material 或者塞进来一个 BuildContext 参数，这里会立刻红。
    test('源文件里没有任何界面相关的 import', () {
      final source =
          File('lib/Services/CourseSyncService.dart').readAsStringSync();
      final imports = source
          .split('\n')
          .where((line) => line.trimLeft().startsWith('import '))
          .toList();

      expect(imports, isNotEmpty, reason: '读不到源文件说明测试的路径假设错了');
      for (final line in imports) {
        expect(line, isNot(contains('material.dart')));
        expect(line, isNot(contains('widgets.dart')));
        expect(line, isNot(contains('cupertino.dart')));
        expect(line, isNot(contains('Components/')),
            reason: 'Components 下都是 Widget');
        expect(line, isNot(contains('Pages/')), reason: '服务层不该反向依赖页面');
      }
    });
  });

  group('抓取结果解析', () {
    test('courses 是列表时直接用', () {
      final courses = CourseSyncService.decodeCourses({
        'courses': [
          {'name': '高等数学'}
        ]
      });
      expect(courses.length, 1);
      expect(courses.first['name'], '高等数学');
    });

    test('courses 是 JSON 字符串时剥一层', () {
      final courses = CourseSyncService.decodeCourses({
        'courses': '[{"name":"高等数学"}]',
      });
      expect(courses.length, 1);
      expect(courses.first['name'], '高等数学');
    });

    test('courses 被编码了两次时剥两层', () {
      final courses = CourseSyncService.decodeCourses({
        'courses': '"[{\\"name\\":\\"高等数学\\"}]"',
      });
      expect(courses.length, 1);
      expect(courses.first['name'], '高等数学');
    });

    test('解析不出来时返回空而不是抛异常', () {
      // 抓取侧返回了预期之外的东西，不该让整个导入流程崩掉。
      expect(CourseSyncService.decodeCourses({'courses': null}), isEmpty);
      expect(CourseSyncService.decodeCourses({'courses': '不是 JSON'}), isEmpty);
      expect(CourseSyncService.decodeCourses(const {}), isEmpty);
    });
  });

  group('FetchResult', () {
    FetchResult make({String name = '', String code = ''}) => FetchResult(
          raw: const {},
          semesterName: name,
          semesterCode: code,
          courses: const [],
        );

    test('学期名称和代码有其一就算读到了学期信息', () {
      // 这个判断决定空结果页说"登录成功了只是没课"还是"可能登录出问题了"。
      expect(make(name: '2025-2026学年第一学期').hasSemesterInfo, isTrue);
      expect(make(code: '2025-2026-1').hasSemesterInfo, isTrue);
      expect(make().hasSemesterInfo, isFalse);
    });

    test('课程数取自解析后的列表', () {
      expect(
        const FetchResult(
          raw: {},
          semesterName: '',
          semesterCode: '',
          courses: [{}, {}],
        ).courseCount,
        2,
      );
    });
  });
}
