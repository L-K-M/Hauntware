import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as paths;
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/app_settings.dart';
import 'package:planchette_app/services/document_store.dart';
import 'package:planchette_app/services/document_workspace.dart';
import 'package:planchette_app/services/recent_documents.dart';

import 'services/document_workspace_test.dart'
    show MemoryDocuments, FakeDialogs, document, testPath;
import 'services/memory_settings.dart';

void main() {
  group('AppSettings recent documents', () {
    test('put the newest first, once, up to the limit', () {
      var settings = const AppSettings();
      for (var i = 0; i < AppSettings.maximumRecentDocuments + 3; i++) {
        settings = settings.withRecentDocument(testPath('$i.txt'));
      }
      settings = settings.withRecentDocument(testPath('5.txt'));

      expect(
        settings.recentDocuments,
        hasLength(AppSettings.maximumRecentDocuments),
      );
      expect(settings.recentDocuments.first, testPath('5.txt'));
      expect(
        settings.recentDocuments.where((path) => path == testPath('5.txt')),
        hasLength(1),
      );
      expect(settings.recentDocuments, isNot(contains(testPath('0.txt'))));
    });

    test('survive a round trip and drop what cannot be reopened', () {
      final stored = const AppSettings()
          .withRecentDocument(testPath('a.txt'))
          .toJson();
      expect(AppSettings.fromJson(stored).recentDocuments, [testPath('a.txt')]);

      final edited = AppSettings.fromJson({
        'recentDocuments': [
          testPath('b.txt'),
          'relative.txt',
          42,
          testPath('b.txt'),
        ],
      });
      expect(edited.recentDocuments, [testPath('b.txt')]);
      expect(
        AppSettings.fromJson({'recentDocuments': 'x'}).recentDocuments,
        isEmpty,
      );
    });

    test('compare by their recent documents', () {
      final one = const AppSettings().withRecentDocument(testPath('a.txt'));
      final same = const AppSettings().withRecentDocument(testPath('a.txt'));
      expect(one, same);
      expect(one.hashCode, same.hashCode);
      expect(one, isNot(const AppSettings()));
    });
  });

  group('Open Recent', () {
    late MemoryDocuments store;
    late DocumentWorkspace workspace;
    setUp(() {
      store = MemoryDocuments();
      workspace = DocumentWorkspace(store: store, dialogs: FakeDialogs());
    });
    tearDown(() => workspace.dispose());

    Future<SettingsController> mount(
      WidgetTester tester, {
      List<String> recent = const [],
    }) async {
      await tester.binding.setSurfaceSize(const Size(1000, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final settings = testSettings(
        initial: AppSettings(
          themeMode: ThemeMode.light,
          recentDocuments: recent,
        ),
      );
      await tester.pumpWidget(
        PlanchetteApp(workspace: workspace, settings: settings),
      );
      await tester.pumpAndSettle();
      return settings;
    }

    List<PlatformMenuItem> recentRows(WidgetTester tester) {
      final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
      final file = bar.menus.whereType<PlatformMenu>().firstWhere(
        (menu) => menu.label == 'File',
      );
      Iterable<PlatformMenuItem> all(Iterable<PlatformMenuItem> items) =>
          items.expand(
            (entry) => switch (entry) {
              PlatformMenuItemGroup(:final members) => all(members),
              _ => [entry],
            },
          );
      final submenu = all(file.menus).whereType<PlatformMenu>().firstWhere(
        (menu) => menu.label == 'Open Recent',
      );
      return all(submenu.menus).toList();
    }

    PlatformMenuItem row(WidgetTester tester, String label) =>
        recentRows(tester).firstWhere((item) => item.label == label);

    // The folder check reads the real disk, which fake time cannot wait for,
    // so real time passes until the outcome is reported, within a bound.
    Future<void> chooseOnDisk(WidgetTester tester, String label) async {
      await tester.runAsync(() async {
        row(tester, label).onSelected!();
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (workspace.error == null && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      await tester.pumpAndSettle();
    }

    testWidgets('lists a file once it has opened', (tester) async {
      store.files[testPath('a.txt')] = document('a.txt', 'hi');
      final settings = await mount(tester);
      expect(row(tester, 'No Recent Documents').onSelected, isNull);

      await workspace.open(testPath('a.txt'));
      await tester.pumpAndSettle();

      expect(settings.value.recentDocuments, [testPath('a.txt')]);
      expect(recentRows(tester).map((item) => item.label), [
        'a.txt',
        'Clear Menu',
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('records the path a Save As gives a tab', (tester) async {
      final settings = await mount(tester);
      final tab = workspace.newDocument()!..editor.text.text = 'new';
      (workspace.dialogs as FakeDialogs).savePath = testPath('saved.txt');
      await tester.pumpAndSettle();

      expect(await workspace.save(tab, saveAs: true), isTrue);
      await tester.pumpAndSettle();

      expect(settings.value.recentDocuments, [testPath('saved.txt')]);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('opens the chosen file', (tester) async {
      store.files[testPath('b.txt')] = document('b.txt', 'bee');
      await mount(tester, recent: [testPath('b.txt')]);

      row(tester, 'b.txt').onSelected!();
      await tester.pumpAndSettle();

      expect(workspace.active?.path, testPath('b.txt'));
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('names the folder when two entries share a name', (
      tester,
    ) async {
      final other = paths.join(testPath('nested'), 'b.txt');
      await mount(tester, recent: [testPath('b.txt'), other]);

      expect(
        recentRows(tester).map((item) => item.label),
        containsAll([
          'b.txt (${paths.dirname(testPath('b.txt'))})',
          'b.txt (${testPath('nested')})',
        ]),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('removes a file that is gone and says so', (tester) async {
      final settings = await mount(tester, recent: [testPath('gone.txt')]);

      await chooseOnDisk(tester, 'gone.txt');

      expect(settings.value.recentDocuments, isEmpty);
      expect(workspace.documents, isEmpty);
      expect(workspace.error, contains('removed from Open Recent'));
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('keeps a file whose folder is not available', (tester) async {
      final unmounted = paths.join(
        testPath('planchette-no-such-volume'),
        'c.txt',
      );
      final settings = await mount(tester, recent: [unmounted]);

      await chooseOnDisk(tester, 'c.txt');

      expect(settings.value.recentDocuments, [unmounted]);
      expect(workspace.error, contains('is not available'));
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('Clear Menu forgets every file', (tester) async {
      final settings = await mount(
        tester,
        recent: [testPath('a.txt'), testPath('b.txt')],
      );

      row(tester, 'Clear Menu').onSelected!();
      await tester.pumpAndSettle();

      expect(settings.value.recentDocuments, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('the empty window offers the newest files', (tester) async {
      store.files[testPath('b.txt')] = document('b.txt', 'bee');
      await mount(tester, recent: [testPath('b.txt')]);

      await tester.tap(find.widgetWithText(TextButton, 'b.txt'));
      await tester.pumpAndSettle();

      expect(workspace.active?.path, testPath('b.txt'));
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('Android keeps no list', (tester) async {
      store.files[testPath('a.txt')] = document('a.txt', 'hi');
      final settings = await mount(tester);

      await workspace.open(testPath('a.txt'));
      await tester.pumpAndSettle();

      expect(settings.value.recentDocuments, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });
  group('recentDocumentState', () {
    // Root reads any folder, so the refusal needs an ordinary user; Windows
    // has no chmod.
    final unrestricted =
        Platform.isWindows ||
        (Process.runSync('id', ['-u']).stdout as String).trim() == '0';

    test('a folder it may not look into is not available', () async {
      final directory = await Directory.systemTemp.createTemp(
        'planchette-recent-',
      );
      final locked = Directory(paths.join(directory.path, 'locked'));
      final folder = Directory(paths.join(locked.path, 'notes'));
      await folder.create(recursive: true);
      await Process.run('chmod', ['000', locked.path]);
      addTearDown(() async {
        await Process.run('chmod', ['700', locked.path]);
        await directory.delete(recursive: true);
      });

      expect(
        await recentDocumentState(
          LocalDocumentStore(),
          paths.join(folder.path, 'a.txt'),
        ),
        RecentDocumentState.folderUnavailable,
      );
    }, skip: unrestricted ? 'needs a non-root POSIX user' : false);
  });
}
