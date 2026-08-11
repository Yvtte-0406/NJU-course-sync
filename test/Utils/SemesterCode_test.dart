import 'package:flutter_test/flutter_test.dart';
import 'package:wheretosleepinnju/Utils/SemesterCode.dart';

/// 这条规则决定一次更新是"增量"还是"换学期新建表"，判错的代价是把用户
/// 手动添加的课当成上学期的清掉，所以边界都要钉住。
void main() {
  test('代码一致 = 同学期', () {
    expect(compareSemesterCode('2025-2026-1', '2025-2026-1'),
        SemesterVerdict.same);
  });

  test('代码不一致 = 换学期', () {
    expect(compareSemesterCode('2025-2026-1', '2025-2026-2'),
        SemesterVerdict.changed);
  });

  test('本地没存过 = 认不出，按同学期处理并补写', () {
    expect(compareSemesterCode(null, '2025-2026-1'), SemesterVerdict.unknown);
    expect(compareSemesterCode('', '2025-2026-1'), SemesterVerdict.unknown);
  });

  test('这次没抓到学期代码时，宁可漏判也不误判为换学期', () {
    // 抓取侧少给一个字段就把人家手动添加的数据清掉，代价太大。
    expect(compareSemesterCode('2025-2026-1', ''), SemesterVerdict.same);
  });

  test('两边都缺时按认不出处理，不会误判成换学期', () {
    expect(compareSemesterCode(null, ''), SemesterVerdict.unknown);
  });
}
