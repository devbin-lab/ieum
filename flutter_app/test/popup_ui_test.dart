import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/popup_ui.dart';

void main() {
  testWidgets(
    'custom menu selects values and dismisses without accidental taps',
    (tester) async {
      var selected = 'normal';
      var outsideTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, update) => Scaffold(
              body: Column(
                children: [
                  SizedBox(
                    width: 220,
                    child: IeumSelect(
                      key: const Key('select'),
                      label: '우선순위',
                      value: selected,
                      values: const {'high': '높음', 'normal': '보통', 'low': '낮음'},
                      onChanged: (value) => update(() => selected = value),
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    key: const Key('outside'),
                    onPressed: () => outsideTaps++,
                    child: const Text('바깥 버튼'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('select')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('option-high')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('option-high')));
      await tester.pumpAndSettle();
      expect(selected, 'high');
      expect(find.byKey(const ValueKey('option-high')), findsNothing);

      await tester.tap(find.byKey(const Key('select')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('outside')));
      await tester.pumpAndSettle();
      expect(outsideTaps, 0);
      expect(find.byKey(const ValueKey('option-low')), findsNothing);

      await tester.tap(find.byKey(const Key('select')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('option-low')), findsNothing);
      expect(selected, 'high');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('custom calendar navigates leap day and confirms chosen date', (
    tester,
  ) async {
    DateTime? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const Key('open-calendar'),
              onPressed: () async {
                result = await showDialog<DateTime>(
                  context: context,
                  builder: (_) =>
                      IeumDateDialog(initialDate: DateTime(2024, 1, 31)),
                );
              },
              child: const Text('날짜'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-calendar')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('calendar-next')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('calendar-day-2024-2-29')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('calendar-day-2024-2-30')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('calendar-day-2024-2-29')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('calendar-confirm')));
    await tester.pumpAndSettle();
    expect(result, DateTime(2024, 2, 29));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'calendar limits navigation and cancellation keeps original date',
    (tester) async {
      DateTime? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<DateTime>(
                    context: context,
                    builder: (_) => IeumDateDialog(initialDate: DateTime(1800)),
                  );
                },
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('calendar-previous')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('calendar-year')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('option-2000')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
