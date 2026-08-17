import 'dart:io';
import '../../generated/l10n.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:umeng_common_sdk/umeng_common_sdk.dart';
import 'package:share_extend/share_extend.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:dio/dio.dart';
import '../ManageTable/ManageTableView.dart';
import '../Import/ImportView.dart';

// import '../AllCourse/AllCourseView.dart';
import '../Lecture/LecturesView.dart';
import '../About/AboutView.dart';
import '../AddCourse/AddCourseView.dart';
import 'AppearanceSettingsView.dart';
import 'BackgroundSyncSettingsView.dart';
import 'ScheduleDisplaySettingsView.dart';
import 'WidgetSettingsView.dart';
import '../Share/ShareView.dart';
import '../../Components/Toast.dart';
import '../../Resources/Config.dart';
import '../../Resources/Url.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({Key? key}) : super(key: key);

  @override
  _SettingsViewState createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(S.of(context).settings_title),
      ),
      body: SafeArea(
          child: SingleChildScrollView(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
            _sectionHeader(context, '课表数据', first: true),
            ...ListTile.divideTiles(context: context, tiles: [
        ListTile(
          title: Text(S.of(context).import_title),
          subtitle: Text(S.of(context).import_subtitle),
          onTap: () async {
            UmengCommonSdk.onEvent(
                "class_import", {"type": "auto", "action": "show"});
            bool? status = await Navigator.of(context).push(MaterialPageRoute(
                builder: (BuildContext context) => const ImportView()));
            if (status == true) Navigator.of(context).pop(status);
          },
        ),
        ListTile(
          title: const Text('添加课程'),
          subtitle: const Text('手动填写课程信息，或从讲座列表快捷添加'),
          onTap: () => _showAddCourseChoices(context),
        ),
        ListTile(
          title: const Text('后台自动更新'),
          subtitle: const Text('每天自动登录检查课表变化，无需手动操作'),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
                builder: (BuildContext context) =>
                    const BackgroundSyncSettingsView()));
          },
        ),
        //TODO: 全校课程
        // ListTile(
        //   title: Text(S.of(context).all_course_title),
        //   subtitle: Text(S.of(context).all_course_subtitle),
        //   onTap: () async {
        //     UmengCommonSdk.onEvent(
        //         "class_import", {"type": "all", "action": "show"});
        //     bool? status = await Navigator.of(context).push(
        //         MaterialPageRoute(
        //             builder: (BuildContext context) => const AllCourseView()));
        //     if (status == true) Navigator.of(context).pop(status);
        //   },
        // ),
        // ListTile(
        //   title: Text(S.of(context).import_from_NJU_title),
        //   subtitle: Text(S.of(context).import_from_NJU_subtitle),
        //   onTap: () async {
        //     bool status = await Navigator.of(context).push(
        //         MaterialPageRoute(
        //             builder: (BuildContext context) => ImportView()));
        //     if (status == true) Navigator.of(context).pop(status);
        //   },
        // ),
        // ListTile(
        //   title: Text(S.of(context).import_from_NJU_cer_title),
        //   subtitle: Text(S.of(context).import_from_NJU_cer_subtitle),
        //   onTap: () async {
        //     bool status = await Navigator.of(context).push(
        //         MaterialPageRoute(
        //             builder: (BuildContext context) =>
        //                 ImportFromWebView()));
        //     if (status == true) Navigator.of(context).pop(status);
        //   },
        // ),
        // ListTile(
        //   title: Text(S.of(context).import_from_NJU_xk_title),
        //   subtitle: Text(S.of(context).import_from_NJU_xk_subtitle),
        //   onTap: () async {
        //     bool? status = await Navigator.of(context).push(
        //         MaterialPageRoute(
        //             builder: (BuildContext context) =>
        //                 ImportFromXKView()));
        //     if (status == true) Navigator.of(context).pop(status);
        //   },
        // ),
        ListTile(
          title: Text(S.of(context).manage_table_title),
          subtitle: Text(S.of(context).manage_table_subtitle),
          onTap: () {
            UmengCommonSdk.onEvent("schedule_manage", {"action": "show"});
            Navigator.of(context).push(MaterialPageRoute(
                builder: (BuildContext context) => const ManageTableView()));
          },
        ),
        ListTile(
          title: const Text('分享与备份课表'),
          subtitle: Text(S.of(context).import_or_export_subtitle),
          onTap: () {
            UmengCommonSdk.onEvent("qr_import", {"action": "show"});
            Navigator.of(context).push(MaterialPageRoute(
                builder: (BuildContext context) => const ShareView()));
          },
        ),
            ]).toList(),
            _sectionHeader(context, '外观'),
            ...ListTile.divideTiles(context: context, tiles: [
        ListTile(
          title: const Text('外观设置'),
          subtitle: const Text('浅色/深色模式、课程颜色、强调色、背景图片'),
          onTap: () {
            UmengCommonSdk.onEvent("appearance_setting", {"action": "show"});
            Navigator.of(context).push(MaterialPageRoute(
                builder: (BuildContext context) =>
                    const AppearanceSettingsView()));
          },
        ),
        ListTile(
          title: const Text('课表显示设置'),
          subtitle: const Text('周末、课程时间、自由时间课程等显示选项，强制缩放'),
          onTap: () {
            UmengCommonSdk.onEvent("schedule_display", {"action": "show"});
            Navigator.of(context).push(MaterialPageRoute(
                builder: (BuildContext context) =>
                    const ScheduleDisplaySettingsView()));
          },
        ),
        // Widget settings - iOS only
        if (Platform.isIOS)
          ListTile(
            title: Text(S.of(context).widget_and_live_activity_settings_title),
            subtitle:
                Text(S.of(context).widget_and_live_activity_settings_subtitle),
            onTap: () {
              UmengCommonSdk.onEvent("widget_setting", {"action": "show"});
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (BuildContext context) =>
                      const WidgetSettingsView()));
            },
          ),
            ]).toList(),
            _sectionHeader(context, '关于与支持'),
            ...ListTile.divideTiles(context: context, tiles: [
        ListTile(
          title: Text(S.of(context).share_title),
          subtitle: Text(S.of(context).share_subtitle),
          onTap: () {
            UmengCommonSdk.onEvent("app_share", {"action": "show"});
            ShareExtend.share(S.of(context).share_content, "text");
          },
        ),
        ListTile(
          title: Text(S.of(context).report_title),
          subtitle: Text(S.of(context).report_subtitle),
          onTap: () async {
            UmengCommonSdk.onEvent("group_add", {"action": "show"});
            bool status = false;
            if (Platform.isIOS) {
              status = await _launchURL(Url.QQ_GROUP_APPLE_URL);
            } else if (Platform.isAndroid) {
              status = await _launchURL(Url.QQ_GROUP_ANDROID_URL);
            } else if (Platform.operatingSystem == 'ohos') {
              status = await _launchURL(Url.QQ_GROUP_OHOS_URL);
            }
            if (!status) {
              Toast.showToast(S.of(context).QQ_open_fail_toast, context);
            }
          },
          onLongPress: () async {
            UmengCommonSdk.onEvent("group_add", {"action": "copy"});
            if (Platform.isIOS) {
              await Clipboard.setData(
                  const ClipboardData(text: Config.IOS_GROUP));
            } else if (Platform.isAndroid) {
              await Clipboard.setData(
                  const ClipboardData(text: Config.ANDROID_GROUP));
            } else if (Platform.operatingSystem == 'ohos') {
              await Clipboard.setData(
                  const ClipboardData(text: Config.OHOS_GROUP));
            }
            Toast.showToast(S.of(context).QQ_copy_success_toast, context);
          },
        ),
        FutureBuilder<bool>(
            future: _shouldShowDonate(),
            builder: (BuildContext context, AsyncSnapshot<bool> snapshot) {
              if (snapshot.hasData && snapshot.data == false) {
                return Container(width: 0, height: 0);
              }
              return ListTile(
                  title: Text(S.of(context).donate_title),
                  subtitle: Text(S.of(context).donate_subtitle),
                  onTap: () async {
                    UmengCommonSdk.onEvent("donate_click", {"action": "show"});
                    bool status = false;
                    if (Platform.isIOS) {
                      status = await _launchURL(Url.URL_APPLE);
                    } else if (Platform.isAndroid) {
                      status = await _launchURL(Url.URL_ANDROID);
                    } else if (Platform.operatingSystem == 'ohos') {
                      status = await _launchURL(Url.URL_OHOS);
                    }
                    if (!status) {
                      Toast.showToast(S.of(context).pay_open_fail_toast, context);
                    }
                  });
            }),
        ListTile(
          title: Text(S.of(context).about_title),
          subtitle: FutureBuilder<String>(
              future: _getVersion(),
              builder: (BuildContext context, AsyncSnapshot<String> snapshot) {
                if (!snapshot.hasData) {
                  return Container();
                } else {
                  return Text(snapshot.data! + S.of(context).flutter_lts);
                }
              }),
          onTap: () {
            UmengCommonSdk.onEvent("about_click", {"action": "show"});
            Navigator.of(context).push(MaterialPageRoute(
                builder: (BuildContext context) => const AboutView()));
          },
        )
            ]).toList(),
          ]))),
    );
  }

  /// 分组标题：用一段留白色带（不是单纯一条细线）把上一组内容"隔开"，
  /// 效果接近 iOS 设置里那种分组间灰色缝隙，跟组内条目之间的细分割线
  /// 明显不一样，看一眼就知道是新的一组，不是粘在上一条目下面。
  Widget _sectionHeader(BuildContext context, String title,
          {bool first = false}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!first)
            Container(
              height: 16,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(16, first ? 16 : 12, 16, 8),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ],
      );

  /// "添加课程"合并了原来两个独立入口——手动填写（自己录一条课程）和
  /// 讲座列表（从已知的讲座里选一个快捷带数据添加）。两者都是"往课表加
  /// 一条记录"，只是数据从哪来不一样，所以合并成一个入口、点开再选，
  /// 而不是继续在设置页平铺两条。
  Future<void> _showAddCourseChoices(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_note),
              title: Text(S.of(context).import_manually_title),
              subtitle: Text(S.of(context).import_manually_subtitle),
              onTap: () {
                Navigator.of(context).pop();
                UmengCommonSdk.onEvent(
                    "class_import", {"type": "manual", "action": "show"});
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (BuildContext context) => const AddView()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.campaign_outlined),
              title: Text(S.of(context).view_lecture_title),
              subtitle: Text(S.of(context).view_lecture_subtitle),
              onTap: () async {
                Navigator.of(context).pop();
                UmengCommonSdk.onEvent(
                    "class_import", {"type": "lecture", "action": "show"});
                bool? status = await Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (BuildContext context) =>
                            const LectureView()));
                if (status == true && context.mounted) {
                  Navigator.of(context).pop(status);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _shouldShowDonate() async {
    if (!Platform.isIOS) {
      return true;
    }
    try {
      String currentVersion = await _getVersion();
      final dio = Dio();
      final response = await dio.get('${Url.UPDATE_ROOT}/showDonate.json');
      return response.data[currentVersion] ?? false;
    } catch (e) {
      return false;
    }
  }

  Future<String> _getVersion() async {
    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version;
  }

  Future<bool> _launchURL(String url) async {
    if (await canLaunch(url)) {
      await launch(url);
      return true;
    } else {
      return false;
    }
  }
}
