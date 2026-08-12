import '../../generated/l10n.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:scoped_model/scoped_model.dart';
import '../../Models/CourseTableModel.dart';
import '../../Utils/States/MainState.dart';
import '../../Utils/UpdateCheckPolicy.dart';
import '../../Components/Toast.dart';
import '../CheckUpdate/CheckUpdateView.dart';
import '../Settings/Widgets/WeekChanger.dart';
import 'Widgets/AddDialog.dart';
import 'Widgets/DelDialog.dart';

class ManageTableView extends StatefulWidget {
  const ManageTableView({Key? key}) : super(key: key);

  @override
  _ManageTableViewState createState() => _ManageTableViewState();
}

class _ManageTableViewState extends State<ManageTableView> {
  CourseTableProvider courseTableProvider = CourseTableProvider();
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
            title: Text(S.of(context).class_table_manage_title),
            actions: <Widget>[
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () async {
                  String str = await _addTableDialog(context);
                  if (str != '') {
                    CourseTable courseTable =
                        await courseTableProvider.insert(CourseTable(str));
                    Toast.showToast(
                        S.of(context).add_class_table_success_toast, context);
                    if (courseTable.id != 0) {
                      ScopedModel.of<MainStateModel>(context)
                          .changeclassTable(courseTable.id!);
                    }
                    Navigator.of(context).pop();
                  }
                },
              )
            ]),
        body: SafeArea(
            child: SingleChildScrollView(
                child: Column(
              children: [
                const WeekChanger(),
                const Divider(height: 1),
                _buildIntervalTile(context),
                const Divider(height: 1),
                FutureBuilder<List<Widget>>(
                    future: _getData(context),
                    builder: (BuildContext context,
                        AsyncSnapshot<List<Widget>> snapshot) {
                      if (!snapshot.hasData) {
                        return Container();
                      } else {
                        return Column(
                            children: ListTile.divideTiles(
                                    context: context, tiles: snapshot.data!)
                                .toList());
                      }
                    }),
              ],
            ))));
  }

  /// 多久提醒一次检查课表更新。这里只控制"提醒"，不会自己去登录抓取——
  /// 到点了在课表页顶部出现一条提示，点了才走完整的更新流程。
  Widget _buildIntervalTile(BuildContext context) {
    return FutureBuilder<UpdateCheckInterval>(
      future: ScopedModel.of<MainStateModel>(context).getUpdateCheckInterval(),
      builder: (context, snapshot) {
        final current = snapshot.data;
        return ListTile(
          title: const Text('提醒检查课表更新'),
          subtitle: const Text('到期后在课表页顶部提示，点了才检查'),
          trailing: current == null
              ? const SizedBox(width: 0)
              : DropdownButton<UpdateCheckInterval>(
                  value: current,
                  items: [
                    for (final interval in UpdateCheckInterval.values)
                      DropdownMenuItem(
                        value: interval,
                        child: Text(interval.displayName),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    ScopedModel.of<MainStateModel>(context)
                        .setUpdateCheckInterval(value);
                    setState(() {});
                  },
                ),
        );
      },
    );
  }

  Future<String> _addTableDialog(BuildContext context) async {
    String? tableName = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      // dialog is dismissible with a tap on the barrier
      builder: (BuildContext context) {
        return const AddDialog();
      },
    );
    return tableName!;
  }

  Future<bool> _delTableDialog(BuildContext context) async {
    bool? result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      // dialog is dismissible with a tap on the barrier
      builder: (BuildContext context) {
        return const DelDialog();
      },
    );
    return result ?? false;
  }

  Future<List<Widget>> _getData(BuildContext context) async {
    List courseTables = await courseTableProvider.getAllCourseTable();
    SharedPreferences prefs = await SharedPreferences.getInstance();
    _selectedIndex = prefs.getInt('tableId') ?? 1;
    List<Widget> result = List.generate(
        courseTables.length,
        (int i) => Container(
            color: _selectedIndex == courseTables[i]['id']
                ? Theme.of(context).primaryColor
                : Theme.of(context).colorScheme.surface,
            child: ListTile(
              title: Text(courseTables[i]['name'],
                  style: TextStyle(
                      color: _selectedIndex == courseTables[i]['id']
                          ? Colors.white
                          : null)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  icon: const Icon(Icons.sync),
                  tooltip: '检查更新',
                  onPressed: () {
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (BuildContext context) =>
                            CheckUpdateView(tableId: courseTables[i]['id'])));
                  },
                ),
                _selectedIndex == courseTables[i]['id']
                    ? const SizedBox(width: 48)
                    : IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () async {
                          bool rst = await _delTableDialog(context);
                          if (rst) {
                            await courseTableProvider
                                .delete(courseTables[i]['id']);
                            Toast.showToast(
                                S.of(context).del_class_table_success_toast,
                                context);
                            Navigator.of(context).pop();
                          }
                        },
                      ),
              ]),
              onTap: () {
                setState(() => _selectedIndex = courseTables[i]['id']);
                ScopedModel.of<MainStateModel>(context)
                    .changeclassTable(courseTables[i]['id']);
              },
            )));
    return result;
  }
}
