import 'package:flutter/material.dart';
import 'package:umeng_common_sdk/umeng_common_sdk.dart';
import 'package:scoped_model/scoped_model.dart';
import '../../generated/l10n.dart';
import '../../Utils/States/MainState.dart';
import 'Widgets/NumChanger.dart';

/// 课表显示设置：周末/课程时间/自由时间课程/非本周课程/月份/日期
/// 这些"课表内容要不要显示"的开关，以及强制缩放、课程高度这类布局选项。
/// 跟"外观设置"（配色/背景图）区分开——这些是"课表长什么样"，不是
/// "App 整体颜色风格"。
class ScheduleDisplaySettingsView extends StatefulWidget {
  const ScheduleDisplaySettingsView({Key? key}) : super(key: key);

  @override
  _ScheduleDisplaySettingsViewState createState() =>
      _ScheduleDisplaySettingsViewState();
}

class _ScheduleDisplaySettingsViewState
    extends State<ScheduleDisplaySettingsView> {
  bool showCustomClassHeight = false;

  @override
  void initState() {
    super.initState();
    init();
  }

  init() async {
    bool forceZoom = await _getForceZoom();
    setState(() {
      showCustomClassHeight = !forceZoom;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('课表显示设置')),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: ListTile.divideTiles(context: context, tiles: [
              ListTile(
                  title: Text(S.of(context).hide_add_button_title),
                  subtitle: Text(S.of(context).hide_add_button_subtitle),
                  trailing: FutureBuilder<bool>(
                      future: _getAddButton(),
                      builder: (BuildContext context,
                          AsyncSnapshot<bool> snapshot) {
                        if (!snapshot.hasData) {
                          return Container(width: 0);
                        } else {
                          return Switch(
                              value: !snapshot.data!,
                              onChanged: (bool value) {
                                UmengCommonSdk.onEvent("schedule_display", {
                                  "type": 5,
                                  "result": value.toString()
                                });
                                ScopedModel.of<MainStateModel>(context)
                                    .setAddButton(!value);
                                setState(() {});
                              });
                        }
                      })),
              ListTile(
                title: Text(S.of(context).if_show_weekend_title),
                subtitle: Text(S.of(context).if_show_weekend_subtitle),
                trailing: FutureBuilder<bool>(
                    future: _getShowWeekend(),
                    builder:
                        (BuildContext context, AsyncSnapshot<bool> snapshot) {
                      if (!snapshot.hasData) {
                        return Container(width: 0);
                      } else {
                        return Switch(
                            value: snapshot.data!,
                            onChanged: (bool value) {
                              UmengCommonSdk.onEvent("schedule_display",
                                  {"type": 6, "result": value.toString()});
                              ScopedModel.of<MainStateModel>(context)
                                  .setShowWeekend(value);
                              setState(() {});
                            });
                      }
                    }),
              ),
              ListTile(
                title: Text(S.of(context).if_show_classtime_title),
                subtitle: Text(S.of(context).if_show_classtime_subtitle),
                trailing: FutureBuilder<bool>(
                    future: _getShowClassTime(),
                    builder:
                        (BuildContext context, AsyncSnapshot<bool> snapshot) {
                      if (!snapshot.hasData) {
                        return Container(width: 0);
                      } else {
                        return Switch(
                            value: snapshot.data!,
                            onChanged: (bool value) {
                              UmengCommonSdk.onEvent("schedule_display",
                                  {"type": 7, "result": value.toString()});
                              ScopedModel.of<MainStateModel>(context)
                                  .setShowClassTime(value);
                              setState(() {});
                            });
                      }
                    }),
              ),
              ListTile(
                title: Text(S.of(context).if_show_freeclass_title),
                subtitle: Text(S.of(context).if_show_freeclass_subtitle),
                trailing: FutureBuilder<bool>(
                    future: _getShowFreeClass(),
                    builder:
                        (BuildContext context, AsyncSnapshot<bool> snapshot) {
                      if (!snapshot.hasData) {
                        return Container(width: 0);
                      } else {
                        return Switch(
                            value: snapshot.data!,
                            onChanged: (bool value) {
                              UmengCommonSdk.onEvent("schedule_display",
                                  {"type": 8, "result": value.toString()});
                              ScopedModel.of<MainStateModel>(context)
                                  .setShowFreeClass(value);
                              setState(() {});
                            });
                      }
                    }),
              ),
              ListTile(
                title:
                    Text(S.of(context).if_show_non_current_week_courses_title),
                subtitle: Text(
                    S.of(context).if_show_non_current_week_courses_subtitle),
                trailing: FutureBuilder<bool>(
                    future: _getShowNonCurrentWeekCourses(),
                    builder:
                        (BuildContext context, AsyncSnapshot<bool> snapshot) {
                      if (!snapshot.hasData) {
                        return Container(width: 0);
                      } else {
                        return Switch(
                            value: snapshot.data!,
                            onChanged: (bool value) {
                              UmengCommonSdk.onEvent("schedule_display", {
                                "type": 22,
                                "result": value.toString()
                              });
                              ScopedModel.of<MainStateModel>(context)
                                  .setShowNonCurrentWeekCourses(value);
                              setState(() {});
                            });
                      }
                    }),
              ),
              ListTile(
                title: Text(S.of(context).show_month_title),
                subtitle: Text(S.of(context).show_month_subtitle),
                trailing: FutureBuilder<bool>(
                    future: _getShowMonth(),
                    builder:
                        (BuildContext context, AsyncSnapshot<bool> snapshot) {
                      if (!snapshot.hasData) {
                        return Container(width: 0);
                      } else {
                        return Switch(
                            value: snapshot.data!,
                            onChanged: (bool value) {
                              UmengCommonSdk.onEvent("schedule_display",
                                  {"type": 9, "result": value.toString()});
                              ScopedModel.of<MainStateModel>(context)
                                  .setShowMonth(value);
                              setState(() {});
                            });
                      }
                    }),
              ),
              ListTile(
                title: Text(S.of(context).show_date_title),
                subtitle: Text(S.of(context).show_date_subtitle),
                trailing: FutureBuilder<bool>(
                    future: _getShowDate(),
                    builder:
                        (BuildContext context, AsyncSnapshot<bool> snapshot) {
                      if (!snapshot.hasData) {
                        return Container(width: 0);
                      } else {
                        return Switch(
                            value: snapshot.data!,
                            onChanged: (bool value) {
                              UmengCommonSdk.onEvent("schedule_display",
                                  {"type": 10, "result": value.toString()});
                              ScopedModel.of<MainStateModel>(context)
                                  .setShowDate(value);
                              setState(() {});
                            });
                      }
                    }),
              ),
              ListTile(
                title: Text(S.of(context).force_zoom_title),
                subtitle: Text(S.of(context).force_zoom_subtitle),
                trailing: FutureBuilder<bool>(
                    future: _getForceZoom(),
                    builder:
                        (BuildContext context, AsyncSnapshot<bool> snapshot) {
                      if (!snapshot.hasData) {
                        return Container(width: 0);
                      } else {
                        return Switch(
                            value: snapshot.data!,
                            onChanged: (bool value) {
                              ScopedModel.of<MainStateModel>(context)
                                  .setForceZoom(value);
                              UmengCommonSdk.onEvent("schedule_display",
                                  {"type": 11, "result": value.toString()});
                              setState(() {
                                showCustomClassHeight = !value;
                              });
                            });
                      }
                    }),
              ),
              showCustomClassHeight
                  ? ListTile(
                      title: Text(S.of(context).class_height_title),
                      subtitle: Text(S.of(context).class_height_subtitle),
                      trailing: FutureBuilder<int>(
                          future: _getClassHeight(),
                          builder: (BuildContext context,
                              AsyncSnapshot<int> snapshot) {
                            if (!snapshot.hasData) {
                              return Container(width: 0);
                            } else {
                              return SizedBox(
                                  width: 102,
                                  child: NumberChangerWidget(
                                    width: 40,
                                    iconWidth: 30,
                                    numText: snapshot.data.toString(),
                                    addValueChanged: (num) {
                                      _setClassHeight(num);
                                    },
                                    removeValueChanged: (num) {
                                      _setClassHeight(num);
                                    },
                                    updateValueChanged: (num) {
                                      _setClassHeight(num);
                                    },
                                  ));
                            }
                          }),
                    )
                  : Container(width: 0),
            ]).toList(),
          ),
        ),
      ),
    );
  }

  Future<bool> _getShowWeekend() async {
    return await ScopedModel.of<MainStateModel>(context).getShowWeekend();
  }

  Future<bool> _getShowClassTime() async {
    return await ScopedModel.of<MainStateModel>(context).getShowClassTime();
  }

  Future<bool> _getShowFreeClass() async {
    return await ScopedModel.of<MainStateModel>(context).getShowFreeClass();
  }

  Future<bool> _getShowNonCurrentWeekCourses() async {
    return await ScopedModel.of<MainStateModel>(context)
        .getShowNonCurrentWeekCourses();
  }

  Future<bool> _getShowMonth() async {
    return await ScopedModel.of<MainStateModel>(context).getShowMonth();
  }

  Future<bool> _getShowDate() async {
    return await ScopedModel.of<MainStateModel>(context).getShowDate();
  }

  Future<int> _getClassHeight() async {
    return await ScopedModel.of<MainStateModel>(context).getClassHeight();
  }

  _setClassHeight(int classHeight) async {
    ScopedModel.of<MainStateModel>(context).setClassHeight(classHeight);
  }

  Future<bool> _getForceZoom() async {
    return await ScopedModel.of<MainStateModel>(context).getForceZoom();
  }

  Future<bool> _getAddButton() async {
    return await ScopedModel.of<MainStateModel>(context).getAddButton();
  }
}
