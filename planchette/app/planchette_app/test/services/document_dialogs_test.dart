import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as paths;
import 'package:planchette_app/services/document_dialogs.dart';
import 'package:planchette_app/services/document_workspace.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Records what the dialogs ask the platform for, and answers as a user
/// would.
final class _FakeFileSelector extends FileSelectorPlatform
    with MockPlatformInterfaceMixin {
  List<String> opened = [];
  String? saveAt;
  String? openButton;
  SaveDialogOptions? saveOptions;

  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    openButton = confirmButtonText;
    return [for (final path in opened) XFile(path)];
  }

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    saveOptions = options;
    final path = saveAt;
    return path == null ? null : FileSaveLocation(path);
  }
}

void main() {
  group('file dialogs', () {
    late _FakeFileSelector platform;
    final dialogs = AppDocumentDialogs(GlobalKey<NavigatorState>());

    setUp(() {
      final original = FileSelectorPlatform.instance;
      platform = _FakeFileSelector();
      FileSelectorPlatform.instance = platform;
      addTearDown(() => FileSelectorPlatform.instance = original);
    });

    test('Open returns every chosen path, and nothing for Cancel', () async {
      final notes = paths.absolute('notes.txt');
      final todo = paths.absolute('todo.md');
      platform.opened = [notes, todo];
      expect(await dialogs.pickOpenFiles(), [notes, todo]);
      expect(platform.openButton, 'Open');

      platform.opened = [];
      expect(await dialogs.pickOpenFiles(), isEmpty);
    });

    test('Save As starts beside the file, named after it', () async {
      final current = paths.absolute('docs', 'notes.txt');
      final chosen = paths.absolute('docs', 'renamed.txt');
      platform.saveAt = chosen;
      expect(await dialogs.pickSavePath(current), chosen);
      expect(platform.saveOptions?.suggestedName, 'notes.txt');
      expect(platform.saveOptions?.initialDirectory, paths.absolute('docs'));
      expect(platform.saveOptions?.confirmButtonText, 'Save');
    });

    test('an untitled document suggests its name only', () async {
      expect(await dialogs.pickSavePath('Untitled 2'), isNull);
      expect(platform.saveOptions?.suggestedName, 'Untitled 2');
      expect(platform.saveOptions?.initialDirectory, isNull);
    });
  });

  for (final (button, choice) in [
    ('Cancel', ReadOnlyChoice.cancel),
    ('Save Anyway', ReadOnlyChoice.saveAnyway),
    ('Save As…', ReadOnlyChoice.saveAs),
  ]) {
    testWidgets('the read-only prompt answers $choice for $button', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const SizedBox()),
      );

      final answer = AppDocumentDialogs(
        navigator,
      ).chooseReadOnlySave('locked.txt');
      await tester.pumpAndSettle();
      expect(find.text('“locked.txt” is read-only'), findsOneWidget);
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();

      expect(await answer, choice);
    });
  }

  for (final (button, choice) in [
    ('Don’t Save', BulkCloseChoice.discardAll),
    ('Cancel', BulkCloseChoice.cancel),
    ('Save All', BulkCloseChoice.saveAll),
  ]) {
    testWidgets('the bulk close prompt answers $choice for $button', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const SizedBox()),
      );

      final answer = AppDocumentDialogs(
        navigator,
      ).chooseBulkClose(['a.txt', 'b.txt', 'c.txt']);
      await tester.pumpAndSettle();
      expect(find.text('Save changes to 3 documents?'), findsOneWidget);
      expect(find.textContaining('a.txt\nb.txt\nc.txt'), findsOneWidget);
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();

      expect(await answer, choice);
    });
  }

  testWidgets('the bulk close prompt lists eight names, then a count', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const SizedBox()),
    );
    final dialogs = AppDocumentDialogs(navigator);
    final names = [for (var i = 1; i <= 9; i++) 'doc$i.txt'];

    final eight = dialogs.chooseBulkClose(names.take(8).toList());
    await tester.pumpAndSettle();
    expect(find.textContaining('doc8.txt'), findsOneWidget);
    expect(find.textContaining('more'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await eight, BulkCloseChoice.cancel);

    final nine = dialogs.chooseBulkClose(names);
    await tester.pumpAndSettle();
    expect(find.textContaining('doc8.txt\nand 1 more'), findsOneWidget);
    expect(find.textContaining('doc9.txt'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await nine, BulkCloseChoice.cancel);
  });
}
