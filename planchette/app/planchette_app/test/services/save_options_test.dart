import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/app_settings.dart';
import 'package:planchette_app/services/document_workspace.dart';
import 'package:planchette_app/services/settings_dialog.dart';
import 'package:planchette_editor/planchette_editor.dart';

import '../services/document_workspace_test.dart'
    show FakeDialogs, MemoryDocuments;
import '../services/memory_settings.dart';

// Slice 6: save normalization as user choices, applied to current and later
// editors. Core owns TextSaveOptions; the app only persists and forwards it.
void main() {
  group('AppSettings.saveOptions', () {
    test('defaults leave the buffer alone', () {
      const options = TextSaveOptions();
      expect(options.trailingWhitespace, TrailingWhitespacePolicy.preserve);
      expect(options.finalNewline, FinalNewlinePolicy.preserve);
      expect(const AppSettings().saveOptions, options);
    });

    test('round-trips through JSON bools', () {
      const settings = AppSettings(
        saveOptions: TextSaveOptions(
          trailingWhitespace: TrailingWhitespacePolicy.trim,
          finalNewline: FinalNewlinePolicy.ensure,
        ),
      );
      final json = settings.toJson();
      expect(json['trimTrailingWhitespaceOnSave'], isTrue);
      expect(json['ensureFinalNewline'], isTrue);
      expect(AppSettings.fromJson(json), settings);
    });

    test('missing keys stay off', () {
      expect(
        AppSettings.fromJson(const {'fontSize': 15}).saveOptions,
        const TextSaveOptions(),
      );
      expect(AppSettings.fromJson(null).saveOptions, const TextSaveOptions());
    });

    test('a non-bool flag falls back rather than failing the file', () {
      expect(
        AppSettings.fromJson(const {
          'trimTrailingWhitespaceOnSave': 'yes',
        }).saveOptions,
        const TextSaveOptions(),
      );
      expect(
        AppSettings.fromJson(const {'ensureFinalNewline': 1}).saveOptions,
        const TextSaveOptions(),
      );
    });

    test('a malformed flag does not discard the other valid flag', () {
      final settings = AppSettings.fromJson(const {
        'trimTrailingWhitespaceOnSave': 'bad',
        'ensureFinalNewline': true,
      });
      expect(
        settings.saveOptions.trailingWhitespace,
        TrailingWhitespacePolicy.preserve,
      );
      expect(settings.saveOptions.finalNewline, FinalNewlinePolicy.ensure);
    });

    test('equality sees the flags', () {
      expect(
        const AppSettings(),
        isNot(
          const AppSettings(
            saveOptions: TextSaveOptions(
              trailingWhitespace: TrailingWhitespacePolicy.trim,
            ),
          ),
        ),
      );
    });
  });

  group('SettingsController saveOptions', () {
    test('a stored choice comes back', () async {
      final store = MemorySettings();
      final settings = SettingsController(store: store);
      addTearDown(settings.dispose);
      await settings.load();
      await settings.update(
        settings.value.copyWith(
          saveOptions: const TextSaveOptions(
            trailingWhitespace: TrailingWhitespacePolicy.trim,
            finalNewline: FinalNewlinePolicy.ensure,
          ),
        ),
      );
      await settings.flush();
      expect(
        (await store.load())?.saveOptions.trailingWhitespace,
        TrailingWhitespacePolicy.trim,
      );
      expect(
        (await store.load())?.saveOptions.finalNewline,
        FinalNewlinePolicy.ensure,
      );
    });
  });

  group('settings shell', () {
    late DocumentWorkspace workspace;
    late MemorySettings store;
    late SettingsController settings;

    setUp(() async {
      workspace = DocumentWorkspace(
        store: MemoryDocuments(),
        dialogs: FakeDialogs(),
      );
      store = MemorySettings();
      settings = SettingsController(store: store);
      addTearDown(settings.dispose);
      await settings.load();
    });
    tearDown(() => workspace.dispose());

    Future<void> mount(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        PlanchetteApp(workspace: workspace, settings: settings),
      );
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pumpAndSettle();
    }

    Future<void> openSettings(WidgetTester tester) async {
      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings…'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDialog), findsOneWidget);
    }

    testWidgets('toggling a save flag and Done keeps it', (tester) async {
      workspace.newDocument();
      await mount(tester);
      await openSettings(tester);

      await tester.tap(find.text('Trim trailing whitespace on save'));
      await tester.pumpAndSettle();
      expect(
        settings.value.saveOptions.trailingWhitespace,
        TrailingWhitespacePolicy.trim,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pumpAndSettle();
      await settings.flush();
      expect(
        (await store.load())?.saveOptions.trailingWhitespace,
        TrailingWhitespacePolicy.trim,
      );
    }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

    testWidgets('Cancel puts the save flags back', (tester) async {
      workspace.newDocument();
      await mount(tester);
      await openSettings(tester);

      await tester.tap(find.text('Trim trailing whitespace on save'));
      await tester.tap(find.text('Ensure final newline on save'));
      await tester.pumpAndSettle();
      expect(settings.value.saveOptions, isNot(const TextSaveOptions()));

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(settings.value.saveOptions, const TextSaveOptions());
    }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

    testWidgets('a stored choice reaches current and later editors', (
      tester,
    ) async {
      final current = workspace.newDocument()!;
      await mount(tester);
      const options = TextSaveOptions(
        trailingWhitespace: TrailingWhitespacePolicy.trim,
        finalNewline: FinalNewlinePolicy.ensure,
      );
      await settings.update(settings.value.copyWith(saveOptions: options));
      await tester.pumpAndSettle();
      expect(workspace.saveOptions, options);
      expect(current.editor.saveOptions, options);

      final later = workspace.newDocument()!;
      await tester.pumpAndSettle();
      expect(workspace.saveOptions, options);
      expect(later.editor.saveOptions, options);
    });
  });
}
