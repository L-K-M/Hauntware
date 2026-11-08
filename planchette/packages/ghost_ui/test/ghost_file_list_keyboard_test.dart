import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart';

void main() {
  test('movement bounds, missing cursors, and empty lists', () {
    int? target(GhostFileListCommand command, int? cursor, {int count = 20}) =>
        ghostFileListTargetIndex(
          command,
          currentIndex: cursor,
          itemCount: count,
          pageSize: 5,
        );
    expect(target(GhostFileListCommand.next, null), 0);
    expect(target(GhostFileListCommand.previous, null), 19);
    expect(target(GhostFileListCommand.previous, 0), 0);
    expect(target(GhostFileListCommand.next, 19), 19);
    expect(target(GhostFileListCommand.first, 12), 0);
    expect(target(GhostFileListCommand.last, 2), 19);
    expect(target(GhostFileListCommand.pageNext, 2), 7);
    expect(target(GhostFileListCommand.pagePrevious, 7), 2);
    expect(target(GhostFileListCommand.pageNext, 18), 19);
    expect(target(GhostFileListCommand.pagePrevious, 2), 0);
    expect(target(GhostFileListCommand.pageNext, null), 0);
    expect(target(GhostFileListCommand.pagePrevious, null), 19);
    expect(target(GhostFileListCommand.next, 30), 0);
    expect(target(GhostFileListCommand.next, null, count: 0), isNull);
    expect(target(GhostFileListCommand.open, 2), isNull);
  });

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.windows,
  ]) {
    testWidgets('exact file chords on $platform', (tester) async {
      GhostFileListKey? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Focus(
            autofocus: true,
            onKeyEvent: (_, event) {
              if (event is! KeyUpEvent) {
                result = ghostFileListKey(event, platform, canRename: true);
              }
              return KeyEventResult.handled;
            },
            child: const SizedBox(),
          ),
        ),
      );
      await tester.pump();
      Future<void> chord(
        LogicalKeyboardKey key, {
        List<LogicalKeyboardKey> modifiers = const [],
      }) async {
        for (final modifier in modifiers) {
          await tester.sendKeyDownEvent(modifier);
        }
        await tester.sendKeyEvent(key);
        for (final modifier in modifiers.reversed) {
          await tester.sendKeyUpEvent(modifier);
        }
      }

      await chord(LogicalKeyboardKey.arrowDown);
      expect(result?.command, GhostFileListCommand.next);
      expect(result?.extendSelection, isFalse);
      await chord(
        LogicalKeyboardKey.pageUp,
        modifiers: [LogicalKeyboardKey.shiftLeft],
      );
      expect(result?.command, GhostFileListCommand.pagePrevious);
      expect(result?.extendSelection, isTrue);
      await chord(LogicalKeyboardKey.end);
      expect(result?.command, GhostFileListCommand.last);
      await chord(LogicalKeyboardKey.home);
      expect(result?.command, GhostFileListCommand.first);
      final modifier = platform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.altLeft;
      await chord(LogicalKeyboardKey.arrowUp, modifiers: [modifier]);
      expect(result?.command, GhostFileListCommand.parent);
      await chord(LogicalKeyboardKey.arrowDown, modifiers: [modifier]);
      expect(
        result?.command,
        platform == TargetPlatform.macOS ? GhostFileListCommand.open : null,
      );
      await chord(LogicalKeyboardKey.enter);
      expect(
        result?.command,
        platform == TargetPlatform.macOS
            ? GhostFileListCommand.rename
            : GhostFileListCommand.open,
      );
      await chord(LogicalKeyboardKey.numpadEnter);
      expect(
        result?.command,
        platform == TargetPlatform.macOS
            ? GhostFileListCommand.rename
            : GhostFileListCommand.open,
      );
      await chord(
        LogicalKeyboardKey.keyA,
        modifiers: [
          platform == TargetPlatform.macOS
              ? LogicalKeyboardKey.metaLeft
              : LogicalKeyboardKey.controlLeft,
        ],
      );
      expect(result?.command, GhostFileListCommand.selectAll);
      await chord(
        LogicalKeyboardKey.arrowDown,
        modifiers: [LogicalKeyboardKey.controlLeft],
      );
      expect(result, isNull);
      await chord(
        LogicalKeyboardKey.arrowUp,
        modifiers: [LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.altLeft],
      );
      expect(result, isNull);
      await chord(
        LogicalKeyboardKey.enter,
        modifiers: [LogicalKeyboardKey.shiftLeft],
      );
      expect(result, isNull);
      await chord(
        LogicalKeyboardKey.f10,
        modifiers: [LogicalKeyboardKey.shiftLeft],
      );
      expect(result?.command, GhostFileListCommand.contextMenu);
    });
  }

  testWidgets('scroll reveal accounts for a scrolling header', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            height: 105,
            child: CustomScrollView(
              controller: scroll,
              slivers: [
                const SliverToBoxAdapter(child: SizedBox(height: 60)),
                SliverFixedExtentList(
                  itemExtent: 20,
                  delegate: SliverChildBuilderDelegate(
                    (_, index) => Text('$index'),
                    childCount: 100,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    ghostRevealFileListIndex(scroll, 99, 20, leadingExtent: 60);
    await tester.pump();
    expect(scroll.offset, scroll.position.maxScrollExtent);
    ghostRevealFileListIndex(scroll, 0, 20, leadingExtent: 60);
    await tester.pump();
    expect(scroll.offset, 60);
  });

  testWidgets('scroll reveal stays inside the scroll range', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            height: 105,
            child: ListView.builder(
              controller: scroll,
              itemCount: 100,
              itemExtent: 20,
              itemBuilder: (_, index) => Text('$index'),
            ),
          ),
        ),
      ),
    );
    ghostRevealFileListIndex(scroll, 99, 20);
    await tester.pump();
    expect(scroll.offset, scroll.position.maxScrollExtent);
    ghostRevealFileListIndex(scroll, 0, 20);
    await tester.pump();
    expect(scroll.offset, 0);
  });
}
