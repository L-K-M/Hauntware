import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/managed_remote_file.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/ui/tab_close.dart';

void main() {
  const cases = [
    ('Return confirms the default', [LogicalKeyboardKey.enter], true),
    (
      'Keypad Enter confirms the default',
      [LogicalKeyboardKey.numpadEnter],
      true,
    ),
    (
      'Tab then Return activates Cancel',
      [LogicalKeyboardKey.tab, LogicalKeyboardKey.enter],
      false,
    ),
    ('Escape cancels', [LogicalKeyboardKey.escape], false),
  ];
  for (final (description, keys, confirms) in cases) {
    testWidgets('$description when closing a session with local edits', (
      tester,
    ) async {
      final engine = XtermTerminalEngine();
      final session = TerminalSession(
        id: 'session',
        serverId: 'server',
        config: null,
        engine: engine,
        connecting: false,
      );
      addTearDown(() {
        session.dispose();
        engine.dispose();
      });
      session.retainedLocalCopies['/remote.txt'] = _LocalCopy();
      final state = _SessionState(session);
      var backgroundActivations = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.macOS),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                autofocus: true,
                onPressed: () => backgroundActivations++,
                child: const Text('Background action'),
              ),
              floatingActionButton: FloatingActionButton(
                onPressed: () => confirmAndCloseTab(context, state, session.id),
                child: const Text('Close session'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Close session'));
      await tester.pumpAndSettle();
      expect(find.text('Close session and local edits?'), findsOneWidget);

      for (final key in keys) {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }

      expect(find.byType(AlertDialog), findsNothing);
      expect(state.closedTabs, confirms ? [session.id] : isEmpty);
      expect(backgroundActivations, 0);
    });
  }
}

class _LocalCopy extends Fake implements ManagedRemoteFile {}

class _SessionState extends Fake implements AppState {
  _SessionState(this.session);

  final TerminalSession session;
  final closedTabs = <String>[];

  @override
  PaneTab? tabById(String? id) => id == session.id ? session : null;

  @override
  List<EditorTab> editorTabsOwnedBy(TerminalSession session) => [];

  @override
  Future<TabCloseReport> closeTab(String tabId) async {
    closedTabs.add(tabId);
    return const TabCloseReport.success();
  }
}
