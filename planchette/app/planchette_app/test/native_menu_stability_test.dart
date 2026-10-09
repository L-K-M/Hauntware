import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/document_workspace.dart';

import 'services/document_workspace_test.dart'
    show FakeDialogs, MemoryDocuments;
import 'services/memory_settings.dart' show testSettings;

/// Records native menu replacement without requiring AppKit's provided items.
final class _RecordingMenuDelegate extends PlatformMenuDelegate {
  List<PlatformMenuItem> menus = const [];
  int updates = 0;

  @override
  void clearMenus() => menus = const [];

  @override
  void setMenus(List<PlatformMenuItem> topLevelMenus) {
    menus = topLevelMenus;
    updates++;
  }

  @override
  bool debugLockDelegate(BuildContext context) => true;

  @override
  bool debugUnlockDelegate(BuildContext context) => true;
}

Iterable<PlatformMenuItem> _leaves(Iterable<PlatformMenuItem> menus) =>
    menus.expand(
      (item) => switch (item) {
        PlatformMenu(:final menus) => _leaves(menus),
        PlatformMenuItemGroup(:final members) => _leaves(members),
        _ => [item],
      },
    );

void main() {
  late DocumentWorkspace workspace;
  late _RecordingMenuDelegate delegate;

  setUp(() {
    workspace = DocumentWorkspace(
      store: MemoryDocuments(),
      dialogs: FakeDialogs(),
    );
    delegate = _RecordingMenuDelegate();
    final original = WidgetsBinding.instance.platformMenuDelegate;
    WidgetsBinding.instance.platformMenuDelegate = delegate;
    addTearDown(() {
      WidgetsBinding.instance.platformMenuDelegate = original;
      workspace.dispose();
    });
  });

  PlatformMenuItem item(String label) =>
      _leaves(delegate.menus).firstWhere((item) => item.label == label);

  testWidgets('macOS: settings rebuild preserves native menus', (tester) async {
    final settings = testSettings();
    expect(workspace.newDocument(), isNotNull);
    workspace.toolHistory.record('sortLines', {'order': 'descending'});
    await tester.pumpWidget(
      PlanchetteApp(workspace: workspace, settings: settings),
    );
    await tester.pumpAndSettle();
    // Changing size enables Actual Size before the theme-only rebuild.
    await settings.update(settings.value.copyWith(fontSize: 16));
    await tester.pumpAndSettle();
    final updates = delegate.updates;

    await settings.update(settings.value.copyWith(themeMode: ThemeMode.dark));
    await tester.pumpAndSettle();
    expect(delegate.updates, updates);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('macOS: changed menu enablement is still published', (
    tester,
  ) async {
    final tab = workspace.newDocument()!;
    await tester.pumpWidget(
      PlanchetteApp(workspace: workspace, settings: testSettings()),
    );
    await tester.pumpAndSettle();
    final updates = delegate.updates;
    expect(item('Save All').onSelected, isNull);

    tab.editor.text.text = 'one\ntwo';
    await tester.pumpAndSettle();
    expect(delegate.updates, greaterThan(updates));
    expect(item('Save All').onSelected, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('macOS: identical tab menus target the active document', (
    tester,
  ) async {
    final first = workspace.newDocument()!;
    final second = workspace.newDocument()!;
    for (final tab in [first, second]) {
      tab.editor.text.text = 'one\ntwo';
      tab.editor.text.selection = const TextSelection.collapsed(offset: 5);
    }
    await tester.pumpWidget(
      PlanchetteApp(workspace: workspace, settings: testSettings()),
    );
    await tester.pumpAndSettle();

    workspace.select(first);
    await tester.pumpAndSettle();
    item('Select Line').onSelected!();
    await tester.pumpAndSettle();
    expect(
      first.editor.text.selection,
      const TextSelection(baseOffset: 4, extentOffset: 7),
    );
    expect(
      second.editor.text.selection,
      const TextSelection.collapsed(offset: 5),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
