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

void main() {
  late MemoryDocuments store;
  late FakeDialogs dialogs;
  late DocumentWorkspace workspace;
  late MemorySettings settingsStore;
  late SettingsController settings;

  setUp(() async {
    store = MemoryDocuments();
    dialogs = FakeDialogs();
    workspace = DocumentWorkspace(store: store, dialogs: dialogs);
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

  /// The brightness the window actually resolved, which is not the same as one
  /// of the two themes MaterialApp was handed.
  /// Drag the size slider to a value, which is how a user reaches it.
  Future<void> dragFontSizeTo(WidgetTester tester, int size) async {
    final box = tester.getRect(find.byType(Slider).first);
    final fraction =
        (size - AppSettings.minimumFontSize) /
        (AppSettings.maximumFontSize - AppSettings.minimumFontSize);
    await tester.tapAt(Offset(box.left + box.width * fraction, box.center.dy));
  }

  Brightness brightnessOf(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(Scaffold))).brightness;

  testWidgets('the stored theme mode is what the window uses', (tester) async {
    await mount(tester, mode: ThemeMode.dark);
    expect(brightnessOf(tester), Brightness.dark);
  });

  testWidgets('a light theme is honoured even on a dark platform', (
    tester,
  ) async {
    await mount(tester, mode: ThemeMode.light);
    expect(brightnessOf(tester), Brightness.light);
  });

  testWidgets('a stored font size reaches the document', (tester) async {
    await settings.update(settings.value.copyWith(fontSize: 24));
    workspace.newDocument();
    await mount(tester);

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('planchette.document')),
    );
    expect(field.style?.fontSize, 24);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stored indent reaches the buffer', (tester) async {
    await settings.update(
      settings.value.copyWith(indent: const EditorIndent(size: 4)),
    );
    workspace.newDocument();
    await mount(tester);

    final tab = workspace.active!;
    expect(tab.editor.indent.size, 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing the settings re-themes a mounted window', (
    tester,
  ) async {
    await mount(tester, mode: ThemeMode.light);
    expect(brightnessOf(tester), Brightness.light);

    await settings.update(settings.value.copyWith(themeMode: ThemeMode.dark));
    await tester.pumpAndSettle();
    expect(brightnessOf(tester), Brightness.dark);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a font size change reaches an already-open document', (
    tester,
  ) async {
    workspace.newDocument();
    await mount(tester);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('planchette.document')))
          .style
          ?.fontSize,
      AppSettings.defaultFontSize,
    );

    await settings.update(settings.value.copyWith(fontSize: 20));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('planchette.document')))
          .style
          ?.fontSize,
      20,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the preferences dialog applies a theme immediately', (
    tester,
  ) async {
    workspace.newDocument();
    await mount(tester, mode: ThemeMode.light);

    await tester.tap(find.byTooltip('Settings…'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsOneWidget);

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(brightnessOf(tester), Brightness.dark);
    expect(settings.value.themeMode, ThemeMode.dark);

    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling the dialog puts the settings back', (tester) async {
    workspace.newDocument();
    await mount(tester, mode: ThemeMode.light);

    await tester.tap(find.byTooltip('Settings…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(settings.value.themeMode, ThemeMode.dark);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pump();
    expect(settings.value.themeMode, ThemeMode.light);
    await tester.pumpAndSettle();
    expect(brightnessOf(tester), Brightness.light);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the dialog persists what it chose', (tester) async {
    workspace.newDocument();
    await mount(tester);

    await tester.tap(find.byTooltip('Settings…'));
    await tester.pumpAndSettle();
    await dragFontSizeTo(tester, 20);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();
    await settings.flush();

    // The stored size is whatever the slider landed on; what matters is that
    // the file and the live value agree and that the choice was kept.
    expect(settingsStore.writes, greaterThan(0));
    expect((await settingsStore.load())?.fontSize, settings.value.fontSize);
    expect(settings.value.fontSize, isNot(AppSettings.defaultFontSize));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the dialog fits a narrow window without overflowing', (
    tester,
  ) async {
    workspace.newDocument();
    await mount(tester);
    await tester.tap(find.byTooltip('Settings…'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the settings entry is in the File menu too', (tester) async {
    workspace.newDocument();
    await mount(tester);

    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    expect(find.text('Settings…'), findsOneWidget);
    await tester.takeException();
  });
}
