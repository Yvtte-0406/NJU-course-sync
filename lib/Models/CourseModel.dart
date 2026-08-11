import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import '../Utils/ColorUtil.dart';
import './Db/DbHelper.dart';

const String tableName = DbHelper.COURSE_TABLE_NAME;
const String columnId = DbHelper.COURSE_COLUMN_ID;
const String columnName = DbHelper.COURSE_COLUMN_NAME;
const String columnTableId = DbHelper.COURSE_COLUMN_COURSETABLEID;
const String columnClassroom = DbHelper.COURSE_COLUMN_CLASS_ROOM;
const String columnClassNumber = DbHelper.COURSE_COLUMN_CLASS_NUMBER;
const String columnTeacher = DbHelper.COURSE_COLUMN_TEACHER;
const String columnTestTime = DbHelper.COURSE_COLUMN_TEST_TIME;
const String columnTestLocation = DbHelper.COURSE_COLUMN_TEST_LOCATION;
const String columnLink = DbHelper.COURSE_COLUMN_INFO_LINK;
const String columnInfo = DbHelper.COURSE_COLUMN_INFO;
const String columnWeeks = DbHelper.COURSE_COLUMN_WEEKS;
const String columnWeekTime = DbHelper.COURSE_COLUMN_WEEK_TIME;
const String columnStartTime = DbHelper.COURSE_COLUMN_START_TIME;
const String columnTimeCount = DbHelper.COURSE_COLUMN_TIME_COUNT;
const String columnImportType = DbHelper.COURSE_COLUMN_IMPORT_TYPE;
const String columnColor = DbHelper.COURSE_COLUMN_COLOR;
const String columnCourseId = DbHelper.COURSE_COLUMN_COURSE_ID;
const String columnData = DbHelper.COURSE_COLUMN_DATA;

class Course {
  int? id;
  String? name;
  int? tableId;

  String? classroom;
  String? classNumber;
  String? teacher;
  String? testTime;
  String? testLocation;
  String? link;
  String? info;

  String? weeks; //哪些周会上这个课
  int? weekTime; //星期几
  int? startTime;
  int? timeCount;
  int? importType;
  String? color;
  int? courseId;

  /// 这一行自己的附加状态，存 JSON。目前只用来记「连续多少轮没在学校数据
  /// 里抓到」。这个列建表时就有、v2 升级也补过，但一直没被读写过——拿它
  /// 存这个状态，省掉一次数据库迁移。
  String? data;

  Course(this.tableId, this.name, this.weeks, this.weekTime, this.startTime,
      this.timeCount, this.importType,
      {this.id,
      this.classroom,
      this.classNumber,
      this.teacher,
      this.testTime,
      this.testLocation,
      this.link,
      this.color,
      this.courseId,
      this.data,
      this.info});

  Map<String, dynamic> toMap() {
    var map = <String, dynamic>{
      columnId: id,
      columnName: name,
      columnTableId: tableId,
      columnWeeks: weeks,
      columnWeekTime: weekTime,
      columnStartTime: startTime,
      columnTimeCount: timeCount,
      columnImportType: importType,
      columnColor: color,
      columnClassroom: classroom,
      columnClassNumber: classNumber,
      columnTeacher: teacher,
      columnTestTime: testTime,
      columnTestLocation: testLocation,
      columnLink: link,
      columnCourseId: courseId,
      columnInfo: info,
      columnData: data,
    };
    return map;
  }

  Course.fromMap(Map<String, dynamic> map) {
    id = map[columnId];
    name = map[columnName];
    tableId = map[columnTableId];

    classroom = map[columnClassroom];
    classNumber = map[columnClassNumber];
    teacher = map[columnTeacher];
    testTime = map[columnTestTime];
    testLocation = map[columnTestLocation];
    link = map[columnLink];
    info = map[columnInfo];

    weeks = map[columnWeeks].toString();
    weekTime = map[columnWeekTime];
    startTime = map[columnStartTime];
    timeCount = map[columnTimeCount];
    importType = map[columnImportType];
    color = map[columnColor];
    courseId = map[columnCourseId];
    data = map[columnData];
  }

  /// 连续多少轮没在学校数据里抓到。0 表示这门课这次抓到了（或从没缺过）。
  ///
  /// 大于 0 的课不在课表上显示——但数据还留着，万一只是这一次抓漏了，
  /// 下轮抓到就能原样恢复，连颜色都不会变（颜色跟的是 [groupKey]）。
  int get missingRounds {
    final raw = _dataMap['missing_rounds'];
    if (raw is int) return raw < 0 ? 0 : raw;
    return int.tryParse(raw?.toString() ?? '')?.clamp(0, 1 << 30) ?? 0;
  }

  set missingRounds(int value) {
    final map = _dataMap;
    if (value <= 0) {
      map.remove('missing_rounds');
      map.remove('missing_since');
    } else {
      map['missing_rounds'] = value;
      map.putIfAbsent(
          'missing_since', () => DateTime.now().toIso8601String());
    }
    data = map.isEmpty ? null : json.encode(map);
  }

  Map<String, dynamic> get _dataMap {
    final raw = data;
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = json.decode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      // 存了非 JSON 的历史脏数据：当成空的，别让它把整张课表带崩。
      return <String, dynamic>{};
    }
  }

  /// "这是同一门课"的稳定标识：优先用课程编号，缺失时退回 课程名 + 教师。
  ///
  /// 比对引擎判断"新旧两条是不是同一门课"，以及课表级配色映射记录"这门课
  /// 用哪个颜色"，用的都是这一个标识——两处必须一致，否则更新一轮之后
  /// 颜色就对不上了。
  String get groupKey {
    final number = classNumber?.trim() ?? '';
    if (number.isNotEmpty) return 'no:$number';
    return 'nt:${name ?? ''}|${teacher ?? ''}';
  }

  /// 取色优先级：用户给这门课单独指定的颜色 → 课表级配色映射 → 色板按序分配。
  ///
  /// 中间那层映射是为了让颜色跟着"课程"而不是跟着"数据库行"走：一门课
  /// 如果在某轮更新里被删掉又加回来，行号和 [courseId] 都会变，但只要
  /// [groupKey] 没变，颜色就还是原来那个。
  String? getColor(ActiveColorPool pool) {
    final explicit = _normalizeHex(color);
    if (explicit != null) return explicit;

    final mapped = _normalizeHex(pool.tableColors[groupKey]);
    if (mapped != null) return mapped;

    return paletteColor(pool);
  }

  /// 纯按色板算出来的颜色，不看单独指定的颜色、也不看映射。写入配色映射
  /// 时用它——映射里要存的就是"色板本来会给它什么颜色"。
  String paletteColor(ActiveColorPool pool) {
    if (courseId == null || pool.indices.isEmpty || pool.palette.isEmpty) {
      return pool.palette.isNotEmpty ? pool.palette.first : '#8AD297';
    }
    return pool.palette[pool.indices[courseId! % pool.indices.length]];
  }

  static String? _normalizeHex(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return null;
    final body = value.startsWith('#') ? value.substring(1) : value;
    if (!RegExp(r'^[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$').hasMatch(body)) {
      return null;
    }
    return '#$body';
  }
}

/// 收集这批课程"按色板本来会分到的颜色"，用于写入课表级配色映射。
///
/// 必须在课程写库之后调用：[Course.paletteColor] 依赖 [Course.courseId]，
/// 而这个字段是 [CourseProvider.insert] 里补上的。
Map<String, String> paletteColorEntries(
    List<Course> courses, ActiveColorPool pool) {
  final entries = <String, String>{};
  for (final course in courses) {
    final key = course.groupKey;
    if (key.isEmpty) continue;
    entries.putIfAbsent(key, () => course.paletteColor(pool));
  }
  return entries;
}

class CourseProvider {
  Database? db;
  DbHelper dbHelper = DbHelper();

  Future open() async {
    db = await dbHelper.open();
  }

  Future close() async => db!.close();

  Future<Course> insert(Course course) async {
    await open();
    course.courseId ??= await getCourseId(course);
//    print(course.toMap());
    course.id = await db!.insert(tableName, course.toMap());
//    await close();
    return course;
  }

  Future<Course?> getCourse(int id) async {
    await open();
    List<Map<String, dynamic>> maps = await db!.query(tableName,
        columns: [columnId, columnName],
        where: '$columnId = ?',
        whereArgs: [id]);
//    await close();
    if (maps.isNotEmpty) {
      return Course.fromMap(maps.first);
    }
    return null;
  }

  Future<List> getAllCourses(int tableId) async {
    await open();
    List<Map> rst = await db!.query(tableName,
//        columns: [columnId, columnName],
        where: '$columnTableId = ?',
        whereArgs: [tableId]);
//    await close();
    return rst.toList();
  }

  Future<int> getCourseNum() async {
    await open();
    List<Map> rst = await db!.query(tableName);
    return rst.length;
  }

  Future<int> delete(int id) async {
    await open();
    int rst =
        await db!.delete(tableName, where: '$columnId = ?', whereArgs: [id]);
//    await close();
    return rst;
  }

  Future<int> deleteByTable(int id) async {
    await open();
    int rst = await db!
        .delete(tableName, where: '$columnTableId = ?', whereArgs: [id]);
//    await close();
    return rst;
  }

  Future<int> update(Course course) async {
    await open();
    int rst = await db!.update(tableName, course.toMap(),
        where: '$columnId = ?', whereArgs: [course.id]);
//    await close();
    return rst;
  }

  Future<bool> checkHasClassByName(int tableId, String name) async {
    await open();
    List<Map> rst = await db!.query(tableName,
        where: '$columnTableId = ? and $columnName = ?',
        whereArgs: [tableId, name]);
    return rst.isNotEmpty;
  }

  //获取课程 courseid，如果存在已有课程则为已有课程，否则指定新id
  Future<int> getCourseId(Course course) async {
    List<Map> rst = await db!.query(tableName,
        where: '$columnName = ? and $columnTableId = ?',
        whereArgs: [course.name, course.tableId]);
    if (rst.isNotEmpty) return rst[0][columnCourseId];
    var maxId =
        await db!.rawQuery('SELECT MAX($columnCourseId) FROM $tableName');
    List maxIdList = maxId.toList();
//    print(maxIdList);
    if (maxIdList.isEmpty || maxIdList[0]['MAX($columnCourseId)'] == null) {
      return 0;
    } else {
      return maxIdList[0]['MAX($columnCourseId)'] + 1;
    }
  }
}
