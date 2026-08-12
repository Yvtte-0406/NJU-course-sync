import 'dart:async';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../Components/Toast.dart';
import '../../Models/CourseTableModel.dart';
import '../../Resources/NjuConfig.dart';
import '../../Services/CourseSyncService.dart';

/// "检查更新"页面：复用已登录 WebView 抓取最新课表，跟当前数据库里的课程
/// 做比对，展示变更预览由用户确认后再落库。
///
/// 抓取、判学期、比对、覆盖这套逻辑全在 [CourseSyncService] 里，本页只负责
/// 「把用户登进去」和「把结果画出来」——导入页的「更新当前课程表」走的是
/// 同一个服务，两边不会再各写一遍。
class CheckUpdateView extends StatefulWidget {
  final int tableId;

  const CheckUpdateView({Key? key, required this.tableId}) : super(key: key);

  @override
  State<CheckUpdateView> createState() => _CheckUpdateViewState();
}

enum _Stage { loadingConfig, unsupported, webview, reviewing, applied }

class _CheckUpdateViewState extends State<CheckUpdateView> {
  final CourseTableProvider _courseTableProvider = CourseTableProvider();
  final CourseSyncService _syncService = CourseSyncService();

  _Stage _stage = _Stage.loadingConfig;
  String _message = '正在准备检查…';
  Map? _config;
  NjuEntryConfig? _entry;
  WebViewController? _webViewController;
  Timer? _sessionTimeoutTimer;

  SyncReport? _report;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _sessionTimeoutTimer?.cancel();
    super.dispose();
  }

  Future<void> _prepare() async {
    final pinyin =
        await _courseTableProvider.getSourceSchoolPinyin(widget.tableId);
    if (pinyin == null || pinyin.isEmpty) {
      setState(() {
        _stage = _Stage.unsupported;
        _message = '该课表不是通过学校自动导入创建的，无法检查更新。';
      });
      return;
    }

    final entry = NjuConfig.findByPinyin(pinyin);
    if (entry == null) {
      setState(() {
        _stage = _Stage.unsupported;
        _message = '未能找到该课表对应的学校配置，无法检查更新。';
      });
      return;
    }

    setState(() {
      _entry = entry;
      _config = entry.toConfigMap();
      _stage = _Stage.webview;
    });
    _initWebView();
  }

  void _initWebView() {
    final config = _config!;
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (String url) {
            if (config['redirectUrl'] != '' &&
                url.startsWith(config['redirectUrl'])) {
              _webViewController!.loadRequest(Uri.parse(config['targetUrl']));
            } else if (url.startsWith(config['targetUrl'])) {
              _sessionTimeoutTimer?.cancel();
              _fetchAndDiff();
            } else if (url.contains('authserver.nju.edu.cn/authserver/login')) {
              // 落回了登录页，说明之前保存的登录状态已经失效——"检查更新"
              // 本身不做登录（那一整套自动填表/验证码兜底逻辑只在
              // ImportView 里维护一份，这里不重复实现），直接提示用户
              // 去导入页重新登录一次。
              _sessionTimeoutTimer?.cancel();
              if (!mounted) return;
              setState(() {
                _stage = _Stage.unsupported;
                _message = '登录状态已失效，需要重新登录。请到"导入南大课表"页面用'
                    '"新账号登录"重新登录一次，之后再回来检查更新。';
              });
            }
          },
          onWebResourceError: (error) {
            _sessionTimeoutTimer?.cancel();
            if (!mounted) return;
            setState(() {
              _stage = _Stage.unsupported;
              _message = '网络错误，请检查网络连接（如需要请先连接南京大学 VPN）。';
            });
          },
        ),
      )
      ..loadRequest(Uri.parse(config['initialUrl']));

    _sessionTimeoutTimer = Timer(const Duration(seconds: 20), () {
      if (!mounted || _stage != _Stage.webview) return;
      setState(() {
        _stage = _Stage.unsupported;
        _message = '检查超时，请稍后重试。';
      });
    });
  }

  Future<void> _fetchAndDiff() async {
    try {
      Toast.showToast('正在抓取最新课表…', context);
      final fetch = await _syncService.fetch(_webViewController!, _entry!);
      final report = await _syncService.compareWithTable(
        config: _entry!,
        fetch: fetch,
        tableId: widget.tableId,
      );

      if (!mounted) return;
      switch (report.outcome) {
        case SyncOutcome.emptyFetch:
          setState(() {
            _stage = _Stage.unsupported;
            _message = '这次没有抓到任何课程，判定为抓取失败，已跳过本轮检查，'
                '课表没有任何改动。请稍后重试。';
          });
          return;
        case SyncOutcome.semesterChanged:
          // 这个页面没有建表能力，指路给导入页。
          setState(() {
            _stage = _Stage.unsupported;
            _message = '教务系统已经是新的学期了，这张课表属于上一个学期。\n'
                '请到"导入课程表"新建一张本学期的课表。';
          });
          return;
        case SyncOutcome.noSuchTable:
          setState(() {
            _stage = _Stage.unsupported;
            _message = '这张课表已经不存在了。';
          });
          return;
        case SyncOutcome.ok:
          setState(() {
            _report = report;
            _stage = _Stage.reviewing;
          });
          return;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.unsupported;
        _message = '检查更新失败：$e';
      });
    }
  }

  Future<void> _applyChanges() async {
    await _syncService.applyChanges(_report!);
    if (mounted) {
      Toast.showToast('已应用课表变更', context);
      setState(() => _stage = _Stage.applied);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('检查课表更新')),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (_stage) {
      case _Stage.loadingConfig:
        return const Center(child: CircularProgressIndicator());
      case _Stage.unsupported:
        return Center(
            child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_message, textAlign: TextAlign.center)));
      case _Stage.webview:
        return Column(children: [
          const Padding(
              padding: EdgeInsets.all(8),
              child: Text('请登录以检查课表是否有更新，登录成功后将自动比对。')),
          Expanded(child: WebViewWidget(controller: _webViewController!)),
        ]);
      case _Stage.reviewing:
        return _buildReview(context);
      case _Stage.applied:
        return const Center(child: Text('变更已应用完成。'));
    }
  }

  Widget _buildReview(BuildContext context) {
    final diff = _report!.diff!;
    final sweepSummary = _report?.sweep?.summary;
    if (diff.isEmpty) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(sweepSummary ?? '没有检测到课表变化。',
                  textAlign: TextAlign.center)));
    }

    final items = <Widget>[];

    if (sweepSummary != null) {
      items.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(sweepSummary,
            style: TextStyle(color: Theme.of(context).colorScheme.primary)),
      ));
    }

    if (diff.addedCourses.isNotEmpty) {
      items.add(_sectionTitle('新增课程'));
      for (final entry in diff.addedCourses.entries) {
        for (final c in entry.value) {
          items.add(ListTile(
            title: Text(c.name ?? '', style: const TextStyle(color: Colors.green)),
            subtitle: Text('${c.teacher ?? ''} · ${c.classroom ?? ''}'),
          ));
        }
      }
    }

    if (diff.removedCourses.isNotEmpty) {
      items.add(_sectionTitle('学校数据里没找到（已从课表隐藏）'));
      for (final entry in diff.removedCourses.entries) {
        for (final c in entry.value) {
          items.add(ListTile(
            title: Text(c.name ?? '', style: const TextStyle(color: Colors.red)),
            subtitle: Text('${c.teacher ?? ''} · ${c.classroom ?? ''}'),
          ));
        }
      }
    }

    if (diff.changedSlots.isNotEmpty) {
      items.add(_sectionTitle('信息变更'));
      for (final change in diff.changedSlots) {
        final fieldNames = {
          'classroom': '教室',
          'info': '备注',
          'weekTime': '星期',
          'startTime': '起始节次',
          'timeCount': '节次跨度',
          'weeks': '周次',
        };
        final desc = change.changedFields.entries
            .map((e) =>
                '${fieldNames[e.key] ?? e.key}：${e.value.key ?? ''} → ${e.value.value ?? ''}')
            .join('\n');
        items.add(ListTile(
          title: Text(change.oldSlot.name ?? ''),
          subtitle: Text(desc),
        ));
      }
    }

    if (diff.addedSlots.isNotEmpty) {
      items.add(_sectionTitle('新增时间段'));
      for (final c in diff.addedSlots) {
        items.add(ListTile(
          title: Text(c.name ?? '', style: const TextStyle(color: Colors.green)),
          subtitle: Text('星期${c.weekTime} 第${c.startTime}节 · ${c.classroom ?? ''}'),
        ));
      }
    }

    if (diff.removedSlots.isNotEmpty) {
      items.add(_sectionTitle('取消的时间段（已从课表隐藏）'));
      for (final c in diff.removedSlots) {
        items.add(ListTile(
          title: Text(c.name ?? '', style: const TextStyle(color: Colors.red)),
          subtitle: Text('星期${c.weekTime} 第${c.startTime}节 · ${c.classroom ?? ''}'),
        ));
      }
    }

    return Column(children: [
      Expanded(child: ListView(children: items)),
      Padding(
        padding: const EdgeInsets.all(12),
        child: ElevatedButton(
          onPressed: _applyChanges,
          child: const Text('应用新增与变更'),
        ),
      ),
    ]);
  }

  Widget _sectionTitle(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(title,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      );
}
