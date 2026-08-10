import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheretosleepinnju/Models/CourseModel.dart';
import 'package:wheretosleepinnju/Pages/CourseTable/Widgets/CourseWidget.dart';
import 'package:wheretosleepinnju/generated/l10n.dart';

const double _kCellWidth = 100;
const double _kRowHeight = 50;

Course _course({String name = '高等数学', int weekTime = 2, int startTime = 3}) =>
    Course(1, name, '[1]', weekTime, startTime, 1, 1, classroom: '仙Ⅰ-101');

Future<Rect> _pumpSlot(
  WidgetTester tester, {
  required int slotIndex,
  required int slotCount,
  int hiddenCount = 0,
  VoidCallback? onTap,
}) async {
  final Course course = _course();
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: const [
      S.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: S.delegate.supportedLocales,
    home: Scaffold(
      body: Stack(children: [
        CourseWidget(
          course,
          '#8AD297',
          '#CCCCCC',
          _kRowHeight,
          _kCellWidth,
          true,
          false,
          onTap,
          null,
          slotIndex: slotIndex,
          slotCount: slotCount,
          hiddenCount: hiddenCount,
        ),
      ]),
    ),
  ));
  await tester.pumpAndSettle();
  // 量内层 InkWell 而不是 CourseWidget 本身：外层 Container 的 margin 算在
  // 它自己的布局盒子里，量外层拿到的是"外边距 + 色块"的合并尺寸，不是色块
  // 实际占多宽。
  return tester.getRect(find.byType(InkWell));
}

/// 外层 Container 的 padding，色块四周各留这么多，两块并排时中间的细缝
/// 就是两边 padding 相加。
const double _kPad = 0.5;

/// 钉住"重叠课程横向分栏"这条渲染约定：不重叠时占满整格，两门重叠时各占
/// 一半且左右错开。这里量的是实际渲染出来的几何尺寸，不是参数本身——
/// 之前 margin/width 的算法改动如果算错，只有量尺寸才看得出来。
void main() {
  testWidgets('不分栏时占满整格宽度', (tester) async {
    final rect = await _pumpSlot(tester, slotIndex: 0, slotCount: 1);

    expect(rect.width, _kCellWidth - _kPad * 2);
    // weekTime = 2 -> 左边空出一整格
    expect(rect.left, _kCellWidth + _kPad);
  });

  testWidgets('两门重叠时各占一半，且左右错开不重叠', (tester) async {
    final left = await _pumpSlot(tester, slotIndex: 0, slotCount: 2);
    final right = await _pumpSlot(tester, slotIndex: 1, slotCount: 2);

    const double halfCell = _kCellWidth / 2;
    expect(left.width, halfCell - _kPad * 2);
    expect(right.width, halfCell - _kPad * 2);

    // 左半块贴着格子左边，右半块接在半格处，两块合起来铺满这一格。
    expect(left.left, _kCellWidth + _kPad);
    expect(right.left, _kCellWidth + halfCell + _kPad);
    expect(right.left, greaterThan(left.right), reason: '两块不能重叠');
    expect(right.right, _kCellWidth + _kCellWidth - _kPad);
  });

  testWidgets('纵向位置和高度不受分栏影响', (tester) async {
    final full = await _pumpSlot(tester, slotIndex: 0, slotCount: 1);
    final half = await _pumpSlot(tester, slotIndex: 1, slotCount: 2);

    expect(half.top, full.top);
    expect(half.height, full.height);
  });

  testWidgets('hiddenCount 大于 0 时画出 +N 角标，且仍占满整格', (tester) async {
    // 三门及以上重叠时的实际用法：只画一门、占满整格、右上角带角标。
    final rect =
        await _pumpSlot(tester, slotIndex: 0, slotCount: 1, hiddenCount: 2);

    expect(find.text('+2'), findsOneWidget);
    expect(rect.width, _kCellWidth - _kPad * 2);
  });

  testWidgets('hiddenCount 为 0 时没有角标', (tester) async {
    await _pumpSlot(tester, slotIndex: 0, slotCount: 2);
    expect(find.textContaining('+'), findsNothing);
  });

  testWidgets('点在角标上也能触发点击，不会被角标挡住', (tester) async {
    // 三门以上重叠时，整块的点击绑的是"翻看整组"，角标只是标记；正好点
    // 在角标上如果被挡住，用户就打不开那个滑动详情了。
    int taps = 0;
    await _pumpSlot(
      tester,
      slotIndex: 0,
      slotCount: 1,
      hiddenCount: 2,
      onTap: () => taps++,
    );

    // 按坐标点，而不是 tap(find.text(...))：角标被 IgnorePointer 包着，
    // 本来就不该自己接住点击，要的就是点在它上面时穿透到底下的块。
    await tester.tapAt(tester.getCenter(find.text('+2')));
    await tester.pumpAndSettle();

    expect(taps, 1);
  });
}
