import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';

import '../Models/CourseModel.dart';
import '../Models/CourseTableModel.dart';
import '../Resources/NjuConfig.dart';
import '../Utils/ColorUtil.dart';
import '../Utils/CourseDiff.dart';
import '../Utils/CourseImportCodec.dart';
import '../Utils/MissingCourseSweeper.dart';
import '../Utils/NjuEhallJsonImporter.dart';
import '../Utils/SemesterCode.dart';

/// 课表同步的全部业务逻辑：抓取 → 判学期 → 比对 → 覆盖 → 落库。
///
/// **这个文件不允许 import material.dart。** 它要能在没有界面的后台
/// isolate 里跑，一旦引入了 Widget、Toast、Navigator 之类的东西，就等于
/// 又把逻辑绑回了界面上。所有结果通过返回值传出去，怎么呈现由调用方决定：
/// 前台进变更预览页，后台转成一条通知。
///
/// 登录不在这里——服务层接收一个**已经登录好**的 [WebViewController]，
/// 怎么登进去是调用方的事。
///
/// 抽出来的另一个直接收益：导入页的「更新当前课程表」和课表管理的
/// 「检查更新」原先各写了一遍同样的流程，每次改动都要在两处同步，漏一处
/// 就是行为不一致。现在两边调同一份。
class CourseSyncService {
  CourseSyncService({
    CourseProvider? courseProvider,
    CourseTableProvider? tableProvider,
  })  : _courseProvider = courseProvider ?? CourseProvider(),
        _tableProvider = tableProvider ?? CourseTableProvider();

  final CourseProvider _courseProvider;
  final CourseTableProvider _tableProvider;

  // ---------------------------------------------------------------- 抓取

  /// 从已登录的 WebView 里抓一次课表并解析。
  ///
  /// 只解析不写库——调用方拿到结果后自己决定是新建课表还是拿去比对。
  Future<FetchResult> fetch(
    WebViewController controller,
    NjuEntryConfig config,
  ) async {
    final raw = await NjuEhallJsonImporter.fetchCourseTableMap(
      controller,
      pinyin: config.pinyin,
    );
    return FetchResult(
      raw: raw,
      semesterName: (raw['name'] ?? '').toString(),
      semesterCode: (raw['semesterCode'] ?? '').toString(),
      courses: decodeCourses(raw),
    );
  }

  /// `courses` 字段在不同来源下可能是列表、JSON 字符串、甚至被编码了两次
  /// 的字符串，统一在这里剥开。解析不出来就当作空。
  static List<Map<String, dynamic>> decodeCourses(Map<String, dynamic> raw) {
    try {
      Iterable courses;
      final rawCourses = raw['courses'];
      if (rawCourses.runtimeType != String) {
        courses = rawCourses;
      } else if (json.decode(rawCourses).runtimeType != String) {
        courses = json.decode(rawCourses);
      } else {
        courses = json.decode(json.decode(rawCourses));
      }
      return List<Map<String, dynamic>>.from(courses);
    } catch (_) {
      return const [];
    }
  }

  // ------------------------------------------------------------ 新建课表

  /// 用抓到的数据新建一张课表并写入全部课程，返回新表 id。
  ///
  /// 调用方拿到 id 之后需要自己把它设为当前课表（那一步要 BuildContext，
  /// 不属于这里）。
  Future<int> importAsNewTable(
    NjuEntryConfig config,
    FetchResult fetch,
  ) async {
    final table =
        await _tableProvider.insert(CourseTable(fetch.semesterName));
    final tableId = table.id!;

    final inserted = <Course>[];
    for (final courseMap in fetch.courses) {
      final dbMap =
          CourseImportCodec.onlineCourseToDbMap(courseMap, tableId: tableId);
      inserted.add(await _courseProvider.insert(Course.fromMap(dbMap)));
    }
    await _recordCourseColors(tableId, inserted);

    await _tableProvider.updateCheckUpdateInfo(
      tableId,
      sourceSchoolPinyin: config.pinyin,
      semesterCode: fetch.semesterCode,
      lastSnapshot: json.encode(fetch.courses),
      lastCheckedAt: DateTime.now().toIso8601String(),
    );
    return tableId;
  }

  // -------------------------------------------------------------- 比对

  /// 拿抓到的数据跟指定课表比对。
  ///
  /// 会**当场处理**消失的课程（两轮宽限期）并记录本轮检查时间，但新增和
  /// 字段变更只出报告、不落库——那部分要等调用方确认后调 [applyChanges]。
  Future<SyncReport> compareWithTable({
    required NjuEntryConfig config,
    required FetchResult fetch,
    required int tableId,
  }) async {
    // 一门课都没抓到 = 这次抓取失败，不是"全学期停课了"。不拦掉的话每门课
    // 都会被判成消失，两轮下来会全部删光，宽限期防不住这种整体性故障。
    if (fetch.courses.isEmpty) {
      return SyncReport._(outcome: SyncOutcome.emptyFetch, fetch: fetch);
    }

    final table = await _tableProvider.getCourseTable(tableId);
    if (table == null) {
      return SyncReport._(outcome: SyncOutcome.noSuchTable, fetch: fetch);
    }

    final verdict = compareSemesterCode(
      await _tableProvider.getSemesterCode(tableId),
      fetch.semesterCode,
    );
    if (verdict == SemesterVerdict.changed) {
      // 换学期了就不是"更新"而是"换一张表"：逐条比对上学期和这学期的课
      // 没有意义（几乎全是新增 + 消失）。怎么处理由调用方决定——导入页
      // 会新建一张表，检查更新页没有建表能力，只能指路。
      return SyncReport._(outcome: SyncOutcome.semesterChanged, fetch: fetch);
    }

    final newCourses = fetch.courses
        .map((m) => Course.fromMap(
            CourseImportCodec.onlineCourseToDbMap(m, tableId: tableId)))
        .toList();
    final oldCourses = (await _courseProvider.getAllCourses(tableId))
        .map((m) => Course.fromMap(Map<String, dynamic>.from(m)))
        .toList();

    final diff = diffCourseLists(oldCourses, newCourses);
    final sweep = await sweepMissingCourses(
      provider: _courseProvider,
      oldCourses: oldCourses,
      diff: diff,
    );

    await _tableProvider.updateCheckUpdateInfo(
      tableId,
      sourceSchoolPinyin: config.pinyin,
      semesterCode: fetch.semesterCode,
      lastSnapshot: json.encode(fetch.courses),
      lastCheckedAt: DateTime.now().toIso8601String(),
    );

    return SyncReport._(
      outcome: SyncOutcome.ok,
      fetch: fetch,
      tableId: tableId,
      diff: diff,
      sweep: sweep,
    );
  }

  /// 把报告里的新增与字段变更落库。消失的课程在 [compareWithTable] 里
  /// 已经处理过了，这里不再涉及。
  Future<void> applyChanges(SyncReport report) async {
    final diff = report.diff;
    final tableId = report.tableId;
    if (diff == null || tableId == null) return;

    for (final change in diff.changedSlots) {
      final updated = change.oldSlot;
      updated.classroom = change.newSlot.classroom;
      updated.info = change.newSlot.info;
      updated.weekTime = change.newSlot.weekTime;
      updated.startTime = change.newSlot.startTime;
      updated.timeCount = change.newSlot.timeCount;
      updated.weeks = change.newSlot.weeks;
      await _courseProvider.update(updated);
    }

    final inserted = <Course>[];
    for (final slot in diff.addedSlots) {
      slot.tableId = tableId;
      inserted.add(await _courseProvider.insert(slot));
    }
    for (final group in diff.addedCourses.values) {
      for (final slot in group) {
        slot.tableId = tableId;
        inserted.add(await _courseProvider.insert(slot));
      }
    }
    await _recordCourseColors(tableId, inserted);
  }

  /// 把新写进来的课程按色板算出的颜色固定到课表级映射里。已经记过的不覆盖，
  /// 所以同一门课在后续更新中被删掉又加回来时颜色不变。
  Future<void> _recordCourseColors(int tableId, List<Course> courses) async {
    if (courses.isEmpty) return;
    final pool = await ColorPool.getActivePool();
    await _tableProvider.mergeCourseColors(
        tableId, paletteColorEntries(courses, pool));
  }
}

/// 一次抓取的结果，还没碰数据库。
class FetchResult {
  const FetchResult({
    required this.raw,
    required this.semesterName,
    required this.semesterCode,
    required this.courses,
  });

  /// 原始返回，抓到 0 门课时要摊给用户看，用来区分"抓取失败"和"确实没课"。
  final Map<String, dynamic> raw;
  final String semesterName;
  final String semesterCode;
  final List<Map<String, dynamic>> courses;

  int get courseCount => courses.length;

  /// 能报出学期信息就说明登录成功、接口通了、解析也没问题。
  bool get hasSemesterInfo =>
      semesterName.isNotEmpty || semesterCode.isNotEmpty;
}

enum SyncOutcome {
  /// 正常完成比对，[SyncReport.diff] 和 [SyncReport.sweep] 有效。
  ok,

  /// 一门课都没抓到，判定为抓取失败，未做任何改动。
  emptyFetch,

  /// 学期变了，不该在这张表上做增量更新。
  semesterChanged,

  /// 要比对的课表不存在。
  noSuchTable,
}

class SyncReport {
  const SyncReport._({
    required this.outcome,
    required this.fetch,
    this.tableId,
    this.diff,
    this.sweep,
  });

  final SyncOutcome outcome;
  final FetchResult fetch;
  final int? tableId;
  final CourseDiffResult? diff;
  final MissingSweepResult? sweep;

  /// 这一轮有没有需要用户确认的新增或变更。
  bool get hasPendingChanges => !(diff?.isEmpty ?? true);
}
