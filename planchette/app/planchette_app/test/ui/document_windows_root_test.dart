import 'dart:ui' show FlutterView, Scene, SemanticsUpdate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/document_windows.dart';
import 'package:planchette_app/services/document_workspace.dart';
import 'package:planchette_app/services/window_host.dart';
import 'package:planchette_app/ui/document_windows_root.dart';

import '../services/document_windows_test.dart' show FakeWindowHost;
import '../services/document_workspace_test.dart'
    show FakeDialogs, MemoryDocuments;
import '../services/memory_settings.dart' show testSettings;

/// A second view for the test binding, the way Flutter's own multi-view
/// tests make one: the test view's metrics under another id, rendering
/// nowhere.
final class _FakeView extends TestFlutterView {
  _FakeView(TestFlutterView view, {required this.viewId})
    : super(
        view: view,
        platformDispatcher: view.platformDispatcher,
        display: view.display,
      );

  @override
  final int viewId;

  @override
  void render(Scene scene, {Size? size}) {}

  @override
  void updateSemantics(SemanticsUpdate update) {}
}

/// Records what the root's PlatformMenuBar pushes (the default delegate
/// asserts the real platform for provided items).
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

/// Every label a native menu tree carries, flattened.
List<String> _itemLabels(List<PlatformMenuItem> menus) => [
  for (final item in menus) ...[
    item.label,
    if (item is PlatformMenu) ..._itemLabels(item.menus),
    if (item is PlatformMenuItemGroup) ..._itemLabels(item.members),
  ],
];

void main() {
  late FakeWindowHost host;
  late DocumentWindows windows;
  late Map<int, FlutterView> views;
  late Map<int, FlutterView> seenViews;

  /// Built inside each test's zone so its futures run there.
  Future<void> startWindows(WidgetTester tester) async {
    host = FakeWindowHost();
    final store = MemoryDocuments();
    windows = DocumentWindows(
      host: host,
      workspaceFactory: (window) =>
          DocumentWorkspace(store: store, dialogs: FakeDialogs()),
      quitApplication: () async {},
      afterFrame: () async {},
    );
    addTearDown(windows.dispose);
    views = {mainWindowViewId: tester.view};
    seenViews = {};
    await windows.start();
  }

  Widget root({
    Widget Function(DocumentWindow window, MenuBarSlot? menuSlot)? content,
  }) => DocumentWindowsRoot(
    windows: windows,
    viewFor: (viewId) => views[viewId],
    buildWindow: (window, menuSlot) =>
        content?.call(window, menuSlot) ??
        PlanchetteApp(
          workspace: window.workspace,
          settings: testSettings(),
          window: window,
          menuSlot: menuSlot,
        ),
  );

  testWidgets('renders one view per open window that has one', (tester) async {
    await startWindows(tester);
    await windows.openWindow();
    await tester.pumpWidget(
      root(
        content: (window, _) => MaterialApp(
          home: Builder(
            builder: (context) {
              seenViews[window.viewId] = View.of(context);
              return Text(
                'window ${window.viewId} '
                '${window.isActive ? 'active' : 'inactive'}',
              );
            },
          ),
        ),
      ),
      wrapWithView: false,
    );

    // The extra window's view has not arrived yet: nothing renders it.
    expect(find.text('window 0 inactive'), findsOneWidget);
    expect(find.textContaining('window 1'), findsNothing);

    views[1] = _FakeView(tester.view, viewId: 1);
    tester.binding.handleMetricsChanged();
    await tester.pump();

    expect(find.text('window 1 active'), findsOneWidget);

    windows.onWindowActivated(mainWindowViewId);
    await tester.pump();

    expect(find.text('window 0 active'), findsOneWidget);
    expect(find.text('window 1 inactive'), findsOneWidget);
    expect(seenViews[1], same(views[1]));
  });

  testWidgets('each window binds its own navigator, under a messenger', (
    tester,
  ) async {
    await startWindows(tester);
    await windows.openWindow();
    views[1] = _FakeView(tester.view, viewId: 1);

    await tester.pumpWidget(root(), wrapWithView: false);
    await tester.pump();

    expect(windows.windows, hasLength(2));
    for (final window in windows.windows) {
      // Dialogs raised for a window's workspace use this key, so it must
      // be the navigator inside that window's own app.
      final navigator = window.navigatorKey.currentState;
      expect(navigator, isNotNull, reason: 'window ${window.viewId}');
      expect(
        View.of(window.navigatorKey.currentContext!).viewId,
        window.viewId,
      );
      expect(
        ScaffoldMessenger.maybeOf(window.navigatorKey.currentContext!),
        isNotNull,
        reason: 'window ${window.viewId}',
      );
    }
  });

  testWidgets("macOS: one menu bar, fed by the active window's shell", (
    tester,
  ) async {
    final delegate = _RecordingMenuDelegate();
    final original = WidgetsBinding.instance.platformMenuDelegate;
    WidgetsBinding.instance.platformMenuDelegate = delegate;
    addTearDown(() {
      WidgetsBinding.instance.platformMenuDelegate = original;
    });
    await startWindows(tester);
    await windows.openWindow();
    views[1] = _FakeView(tester.view, viewId: 1);

    await tester.pumpWidget(root(), wrapWithView: false);
    await tester.pump();
    await tester.pump();

    // One bar, the root's: a window's own would fight over the native one.
    expect(find.byType(PlatformMenuBar), findsOneWidget);
    var labels = _itemLabels(delegate.menus);
    expect(labels, contains('New Window'));
    expect(labels, contains('Close Window'));
    // The active extra window's title sits in the Window menu's list,
    // marked as the front one.
    expect(labels, contains(startsWith('✓ ')));

    windows.onWindowActivated(mainWindowViewId);
    await tester.pump();
    await tester.pump();

    // Republished: the ✓ moved to the main window's row.
    expect(
      _itemLabels(delegate.menus).where((label) => label.startsWith('✓ ')),
      [startsWith('✓ ')],
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('macOS: caret and metrics updates preserve native menus', (
    tester,
  ) async {
    final delegate = _RecordingMenuDelegate();
    final original = WidgetsBinding.instance.platformMenuDelegate;
    WidgetsBinding.instance.platformMenuDelegate = delegate;
    addTearDown(() {
      WidgetsBinding.instance.platformMenuDelegate = original;
    });
    await startWindows(tester);
    final workspace = windows.activeWindow!.workspace;
    final tab = workspace.newDocument()!;
    workspace.toolHistory.record('sortLines', {'order': 'descending'});
    tab.editor.text.text = 'one\ntwo';

    await tester.pumpWidget(root(), wrapWithView: false);
    await tester.pumpAndSettle();
    final updates = delegate.updates;

    // Moving a collapsed caret changes editor state, not menu contents.
    tab.editor.text.selection = const TextSelection.collapsed(offset: 5);
    await tester.pumpAndSettle();
    expect(delegate.updates, updates);

    tester.binding.handleMetricsChanged();
    await tester.pumpAndSettle();
    expect(delegate.updates, updates);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
