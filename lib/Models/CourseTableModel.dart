import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import '../Resources/Constant.dart';
import './CourseModel.dart';
import './Db/DbHelper.dart';

const String tableName = DbHelper.COURSETABLE_TABLE_NAME;
const String columnId = DbHelper.COURSETABLE_COLUMN_ID;
const String columnName = DbHelper.COURSETABLE_COLUMN_NAME;
const String columnData = DbHelper.COURSETABLE_COLUMN_DATA;

class CourseTable {
  int? id;
  String? name;
  String? data;

//  CourseTable(id, name){
//    this.id = id;
//    this.name = name;
//  };
  CourseTable(this.name, {this.data = ''});

  Map<String, dynamic> toMap() {
    var map = <String, dynamic>{
      columnName: name,
      columnData: data,
    };
    if (id != null) {
      map[columnId] = id;
      map[columnData] = data;
    }
    return map;
  }

  CourseTable.fromMap(Map<String, dynamic> map) {
    id = map[columnId];
    name = map[columnName];
    data = map[columnData];
  }
}

class CourseTableProvider {
  Database? db;
  DbHelper dbHelper = DbHelper();

  Future open() async {
    db = await dbHelper.open();
  }

  Future close() async => db!.close();

  Future<CourseTable> insert(CourseTable courseTable) async {
    await open();
    courseTable.id = await db!.insert(tableName, courseTable.toMap());
//    await close();
    return courseTable;
  }

  Future<CourseTable?> getCourseTable(int id) async {
    await open();
    List<Map<String, dynamic>> maps = await db!.query(tableName,
        columns: [columnId, columnName, columnData],
        where: '$columnId = ?',
        whereArgs: [id]);
    if (maps.isNotEmpty) {
      return CourseTable.fromMap(maps.first);
    }
//    await close();
    return null;
  }

  Future<List> getAllCourseTable() async {
    await open();
    List<Map> rst = await db!.query(tableName, columns: [columnId, columnName]);
//    await close();
    return rst.toList();
  }

  Future<List<Map>> getClassTimeList(int id) async {
    await open();
    List<Map> defaultClassTimeList = Constant.CLASS_TIME_LIST;

    List<Map<String, dynamic>> maps = await db!.query(tableName,
        columns: [columnId, columnName, columnData],
        where: '$columnId = ?',
        whereArgs: [id]);
    if (maps.isEmpty || maps[0]["data"] == null) {
      return defaultClassTimeList;
    }
    // print(maps);
    try {
      Map rst = json.decode(maps[0]["data"]);
      if (rst["class_time_list"] == null) {
        return defaultClassTimeList;
      }
      // print(rst["class_time_list"]);
      return List<Map>.from(rst["class_time_list"]);
    } catch (e) {
      // print(e);
      return defaultClassTimeList;
    }
  }

  Future<String> getSemesterStartMonday(int id) async {
    await open();
    List<Map<String, dynamic>> maps = await db!.query(tableName,
        columns: [columnId, columnName, columnData],
        where: '$columnId = ?',
        whereArgs: [id]);
    if (maps.isEmpty || maps[0]["data"] == null || maps[0]["data"] == "") {
      return "";
    }
    try {
      Map rst = json.decode(maps[0]["data"]);
      if (rst["semester_start_monday"] == null) {
        return "";
      }
      return rst["semester_start_monday"];
    } catch (e) {
      // print(e);
      return "";
    }
  }

  /// 读取 `data` JSON blob 中除 class_time_list/semester_start_monday 之外
  /// 用于"检查更新"功能的字段：last_snapshot（上次抓取的原始 courses JSON）、
  /// last_checked_at、source_school_pinyin（对应 schoolList.json 里的学校配置）。
  Future<Map<String, dynamic>> _getDataMap(int id) async {
    await open();
    List<Map<String, dynamic>> maps = await db!.query(tableName,
        columns: [columnId, columnData], where: '$columnId = ?', whereArgs: [id]);
    if (maps.isEmpty || maps[0][columnData] == null || maps[0][columnData] == '') {
      return {};
    }
    try {
      final decoded = json.decode(maps[0][columnData]);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return {};
    } catch (e) {
      return {};
    }
  }

  /// 把新字段合并进现有的 data JSON blob 里，不覆盖 class_time_list 等已有字段。
  Future<void> updateCheckUpdateInfo(
    int id, {
    String? lastSnapshot,
    String? lastCheckedAt,
    String? sourceSchoolPinyin,
    String? semesterCode,
  }) async {
    final data = await _getDataMap(id);
    if (lastSnapshot != null) data['last_snapshot'] = lastSnapshot;
    if (lastCheckedAt != null) data['last_checked_at'] = lastCheckedAt;
    if (sourceSchoolPinyin != null) {
      data['source_school_pinyin'] = sourceSchoolPinyin;
    }
    if (semesterCode != null && semesterCode.isNotEmpty) {
      data['semester_code'] = semesterCode;
    }
    await open();
    await db!.update(tableName, {columnData: json.encode(data)},
        where: '$columnId = ?', whereArgs: [id]);
  }

  /// 这张课表记下来的"课程 → 颜色"映射，键是 [Course.groupKey]。
  /// 没记过就是空 Map，此时取色行为跟从前完全一致。
  Future<Map<String, String>> getCourseColors(int id) async {
    final data = await _getDataMap(id);
    final raw = data['course_colors'];
    if (raw is! Map) return <String, String>{};
    final result = <String, String>{};
    raw.forEach((k, v) {
      final key = k?.toString();
      final value = v?.toString();
      if (key != null && key.isNotEmpty && value != null && value.isNotEmpty) {
        result[key] = value;
      }
    });
    return result;
  }

  /// 只补充还没记过的课程，已经记下的不覆盖——固定下来的颜色就不该再变，
  /// 这正是这张映射存在的意义。返回是否真的写入了新条目。
  Future<bool> mergeCourseColors(int id, Map<String, String> entries) async {
    if (entries.isEmpty) return false;
    final data = await _getDataMap(id);
    final existing = <String, String>{};
    final raw = data['course_colors'];
    if (raw is Map) {
      raw.forEach((k, v) {
        if (k != null && v != null) existing[k.toString()] = v.toString();
      });
    }
    var changed = false;
    entries.forEach((key, value) {
      if (key.isEmpty || value.isEmpty) return;
      if (existing.containsKey(key)) return;
      existing[key] = value;
      changed = true;
    });
    if (!changed) return false;
    data['course_colors'] = existing;
    await open();
    await db!.update(tableName, {columnData: json.encode(data)},
        where: '$columnId = ?', whereArgs: [id]);
    return true;
  }

  /// 清掉整张配色映射。切换配色方案时必须调用——否则映射会一直把课程钉在
  /// 旧方案的颜色上，用户换了方案却看不到任何变化。
  Future<void> clearCourseColors(int id) async {
    final data = await _getDataMap(id);
    if (!data.containsKey('course_colors')) return;
    data.remove('course_colors');
    await open();
    await db!.update(tableName, {columnData: json.encode(data)},
        where: '$columnId = ?', whereArgs: [id]);
  }

  /// 这张课表是哪个学期的（学校系统给的学期代码）。空字符串和 null 一律
  /// 返回 null——课表建于这个字段存在之前时就是这种情况，调用方按"认不出
  /// 学期"处理。
  Future<String?> getSemesterCode(int id) async {
    final data = await _getDataMap(id);
    final v = data['semester_code']?.toString();
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<String?> getSourceSchoolPinyin(int id) async {
    final data = await _getDataMap(id);
    final v = data['source_school_pinyin'];
    return v == null ? null : v.toString();
  }

  Future<String?> getLastSnapshot(int id) async {
    final data = await _getDataMap(id);
    final v = data['last_snapshot'];
    return v == null ? null : v.toString();
  }

  Future<String?> getLastCheckedAt(int id) async {
    final data = await _getDataMap(id);
    final v = data['last_checked_at'];
    return v == null ? null : v.toString();
  }

  Future<int> delete(int id) async {
    await open();
    CourseProvider courseProvider = CourseProvider();
    await courseProvider.deleteByTable(id);
    int rst =
        await db!.delete(tableName, where: '$columnId = ?', whereArgs: [id]);
//    await close();
    return rst;
  }

  Future<int> update(CourseTable courseTable) async {
    await open();
    int rst = await db!.update(tableName, courseTable.toMap(),
        where: '$columnId = ?', whereArgs: [courseTable.id]);
//    await close();
    return rst;
  }
}
