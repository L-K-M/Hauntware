import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

void main() {
  testWidgets(
    'desktop selection menus show glyphs and copy the selection',
    (tester) async {
      final controller = EditorController(
        displayPath: 'notes.txt',
        initialText: 'selected text',
      );
      addTearDown(controller.dispose);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PlanchetteEditor(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byType(EditableText),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      controller.text.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 8,
      );
      await tester.pump();
      await tester.tapAt(
        tester.getTopLeft(find.byType(EditableText)) + const Offset(35, 20),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('Copy'), findsOneWidget);

      final copy = find.ancestor(
        of: find.text('Copy'),
        matching: find.byType(MenuItemButton),
      );
      expect(copy, findsOneWidget);
      expect(tester.getSize(copy).height, 26);
      expect(
        find.descendant(of: copy, matching: find.byIcon(Icons.copy)),
        findsOneWidget,
      );
      final apple =
          Theme.of(tester.element(copy)).platform == TargetPlatform.macOS;
      expect(find.text(apple ? '⌘C' : 'Ctrl+C'), findsOneWidget);
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(copied, 'selected');
      expect(find.byType(MenuItemButton), findsNothing);
      expect(controller.editorFocus.hasFocus, isTrue);

      await tester.tapAt(
        tester.getTopLeft(find.byType(EditableText)) + const Offset(35, 20),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsWidgets);
      await tester.tapAt(const Offset(700, 500), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'locked documents offer copy without editing actions',
    (tester) async {
      final controller = EditorController(
        displayPath: 'locked.txt',
        initialText: 'read only',
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlanchetteEditor(controller: controller, editingLocked: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byType(EditableText),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      controller.text.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 4,
      );
      await tester.pump();
      await tester.tapAt(
        tester.getTopLeft(find.byType(EditableText)) + const Offset(25, 20),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Cut'), findsNothing);
      expect(find.text('Paste'), findsNothing);
      expect(controller.text.text, 'read only');
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.linux,
    }),
  );

  testWidgets(
    'touch retains the adaptive selection toolbar',
    (tester) async {
      final controller = EditorController(
        displayPath: 'touch.txt',
        initialText: 'touch text',
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PlanchetteEditor(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.longPressAt(
        tester.getTopLeft(find.byType(EditableText)) + const Offset(35, 20),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
      expect(find.byType(MenuItemButton), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );
}
