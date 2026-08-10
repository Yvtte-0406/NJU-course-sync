import '../../../generated/l10n.dart';
import 'package:flutter/material.dart';
import '../../../Models/CourseModel.dart';
import '../../../Utils/ColorUtil.dart';

class CourseWidget extends StatelessWidget {
  final Course course;
  final String color;
  final String mutedColor;
  final double height;
  final double width;
  final bool isActive;
  final bool setFlag;
  final GestureTapCallback? onTap;
  final GestureLongPressCallback? onLongPress;

  /// 同一格子里有多门课重叠时，这门课占第几列、这一格一共分成几列。
  /// 不重叠就是 0 / 1，跟以前一样占满整格。
  final int slotIndex;
  final int slotCount;

  /// 这一组里没能并排显示、被折叠掉的课程数。大于 0 时右上角画一个
  /// "+N" 角标，点这一块可以翻看整组。
  final int hiddenCount;

  const CourseWidget(this.course, this.color, this.mutedColor, this.height,
      this.width, this.isActive, this.setFlag, this.onTap, this.onLongPress,
      {Key? key,
      this.slotIndex = 0,
      this.slotCount = 1,
      this.hiddenCount = 0})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    final double slotWidth = width / slotCount;
    return Container(
      margin: EdgeInsets.only(
          top: (course.startTime! - 1) * height,
          left: (course.weekTime! - 1) * width + slotIndex * slotWidth),
      padding: const EdgeInsets.all(0.5),
      height: (course.timeCount! + 1) * height,
      width: slotWidth,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Container(
              // 分栏之后每块更窄，文字更容易顶出边界；裁掉超出的部分，
              // 免得压到隔壁那门课上。
              clipBehavior: Clip.hardEdge,
              decoration: BoxDecoration(
                color: HexColor(isActive ? color : mutedColor).withOpacity(0.9),
                // TODO: Needs to be improved
                borderRadius: setFlag
                    ? const BorderRadius.only(
                        topLeft: Radius.circular(7),
                        bottomLeft: Radius.circular(7),
                        bottomRight: Radius.circular(7))
                    : const BorderRadius.all(Radius.circular(7)),
              ),
              child: InkWell(
                  borderRadius: const BorderRadius.all(Radius.circular(5)),
                  highlightColor: Colors.black,
                  onLongPress: onLongPress,
                  onTap: onTap,
                  child: RichText(
                    text: TextSpan(
                      style: const TextStyle(
                        fontSize: 12.0,
                        color: Colors.white,
                      ),
                      children: <TextSpan>[
                        TextSpan(
                            text: (isActive ? '' : S.of(context).not_this_week) +
                                course.name!,
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                        TextSpan(
                            text: S.of(context).at +
                                (course.classroom ??
                                    S.of(context).unknown_place)),
                      ],
                    ),
                  )),
            ),
          ),
          if (hiddenCount > 0)
            // 角标只是个标记，不该挡住点击——正好点在它上面时也要能落到
            // 底下的块上，打开整组的滑动浏览。
            Positioned(
              top: 2,
              right: 2,
              child: IgnorePointer(child: _buildOverflowBadge()),
            ),
        ],
      ),
    );
  }

  /// "+N" 角标：这一格还有几门课没显示出来。白底 + 深色粗字 + 描边阴影，
  /// 保证压在任何一套配色的课程色块上都一眼看得见。
  Widget _buildOverflowBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.black26, width: 0.5),
        boxShadow: const [
          BoxShadow(color: Colors.black38, blurRadius: 2, offset: Offset(0, 1)),
        ],
      ),
      child: Text(
        '+$hiddenCount',
        style: const TextStyle(
          fontSize: 9,
          height: 1.1,
          fontWeight: FontWeight.bold,
          color: Colors.black87,
        ),
      ),
    );
  }
}
