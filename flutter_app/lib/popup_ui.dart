import 'dart:math';

import 'package:flutter/material.dart';

const _accent = Color(0xff7963d5),
    _text = Color(0xff302b3c),
    _muted = Color(0xff9990a5),
    _line = Color(0xffe9e5ef);

/// Anchored, keyboard-accessible selection menu shared by every dropdown.
class IeumSelect extends StatefulWidget {
  const IeumSelect({
    super.key,
    required this.value,
    required this.values,
    required this.onChanged,
    this.label,
    this.icon,
    this.colors = const {},
  });
  final String value;
  final Map<String, String> values;
  final ValueChanged<String> onChanged;
  final String? label;
  final IconData? icon;
  final Map<String, Color> colors;

  @override
  State<IeumSelect> createState() => _IeumSelectState();
}

class _IeumSelectState extends State<IeumSelect> {
  final controller = MenuController();
  final focusNode = FocusNode();
  bool open = false;

  @override
  void dispose() {
    focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = min(
        max(constraints.maxWidth, 200.0),
        MediaQuery.sizeOf(context).width - 32,
      );
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.label != null) ...[
            Text(
              widget.label!,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: _muted,
              ),
            ),
            const SizedBox(height: 7),
          ],
          MenuAnchor(
            controller: controller,
            childFocusNode: focusNode,
            consumeOutsideTap: true,
            alignmentOffset: const Offset(0, 6),
            onOpen: () => setState(() => open = true),
            onClose: () {
              if (mounted) setState(() => open = false);
            },
            style: MenuStyle(
              backgroundColor: const WidgetStatePropertyAll(Colors.white),
              surfaceTintColor: const WidgetStatePropertyAll(
                Colors.transparent,
              ),
              shadowColor: WidgetStatePropertyAll(_text.withValues(alpha: .18)),
              elevation: const WidgetStatePropertyAll(16),
              padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
              minimumSize: WidgetStatePropertyAll(Size(width, 0)),
              maximumSize: WidgetStatePropertyAll(Size(width, 300)),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: _line),
                ),
              ),
            ),
            menuChildren: [
              for (final entry in widget.values.entries)
                MenuItemButton(
                  key: ValueKey('option-${entry.key}'),
                  autofocus: entry.key == widget.value,
                  onPressed: () {
                    controller.close();
                    widget.onChanged(entry.key);
                  },
                  style: ButtonStyle(
                    padding: const WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                    ),
                    minimumSize: const WidgetStatePropertyAll(Size(0, 42)),
                    shape: WidgetStatePropertyAll(
                      RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(7),
                      ),
                    ),
                    foregroundColor: WidgetStatePropertyAll(
                      entry.key == widget.value ? _accent : _text,
                    ),
                    backgroundColor: WidgetStateProperty.resolveWith((states) {
                      if (entry.key == widget.value) {
                        return const Color(0xfff0ebfc);
                      }
                      return states.contains(WidgetState.hovered) ||
                              states.contains(WidgetState.focused)
                          ? const Color(0xfff7f5fb)
                          : Colors.transparent;
                    }),
                    textStyle: WidgetStatePropertyAll(
                      TextStyle(
                        fontSize: 12,
                        fontWeight: entry.key == widget.value
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  leadingIcon: widget.colors.containsKey(entry.key)
                      ? Icon(
                          Icons.circle,
                          size: 8,
                          color: widget.colors[entry.key],
                        )
                      : null,
                  trailingIcon: Icon(
                    Icons.check_rounded,
                    size: 16,
                    color: entry.key == widget.value
                        ? _accent
                        : Colors.transparent,
                  ),
                  child: Text(entry.value, overflow: TextOverflow.ellipsis),
                ),
            ],
            builder: (context, controller, child) => Semantics(
              button: true,
              expanded: open,
              label: widget.label,
              child: Material(
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: open ? _accent : _line),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  focusNode: focusNode,
                  onTap: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                  hoverColor: const Color(0xfff8f6fc),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        if (widget.icon != null) ...[
                          Icon(widget.icon, size: 15, color: _accent),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Text(
                            widget.values[widget.value] ?? '',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, color: _text),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          open
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 18,
                          color: open ? _accent : _muted,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

class IeumDialog extends StatelessWidget {
  const IeumDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions = const [],
    this.icon = Icons.auto_awesome_outlined,
    this.width = 540,
  });
  final Widget title, content;
  final List<Widget> actions;
  final IconData icon;
  final double width;

  @override
  Widget build(BuildContext context) => Dialog(
    clipBehavior: Clip.antiAlias,
    insetPadding: const EdgeInsets.all(24),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: width,
        maxHeight: MediaQuery.sizeOf(context).height - 64,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(24, 16, 12, 16),
            decoration: const BoxDecoration(
              color: Color(0xfff7f4fd),
              border: Border(bottom: BorderSide(color: _line)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: const Color(0xffece5fb),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 19, color: _accent),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: DefaultTextStyle.merge(
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: _text,
                    ),
                    child: title,
                  ),
                ),
                IconButton(
                  tooltip: '팝업 닫기',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 19,
                    color: _muted,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: content,
            ),
          ),
          if (actions.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              decoration: const BoxDecoration(
                color: Color(0xfffcfbfe),
                border: Border(top: BorderSide(color: _line)),
              ),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 10,
                runSpacing: 8,
                children: actions,
              ),
            ),
        ],
      ),
    ),
  );
}

class IeumDateDialog extends StatefulWidget {
  const IeumDateDialog({super.key, required this.initialDate});
  final DateTime initialDate;

  @override
  State<IeumDateDialog> createState() => _IeumDateDialogState();
}

class _IeumDateDialogState extends State<IeumDateDialog> {
  late DateTime selected, month;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialDate;
    selected = initial.year < 2000
        ? DateTime(2000)
        : initial.year > 2100
        ? DateTime(2100, 12, 31)
        : DateTime(initial.year, initial.month, initial.day);
    month = DateTime(selected.year, selected.month);
  }

  void shiftMonth(int delta) {
    final target = DateTime(month.year, month.month + delta);
    if (target.year >= 2000 && target.year <= 2100) {
      setState(() => month = target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final first = DateTime(month.year, month.month);
    final offset = first.weekday % 7;
    final days = DateTime(month.year, month.month + 1, 0).day;
    final rows = ((offset + days) / 7).ceil();
    final today = DateUtils.dateOnly(DateTime.now());
    return IeumDialog(
      title: const Text('날짜 선택'),
      icon: Icons.calendar_month_outlined,
      width: 430,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                key: const Key('calendar-previous'),
                tooltip: '이전 달',
                onPressed: month.year == 2000 && month.month == 1
                    ? null
                    : () => shiftMonth(-1),
                icon: const Icon(Icons.chevron_left_rounded, size: 20),
              ),
              Expanded(
                child: IeumSelect(
                  key: const Key('calendar-year'),
                  value: '${month.year}',
                  values: {for (int y = 2000; y <= 2100; y++) '$y': '$y년'},
                  onChanged: (v) => setState(
                    () => month = DateTime(int.parse(v), month.month),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: IeumSelect(
                  key: const Key('calendar-month'),
                  value: '${month.month}',
                  values: {for (int m = 1; m <= 12; m++) '$m': '$m월'},
                  onChanged: (v) => setState(
                    () => month = DateTime(month.year, int.parse(v)),
                  ),
                ),
              ),
              IconButton(
                key: const Key('calendar-next'),
                tooltip: '다음 달',
                onPressed: month.year == 2100 && month.month == 12
                    ? null
                    : () => shiftMonth(1),
                icon: const Icon(Icons.chevron_right_rounded, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              for (final day in ['일', '월', '화', '수', '목', '금', '토'])
                Expanded(
                  child: Center(
                    child: Text(
                      day,
                      style: const TextStyle(fontSize: 11, color: _muted),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          for (int row = 0; row < rows; row++)
            Row(
              children: [
                for (int col = 0; col < 7; col++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: dayCell(row * 7 + col - offset + 1, days, today),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 15),
          Row(
            children: [
              TextButton(
                onPressed: () => setState(() {
                  selected = today;
                  month = DateTime(today.year, today.month);
                }),
                child: const Text('오늘'),
              ),
              const Spacer(),
              Text(
                '${selected.year}.${selected.month.toString().padLeft(2, '0')}.${selected.day.toString().padLeft(2, '0')}',
                style: const TextStyle(fontSize: 12, color: _accent),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const Key('calendar-confirm'),
          onPressed: () => Navigator.pop(context, selected),
          child: const Text('날짜 적용'),
        ),
      ],
    );
  }

  Widget dayCell(int day, int days, DateTime today) {
    if (day < 1 || day > days) return const SizedBox(height: 36);
    final date = DateTime(month.year, month.month, day);
    final chosen = DateUtils.isSameDay(date, selected);
    return SizedBox(
      height: 36,
      child: Material(
        color: chosen ? _accent : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(9),
          side: DateUtils.isSameDay(date, today)
              ? const BorderSide(color: _accent)
              : BorderSide.none,
        ),
        child: InkWell(
          key: ValueKey('calendar-day-${date.year}-${date.month}-$day'),
          borderRadius: BorderRadius.circular(9),
          onTap: () => setState(() => selected = date),
          child: Semantics(
            label: '${date.year}년 ${date.month}월 $day일',
            selected: chosen,
            button: true,
            child: Center(
              child: Text(
                '$day',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: chosen ? FontWeight.w700 : FontWeight.w400,
                  color: chosen
                      ? Colors.white
                      : date.weekday == DateTime.sunday
                      ? const Color(0xffc47c89)
                      : _text,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
