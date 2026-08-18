import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheretosleepinnju/Pages/CourseTable/Widgets/SyncChangeDialog.dart';
import 'package:wheretosleepinnju/Services/SyncChangeSummary.dart';
import 'package:wheretosleepinnju/generated/l10n.dart';

SyncChangeSummary _summary(int entryCount) => SyncChangeSummary(
      at: DateTime.now().subtract(const Duration(hours: 2)),
      tableName: '2025-2026学年第一学期',
      entries: [
        for (var i = 0; i < entryCount; i++)
          SyncChangeEntry(
            kind: SyncChangeKind.changed,
            name: '课程$i',
            detail: '教室：A$i → B$i',
          ),
      ],
    );

/// 打开弹窗并停在那一帧。
Future<void> _open(WidgetTester tester, SyncChangeSummary summary) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: const [
      S.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: S.delegate.supportedLocales,
    home: Builder(
      builder: (context) => Scaffold(
        body: ElevatedButton(
          onPressed: () => showSyncChangeDialog(context, summary),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// 这个弹窗在开发环境里几乎无法自然触发——要等学校真的调课才会出现，
/// 暑假或课表没变动时根本验证不了。所以它的渲染行为只能靠这些测试守住。
void main() {
  testWidgets('列出每一条变更的课程名和详情', (tester) async {
    await _open(tester, _summary(2));

    expect(find.text('课表已自动更新'), findsOneWidget);
    expect(find.text('课程0'), findsOneWidget);
    expect(find.text('教室：A0 → B0'), findsOneWidget);
    expect(find.text('课程1'), findsOneWidget);
  });

  testWidgets('标题栏说明是哪张表、什么时候的事', (tester) async {
    await _open(tester, _summary(1));

    // 用户可能隔几天才打开 App，得让他知道这是什么时候发生的。
    expect(find.textContaining('2025-2026学年第一学期'), findsOneWidget);
    expect(find.textContaining('2 小时前'), findsOneWidget);
  });

  testWidgets('条目不超过一页时不翻页，只有一个「知道了」', (tester) async {
    await _open(tester, _summary(4));

    expect(find.text('知道了'), findsOneWidget);
    // 课表已经是更新好的状态，没有要用户确认的动作，不该有取消/确定两个键。
    expect(find.text('取消'), findsNothing);
  });

  testWidgets('条目超过一页时分页，第二页显示后面的条目', (tester) async {
    await _open(tester, _summary(6));

    // 第 1 页：课程0..3；第 2 页：课程4、课程5
    expect(find.text('课程0'), findsOneWidget);
    expect(find.text('课程5'), findsNothing);
    expect(find.textContaining('1 / 2'), findsOneWidget);

    await tester.drag(find.text('课程0'), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(find.text('课程5'), findsOneWidget);
    expect(find.textContaining('2 / 2'), findsOneWidget);
  });

  testWidgets('点「知道了」关闭弹窗', (tester) async {
    await _open(tester, _summary(2));

    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    expect(find.text('课表已自动更新'), findsNothing);
  });
}
