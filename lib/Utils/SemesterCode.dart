/// 判断"这次抓到的数据和这张课表是不是同一个学期"。
///
/// 抽成纯函数是因为有两个入口都要做这件事——导入页的「更新当前课程表」
/// 和课表管理里每张表的「检查更新」——规则写两遍迟早会走样。两边拿到
/// 同一个判定结果后再各自决定怎么处理（前者新建课表，后者提示去导入页）。
enum SemesterVerdict {
  /// 同一个学期，照常做增量更新。
  same,

  /// 换学期了，不该在这张表上做"更新"。
  changed,

  /// 认不出来：这张表建于"学期代码"这个字段存在之前，本地没存过。
  /// 按同学期处理（保守，不会误清手动数据），同时把代码补写进去，
  /// 下次就有依据了。
  unknown,
}

/// [stored] 是课表里存的学期代码，没存过传 null；[fetched] 是这次抓到的。
///
/// 抓到的代码为空时一律返回 [SemesterVerdict.same]：宁可漏判一次换学期
/// （最坏是用户手动重新导入一下），也不能因为抓取侧少给一个字段就把人家
/// 手动添加的数据当成上学期的清掉。
SemesterVerdict compareSemesterCode(String? stored, String fetched) {
  if (stored == null || stored.isEmpty) return SemesterVerdict.unknown;
  if (fetched.isEmpty) return SemesterVerdict.same;
  return fetched == stored ? SemesterVerdict.same : SemesterVerdict.changed;
}
