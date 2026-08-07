import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:umeng_common_sdk/umeng_common_sdk.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:scoped_model/scoped_model.dart';
import '../../generated/l10n.dart';
import '../../Utils/States/MainState.dart';
import '../../Utils/ColorUtil.dart';
import '../../Components/Toast.dart';
import 'ColorSettingsView.dart';
import 'AccentColorSettingsView.dart';

/// 外观设置：浅色/深色模式、课程颜色、强调色、背景图片——原来这些都跟
/// 一堆课表显示开关一起塞在"更多设置"里，现在单独拆出来，方便找。
class AppearanceSettingsView extends StatefulWidget {
  const AppearanceSettingsView({Key? key}) : super(key: key);

  @override
  _AppearanceSettingsViewState createState() =>
      _AppearanceSettingsViewState();
}

class _AppearanceSettingsViewState extends State<AppearanceSettingsView> {
  bool showWhiteTitleMode = false;

  @override
  void initState() {
    super.initState();
    init();
  }

  init() async {
    bool hasPic = await _getHasImgPath();
    setState(() {
      showWhiteTitleMode = hasPic;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('外观设置')),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: ListTile.divideTiles(context: context, tiles: [
              ListTile(
                  title: Text(S.of(context).change_theme_mode_title),
                  subtitle: Text(S.of(context).change_theme_mode_subtitle),
                  trailing: FutureBuilder<int>(
                      future: _getThemeIndex(),
                      builder:
                          (BuildContext context, AsyncSnapshot<int> snapshot) {
                        if (!snapshot.hasData) {
                          return Container(width: 0);
                        } else {
                          return DropdownButton<int>(
                              value: snapshot.data,
                              items: const [
                                DropdownMenuItem(
                                    child: Row(children: [
                                      Icon(Icons.settings),
                                      Text('跟随系统')
                                    ]),
                                    value: 0),
                                DropdownMenuItem(
                                    child: Row(children: [
                                      Icon(Icons.wb_sunny),
                                      Text('浅色模式')
                                    ]),
                                    value: 1),
                                DropdownMenuItem(
                                    child: Row(children: [
                                      Icon(Icons.shield_moon),
                                      Text('深色模式')
                                    ]),
                                    value: 2)
                              ],
                              onChanged: (value) {
                                UmengCommonSdk.onEvent("appearance_setting",
                                    {"type": 12, "result": value.toString()});
                                ScopedModel.of<MainStateModel>(context)
                                    .changeThemeMode(value ?? 0);
                                setState(() {});
                              });
                        }
                      })),
              ListTile(
                title: const Text('课程颜色设置'),
                subtitle: const Text('选取配色方案，或者给每门课单独指定颜色'),
                onTap: () {
                  UmengCommonSdk.onEvent("appearance_setting", {"type": 1});
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (context) => const ColorSettingsView()));
                },
              ),
              ListTile(
                title: const Text('强调色设置'),
                subtitle: const Text('选择 App 强调色'),
                onTap: () {
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (context) => const AccentColorSettingsView()));
                },
              ),
              ListTile(
                title: Text(S.of(context).add_backgound_picture_title),
                subtitle: Text(S.of(context).add_backgound_picture_subtitle),
                onTap: () async {
                  UmengCommonSdk.onEvent("appearance_setting", {"type": 2});
                  final XFile? image = await ImagePicker()
                      .pickImage(source: ImageSource.gallery);

                  if (image == null) return;

                  String oldPath = await ScopedModel.of<MainStateModel>(context)
                      .getBgImgPath();
                  File oldImg = File(oldPath);
                  if (oldImg.existsSync()) {
                    oldImg.deleteSync(recursive: true);
                  }

                  int num = Random().nextInt(1000);
                  Directory directory =
                      await getApplicationDocumentsDirectory();
                  final String path = directory.path;
                  String fileName = '$path/background_$num.jpg';
                  await image.saveTo(fileName);

                  bool isWhiteMode =
                      await ColorUtil.shouldApplyWhiteMode(fileName);

                  await ScopedModel.of<MainStateModel>(context)
                      .setBgImgPath(fileName);
                  ScopedModel.of<MainStateModel>(context)
                      .setWhiteMode(isWhiteMode);
                  Toast.showToast(
                      S.of(context).add_backgound_picture_success_toast,
                      context);
                  Navigator.of(context).pop();
                  Navigator.of(context).pop();
                },
              ),
              ListTile(
                title: Text(S.of(context).delete_backgound_picture_title),
                subtitle: Text(S.of(context).delete_backgound_picture_subtitle),
                onTap: () async {
                  UmengCommonSdk.onEvent("appearance_setting", {"type": 3});
                  String oldPath = await ScopedModel.of<MainStateModel>(context)
                      .getBgImgPath();
                  File oldImg = File(oldPath);
                  if (await oldImg.exists()) {
                    await oldImg.delete(recursive: true);
                  }
                  await ScopedModel.of<MainStateModel>(context)
                      .removeBgImgPath();
                  Toast.showToast(
                      S.of(context).delete_backgound_picture_success_toast,
                      context);
                  Navigator.of(context).pop();
                  Navigator.of(context).pop();
                },
              ),
              showWhiteTitleMode
                  ? ListTile(
                      title: Text(S.of(context).white_title_mode_title),
                      subtitle: Text(S.of(context).white_title_mode_subtitle),
                      trailing: FutureBuilder<bool>(
                          future: _getWhiteMode(),
                          builder: (BuildContext context,
                              AsyncSnapshot<bool> snapshot) {
                            if (!snapshot.hasData) {
                              return Container(width: 0);
                            } else {
                              return Switch(
                                  value: snapshot.data!,
                                  onChanged: (bool value) {
                                    UmengCommonSdk.onEvent(
                                        "appearance_setting", {
                                      "type": 4,
                                      "result": value.toString()
                                    });
                                    ScopedModel.of<MainStateModel>(context)
                                        .setWhiteMode(value);
                                    setState(() {});
                                  });
                            }
                          }))
                  : Container(width: 0),
            ]).toList(),
          ),
        ),
      ),
    );
  }

  Future<int> _getThemeIndex() async {
    return await ScopedModel.of<MainStateModel>(context).getThemeMode();
  }

  Future<bool> _getHasImgPath() async {
    String imgPath =
        await ScopedModel.of<MainStateModel>(context).getBgImgPath();
    return imgPath != "";
  }

  Future<bool> _getWhiteMode() async {
    bool whiteMode =
        await ScopedModel.of<MainStateModel>(context).getWhiteMode();
    return whiteMode;
  }
}
