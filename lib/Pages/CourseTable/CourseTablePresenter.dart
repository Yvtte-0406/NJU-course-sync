import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_swiper_null_safety_flutter3/flutter_swiper_null_safety_flutter3.dart';
import 'package:umeng_common_sdk/umeng_common_sdk.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:scoped_model/scoped_model.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../Models/CourseTableModel.dart';
import '../../generated/l10n.dart';
import '../../Models/CourseModel.dart';
import '../../Models/ScheduleModel.dart';
import '../../Resources/Config.dart';
import '../../Resources/Url.dart';
import '../../Utils/States/MainState.dart';
import '../../Utils/ColorUtil.dart';
import '../../Utils/WeekUtil.dart';
import '../../Components/Dialog.dart';
import '../../Components/Toast.dart';
import '../../Components/TransBgTextButton.dart';

import 'Widgets/CourseDetailDialog.dart';
import 'Widgets/HideFreeCourseDialog.dart';
import 'Widgets/CourseDeleteDialog.dart';
import 'Widgets/CourseWidget.dart';

/// 同一格子里最多并排显示几门重叠课程。超过这个数就不再平分了——分成
/// 三列每块窄到看不清课名，不如只显示一门并占满整格，剩下的折叠成角标
/// 让用户点开翻。
const int _kMaxSideBySide = 2;

class CourseTablePresenter {
  CourseProvider courseProvider = CourseProvider();
  CourseTableProvider courseTableProvider = CourseTableProvider();
  List<Course> activeCourses = [];
  List<Course> hideCourses = [];
  List<List<Course>> multiCourses = [];
  List<Course> freeCourses = [];

  /// 取色要用到这张表自己的配色映射，[refreshClasses] 时记下来。
  int _tableId = 0;

  refreshClasses(int tableId, int nowWeek) async {
    _tableId = tableId;
    List allCoursesMap = await courseProvider.getAllCourses(tableId);
    List<Course> allCourses = [];
    for (Map<String, dynamic> courseMap in allCoursesMap) {
      allCourses.add(Course.fromMap(courseMap));
    }
    ScheduleModel scheduleModel = ScheduleModel(allCourses, nowWeek);
    scheduleModel.init();

    activeCourses = scheduleModel.activeCourses;
    hideCourses = scheduleModel.hideCourses;
    multiCourses = scheduleModel.multiCourses;
    freeCourses = scheduleModel.freeCourses;
  }

  Future<List<Widget>?> getClassesWidgetList(
      BuildContext context,
      double height,
      double width,
      int nowWeek,
      bool showNonCurrentWeekCourses) async {
    ActiveColorPool colorPool = (await ColorPool.getActivePool())
        .withTableColors(await courseTableProvider.getCourseColors(_tableId));
    String mutedColor = await ColorPool.getEffectiveMutedColor();

    // Filter hideCourses based on setting
    List<Course> filteredHideCourses =
        showNonCurrentWeekCourses ? hideCourses : [];

    List<Widget> result = List.generate(
            filteredHideCourses.length,
            (int i) => CourseWidget(
                  filteredHideCourses[i],
                  filteredHideCourses[i].getColor(colorPool)!,
                  mutedColor,
                  height,
                  width,
                  false,
                  false,
                  () => showClassDialog(context, filteredHideCourses[i], false),
                  () => showDeleteDialog(
                    context,
                    filteredHideCourses[i],
                  ),
                )) +
        List.generate(
            activeCourses.length,
            (int i) => CourseWidget(
                  activeCourses[i],
                  activeCourses[i].getColor(colorPool)!,
                  mutedColor,
                  height,
                  width,
                  true,
                  false,
                  () => showClassDialog(context, activeCourses[i], true),
                  () => showDeleteDialog(context, activeCourses[i]),
                ));

    // 撞在同一格里的课怎么显示：
    // - 两门：左右平分格子并排，各点各的详情。
    // - 三门及以上：平分只会窄到看不清课名，所以只显示排在最前面那门、
    //   占满整格，右上角画 "+N" 角标，点它翻看整组。
    for (int groupIndex = 0; groupIndex < multiCourses.length; groupIndex++) {
      final List<Course> group = multiCourses[groupIndex];
      // 关掉"显示非本周课程"时，组里的灰显成员也不该露出来——不然用户
      // 明明关了这个开关，重叠的格子里反而还看得见它们。只剩一门要显示
      // 的话 slotCount 就是 1，照常占满整格，不会莫名其妙留半格空白。
      final List<Course> shown = showNonCurrentWeekCourses
          ? group
          : group.where((c) => isThisWeek(c, nowWeek)).toList();
      if (shown.isEmpty) continue;
      final int visibleCount =
          shown.length > _kMaxSideBySide ? 1 : shown.length;
      final int hiddenCount = shown.length - visibleCount;
      for (int slot = 0; slot < visibleCount; slot++) {
        final Course course = shown[slot];
        final bool isActive = isThisWeek(course, nowWeek);
        final bool isOverflowSlot = slot == visibleCount - 1 && hiddenCount > 0;
        result.add(CourseWidget(
          course,
          course.getColor(colorPool)!,
          mutedColor,
          height,
          width,
          isActive,
          false,
          isOverflowSlot
              ? () => showMultiClassDialog(context, groupIndex, nowWeek)
              : () => showClassDialog(context, course, isActive),
          () => showDeleteDialog(context, course),
          slotIndex: slot,
          slotCount: visibleCount,
          hiddenCount: isOverflowSlot ? hiddenCount : 0,
        ));
      }
    }
    return result;
  }

  Future<bool> showAfterImport(BuildContext context) async {
    if (!await _shouldShowDonate()) {
      return true;
    }
    Dio dio = Dio();
    String url = Url.UPDATE_ROOT + '/complete.json';
    Response response = await dio.get(url);
    String welcomeTitle = '';
    String welcomeContent = '';
    int delaySeconds = Config.DONATE_DIALOG_DELAY_SECONDS;
    if (response.statusCode == HttpStatus.ok) {
      welcomeTitle = response.data['title'];
      welcomeContent = response.data['content_html'];
      delaySeconds = response.data['delay'];
      String semesterStartMonday = response.data['semester_start_monday'];
      int index = await ScopedModel.of<MainStateModel>(context).getClassTable();
      CourseTableProvider courseTableProvider = CourseTableProvider();
      String tmpSemesterStartMonday =
          await courseTableProvider.getSemesterStartMonday(index);
      if (tmpSemesterStartMonday != "") {
        semesterStartMonday = tmpSemesterStartMonday;
      }
      bool isSameWeek = await WeekUtil.isSameWeek(semesterStartMonday, 1);
      if (!isSameWeek) {
        await changeWeek(context, semesterStartMonday);
      }
    } else {
      welcomeTitle = S.of(context).welcome_title;
      welcomeContent = S.of(context).welcome_content_html;
    }
    Timer(Duration(seconds: delaySeconds), () {
      showDonateDialog(context, welcomeTitle, welcomeContent);
    });
    return true;
  }

  Future<bool> _shouldShowDonate() async {
    if (!Platform.isIOS) {
      return true;
    }
    try {
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      String currentVersion = packageInfo.version;

      final dio = Dio();
      final response = await dio.get('${Url.UPDATE_ROOT}/showDonate.json');
      return response.data[currentVersion] ?? false;
    } catch (e) {
      return false;
    }
  }

  void showDonateDialog(
      BuildContext context, String welcomeTitle, String welcomeContent) async {
    UmengCommonSdk.onEvent("import_dialog", {"action": "show"});
    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => MDialog(
              welcomeTitle,
              SingleChildScrollView(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                    Html(data: welcomeContent),
                    Container(
                        alignment: Alignment.centerRight,
                        child: TransBgTextButton(
                            color:
                                Theme.of(context).brightness == Brightness.light
                                    ? Theme.of(context).primaryColor
                                    : Colors.white,
                            child: Text(S.of(context).love_and_donate),
                            onPressed: () async {
                              UmengCommonSdk.onEvent(
                                  "import_dialog", {"action": "donate"});
                              if (Platform.isIOS) {
                                _launchURL(Url.URL_APPLE);
                              } else if (Platform.isAndroid) {
                                _launchURL(Url.URL_ANDROID);
                              } else if (Platform.operatingSystem == 'ohos') {
                                _launchURL(Url.URL_OHOS);
                              }
                              Navigator.of(context).pop();
                            })),
                    Container(
                        alignment: Alignment.centerRight,
                        child: TransBgTextButton(
                            color:
                                Theme.of(context).brightness == Brightness.light
                                    ? Theme.of(context).primaryColor
                                    : Colors.white,
                            child: Text(S.of(context).bug_and_report),
                            onPressed: () {
                              UmengCommonSdk.onEvent(
                                  "import_dialog", {"action": "bug"});
                              if (Platform.isIOS) {
                                _launchURL(Url.QQ_GROUP_APPLE_URL);
                              } else if (Platform.isAndroid) {
                                _launchURL(Url.QQ_GROUP_ANDROID_URL);
                              } else if (Platform.operatingSystem == 'ohos') {
                                _launchURL(Url.QQ_GROUP_OHOS_URL);
                              }
                              Navigator.of(context).pop();
                            })),
                    Container(
                        alignment: Alignment.centerRight,
                        child: TransBgTextButton(
                            color: Colors.grey,
                            child: Text(S.of(context).love_but_no_money,
                                style: const TextStyle(color: Colors.grey)),
                            onPressed: () async {
                              UmengCommonSdk.onEvent(
                                  "import_dialog", {"action": "noMoney"});
                              Navigator.of(context).pop();
                            })),
                  ])),
              overrideActions: const [],
            ));
  }

  Future<bool> _launchURL(String url) async {
    if (await canLaunch(url)) {
      await launch(url);
      return true;
    } else {
      return false;
    }
  }

  Future<bool> changeWeek(
      BuildContext context, String semesterStartMonday) async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => MDialog(S.of(context).fix_week_dialog_title,
          Text(S.of(context).fix_week_dialog_content), widgetCancelAction: () {
        Navigator.of(context).pop();
      }, widgetOKAction: () async {
        await WeekUtil.initWeek(semesterStartMonday, 1);
        ScopedModel.of<MainStateModel>(context).refresh();
        Toast.showToast(S.of(context).fix_week_toast_success, context);
        Navigator.of(context).pop(true);
      }),
    );
    return true;
  }

  showClassDialog(BuildContext context, Course course, bool isActive) {
    return showDialog<String>(
        context: context,
        builder: (BuildContext context) {
          UmengCommonSdk.onEvent("class_click", {"type": "single"});
          return CourseDetailDialog(course, isActive, () {
            Navigator.of(context).pop();
          });
        });
  }

  showMultiClassDialog(BuildContext context, int i, int nowWeek) {
    return showDialog(
        context: context,
        builder: (BuildContext context) {
          // 设计失误，其实应该把是不是当前周传进来的
          UmengCommonSdk.onEvent("class_click", {"type": "multi"});
          return Swiper(
            itemBuilder: (BuildContext context, int index) {
              return CourseDetailDialog(
                  multiCourses[i][index],
                  isThisWeek(multiCourses[i][index], nowWeek),
                  () => Navigator.of(context).pop());
            },
            itemCount: multiCourses[i].length,
            pagination: SwiperPagination(
                margin: const EdgeInsets.only(bottom: 100),
                builder: DotSwiperPaginationBuilder(
                    color: Colors.grey,
                    activeColor: Theme.of(context).primaryColor)),
            viewportFraction: 1,
            scale: 1,
          );
        });
  }

  showFreeClassDialog(BuildContext context, int nowWeek) {
    return showDialog(
        context: context,
        builder: (BuildContext context) {
          UmengCommonSdk.onEvent("class_click", {"type": "free"});
          return Swiper(
            itemBuilder: (BuildContext context, int index) {
              return CourseDetailDialog(
                  freeCourses[index],
                  isThisWeek(freeCourses[index], nowWeek),
                  () => Navigator.of(context).pop());
            },
            itemCount: freeCourses.length,
            pagination: SwiperPagination(
                margin: const EdgeInsets.only(bottom: 100),
                builder: DotSwiperPaginationBuilder(
                    color: Colors.grey,
                    activeColor: Theme.of(context).primaryColor)),
            loop: freeCourses.length > 1,
            viewportFraction: 1,
            scale: 1,
          );
        });
  }

  showDeleteDialog(BuildContext context, Course course) {
    UmengCommonSdk.onEvent("class_delete", {"action": "show"});
    return showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return CourseDeleteDialog(course);
      },
    ).then((val) => ScopedModel.of<MainStateModel>(context).refresh());
  }

  showHideFreeCourseDialog(BuildContext context) {
    return showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return const HideFreeCourseDialog();
      },
    ).then((val) => ScopedModel.of<MainStateModel>(context).refresh());
  }

  bool isThisWeek(Course course, int nowWeek) {
    List weeks = json.decode(course.weeks!);
    return weeks.contains(nowWeek);
  }

//TEST: 测试用函数
//  Future insertMockData() async {
//    await courseProvider.insert(new Course(
//        0, "微积分", "[1,2,3,4,5,6,7]", 3, 5, 2, 0,
//        color: '#8AD297', classroom: 'QAQ'));
//    await courseProvider.insert(new Course(
//        0, "线性代数", "[1,2,3,4,5,6,7]", 4, 2, 3, 0,
//        color: '#F9A883', classroom: '仙林校区不知道哪个教室'));
//    await courseProvider.insert(new Course(
//        1, "并不是线性代数", "[1,2,3,4,5,6,7]", 4, 2, 3, 0,
//        color: '#F9A883', classroom: 'QAQ'));
//  }
}
