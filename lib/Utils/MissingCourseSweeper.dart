import '../Models/CourseModel.dart';
import 'CourseDiff.dart';

/// 连续多少轮没抓到就彻底删除。
///
/// 定成 2 是因为「这门课这次没抓到」有两种可能：用户真的退课了，或者
/// 这一次抓漏了（网络抖动、接口返回不全）。数据上无法区分，所以把
/// 「眼不见」和「真删除」拆开——课表上立刻干净，数据要连续两次确认。
const int kMissingRoundsBeforeDelete = 2;

class MissingSweepResult {
  /// 这一轮新标记、已从课表上隐藏但数据还留着的条数。
  final int hidden;

  /// 累计到上限、这一轮被彻底删除的条数。
  final int deleted;

  /// 之前标记过、这一轮又抓到了因而恢复显示的条数。
  final int restored;

  const MissingSweepResult(
      {this.hidden = 0, this.deleted = 0, this.restored = 0});

  bool get isEmpty => hidden == 0 && deleted == 0 && restored == 0;

  /// 给用户看的一句话。返回 null 表示这轮没有任何值得打扰用户的变化。
  String? get summary {
    final parts = <String>[];
    if (restored > 0) parts.add('$restored 门课重新出现，已恢复显示');
    if (hidden > 0) parts.add('$hidden 门课在学校数据里没找到，已暂时隐藏');
    if (deleted > 0) parts.add('$deleted 门课连续两次没找到，已删除');
    return parts.isEmpty ? null : parts.join('；');
  }
}

/// 按两轮宽限期处理「学校数据里不见了」的课程。
///
/// [oldCourses] 是比对前这张表里的全部课程（含手动添加的，本函数自己会
/// 过滤）；[diff] 是这一轮的比对结果。抓取失败（一门课都没抓到）的情况
/// 请由调用方在调用本函数之前就拦掉——那种情况下所有课都会被判成消失，
/// 两轮下来会全部删光，宽限期防不住。
Future<MissingSweepResult> sweepMissingCourses({
  required CourseProvider provider,
  required List<Course> oldCourses,
  required CourseDiffResult diff,
}) async {
  final missing = <Course>[
    for (final group in diff.removedCourses.values) ...group,
    ...diff.removedSlots,
  ];
  final missingIds = missing.map((c) => c.id).whereType<int>().toSet();

  var hidden = 0;
  var deleted = 0;
  var restored = 0;

  for (final course in missing) {
    if (course.id == null) continue;
    final rounds = course.missingRounds + 1;
    if (rounds >= kMissingRoundsBeforeDelete) {
      await provider.delete(course.id!);
      deleted++;
    } else {
      course.missingRounds = rounds;
      await provider.update(course);
      hidden++;
    }
  }

  // 这轮抓到了的课里，之前被标记过的要恢复。数据一直还在，所以恢复之后
  // 行号、颜色、用户单独设过的颜色都跟原来一样。
  for (final course in oldCourses) {
    if (course.id == null || missingIds.contains(course.id)) continue;
    if (course.missingRounds == 0) continue;
    course.missingRounds = 0;
    await provider.update(course);
    restored++;
  }

  return MissingSweepResult(
      hidden: hidden, deleted: deleted, restored: restored);
}
