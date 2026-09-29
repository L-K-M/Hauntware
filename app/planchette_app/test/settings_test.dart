import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/app_settings.dart';
import 'package:planchette_app/services/document_workspace.dart';
import 'package:planchette_app/services/settings_dialog.dart';
import 'package:planchette_editor/planchette_editor.dart';

import 'services/document_workspace_test.dart'
    show FakeDialogs, MemoryDocuments;
import 'services/memory_settings.dart';

// Ported from #37, whose settings were rebuilt on #14's indentation and
// #30's fonts; the tests marked as review fixes failed on #37's own code.
void main() {
  late DocumentWorkspace workspace;
  late MemorySettings settingsStore;
  late SettingsController settings;

  setUp(() async {
    workspace = DocumentWorkspace(
      store: MemoryDocuments(),
      dialogs: FakeDialogs(),
    );
    settingsStore = MemorySettings();
    settings = SettingsController(store: settingsStore);
    addTearDown(settings.dispose);
    await settings.load();
  });
  tearDown(() => workspace.dispose());

  Future<void> mount(WidgetTester tester, {ThemeMode? mode}) async {
    if (mode != null) {
      await settings.update(settings.value.copyWith(themeMode: mode));
    }
    await tester.binding.setSurfaceSize(const Size(1000, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      PlanchetteApp(workspace: workspace, settings: settings),
    );
    // The shell listens to the global FocusManager, so the tree has to be torn
    // down before the next test rather than left for the binding to discard.
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

  Brightness brightnessOf(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(Scaffold))).brightness;

  TextStyle documentStyle(WidgetTester tester) => tester
      .widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('planchette.document')),
          matching: find.byType(EditableText),
        ),
      )
      .style;

  testWidgets('the stored theme mode is what the window uses', (tester) async {
    await mount(tester, mode: ThemeMode.dark);
    expect(brightnessOf(tester), Brightness.dark);
  });

  testWidgets('changing the settings re-themes a mounted window', (
    tester,
  ) async {
    await mount(tester, mode: ThemeMode.light);
    await settings.update(settings.value.copyWith(themeMode: ThemeMode.dark));
    await tester.pumpAndSettle();
    expect(brightnessOf(tester), Brightness.dark);
  });

  testWidgets('a stored text size reaches every document, then and later', (
    tester,
  ) async {
    await settings.update(settings.value.copyWith(fontSize: 24));
    workspace.newDocument();
    await mount(tester);
    expect(documentStyle(tester).fontSize, 24);

    await settings.update(settings.value.copyWith(fontSize: 20));
    await tester.pumpAndSettle();
    expect(documentStyle(tester).fontSize, 20);
  });

  testWidgets('review fix: the document keeps the platform monospace face', (
    tester,
  ) async {
    // #37 listed the monospace faces only as fallbacks, so the document
    // rendered in the proportional UI font.
    workspace.newDocument();
    await mount(tester);
    expect(
      documentStyle(tester).fontFamily,
      editorMonospaceFor(defaultTargetPlatform).fontFamily,
    );
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('review fix: documents made after mount take the indentation', (
    tester,
  ) async {
    // #37 pushed the indentation only into tabs open when the shell mounted,
    // and the first document is created after that.
    await settings.update(
      settings.value.copyWith(indentation: const Indentation.spaces(2)),
    );
    await mount(tester);
    final tab = workspace.newDocument()!;
    expect(tab.editor.indentation, const Indentation.spaces(2));

    await settings.update(
      settings.value.copyWith(indentation: const Indentation.tabs()),
    );
    await tester.pumpAndSettle();
    expect(tab.editor.indentation, const Indentation.tabs());
  });

  testWidgets('a file that indents its own way keeps it', (tester) async {
    await settings.update(
      settings.value.copyWith(indentation: const Indentation.tabs()),
    );
    await mount(tester);
    final tab = workspace.newDocument()!
      ..editor.text.text = 'a:\n  b: 1\n  c: 2\n';
    expect(tab.editor.indentation, const Indentation.spaces(2));
  });

  testWidgets('the dialog applies a theme at once and Done keeps it', (
    tester,
  ) async {
    workspace.newDocument();
    await mount(tester, mode: ThemeMode.light);
    await openSettings(tester);

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(brightnessOf(tester), Brightness.dark);
    expect(settings.value.themeMode, ThemeMode.dark);

    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsNothing);
    await settings.flush();
    expect((await settingsStore.load())?.themeMode, ThemeMode.dark);
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('cancelling the dialog puts the settings back', (tester) async {
    workspace.newDocument();
    await mount(tester, mode: ThemeMode.light);
    await openSettings(tester);
    await tester.tap(find.text('Dark'));
    await tester.tap(find.text('Tabs'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(settings.value.themeMode, ThemeMode.light);
    expect(settings.value.indentation, const Indentation.spaces());
    expect(brightnessOf(tester), Brightness.light);
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('review fix: a click outside the dialog keeps it open', (
    tester,
  ) async {
    // Dismissing on the barrier kept a previewed size without a word.
    workspace.newDocument();
    await mount(tester);
    await openSettings(tester);
    await tester.tapAt(const Offset(10, 700));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsOneWidget);
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('the size slider previews live and Done saves it', (
    tester,
  ) async {
    workspace.newDocument();
    await mount(tester);
    await openSettings(tester);
    await tester.tap(find.byType(Slider).first);
    await tester.pumpAndSettle();
    final chosen = settings.value.fontSize;
    expect(chosen, isNot(AppSettings.defaultFontSize));
    expect(documentStyle(tester).fontSize, chosen);

    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();
    await settings.flush();
    expect((await settingsStore.load())?.fontSize, chosen);
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('View › Zoom changes the stored text size', (tester) async {
    workspace.newDocument();
    await mount(tester);
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zoom In'));
    await tester.pumpAndSettle();
    await settings.flush();
    expect(settings.value.fontSize, 16);
    expect((await settingsStore.load())?.fontSize, 16);

    // From a size between the steps, zoom goes to the next step.
    await settings.update(settings.value.copyWith(fontSize: 15));
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zoom Out'));
    await tester.pumpAndSettle();
    expect(settings.value.fontSize, 14);
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('a failed settings save says so in a banner', (tester) async {
    settingsStore.failSaves = true;
    workspace.newDocument();
    await mount(tester);
    await settings.update(settings.value.copyWith(fontSize: 20));
    await tester.pumpAndSettle();
    final banner = find.byKey(const ValueKey('settings-error-banner'));
    expect(banner, findsOneWidget);
    expect(find.textContaining('disk full'), findsOneWidget);

    await tester.tap(
      find.descendant(of: banner, matching: find.byTooltip('Dismiss error')),
    );
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
  });

  testWidgets('Settings lives in the File menu off macOS', (tester) async {
    workspace.newDocument();
    await mount(tester);
    await openSettings(tester);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('Settings lives in the application menu on macOS', (
    tester,
  ) async {
    workspace.newDocument();
    await mount(tester);
    final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
    final app = bar.menus.whereType<PlatformMenu>().first;
    expect(app.label, 'Planchette');
    final items = app.menus
        .whereType<PlatformMenuItemGroup>()
        .expand((group) => group.members)
        .whereType<PlatformMenuItem>()
        .map((item) => item.label);
    expect(items, contains('Settings…'));
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));
}
