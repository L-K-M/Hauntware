import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/ui/app_menus.dart';
import 'package:seance_terminal/seance_terminal.dart';

// Clipboard pastes into Séance's terminal pass the shared paste policy
// (docs/design/seance-terminal.md, 10.8), as Klabautermann's container
// shell does: no control character reaches the shell, and a multi-line
// paste the danger linter flags asks first.
void main() {
  late String clipboard;
  late XtermTerminalEngine engine;
  late TerminalSession tab;
  late StringBuffer typed;
  late StreamSubscription<List<int>> input;

  setUp(() {
    clipboard = '';
    engine = XtermTerminalEngine();
    tab = TerminalSession(id: 'tab', serverId: 'local', engine: engine);
    typed = StringBuffer();
    input = engine.userInput.listen((bytes) => typed.write(utf8.decode(bytes)));
  });

  tearDown(() async {
    await input.cancel();
    engine.dispose();
  });

  Future<BuildContext> pumpHost(WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => switch (call.method) {
        'Clipboard.getData' => {'text': clipboard},
        _ => null,
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    );
    return tester.element(find.byType(SizedBox));
  }

  testWidgets('a pasted bracketed-paste end marker cannot reach the shell', (
    tester,
  ) async {
    final context = await pumpHost(tester);
    clipboard = 'echo safe\x1b[201~; echo injected';

    await tester.runAsync(() => terminalPaste(tab, context: context));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(typed.toString(), isNot(contains('\x1b')));
    expect(typed.toString(), contains('echo safe[201~; echo injected'));
  });

  testWidgets('a flagged multi-line paste asks first; First line only pastes '
      'it without its break', (tester) async {
    final context = await pumpHost(tester);
    clipboard = 'cd /tmp\nrm -rf /';

    final paste = terminalPaste(tab, context: context);
    await tester.pumpAndSettle();
    expect(find.text('Paste 2 lines?'), findsOneWidget);
    expect(find.textContaining('Line 2: '), findsOneWidget);
    expect(typed.toString(), isEmpty);

    await tester.tap(find.text('First line only'));
    await tester.pumpAndSettle();
    await paste;
    expect(typed.toString(), contains('cd /tmp'));
    expect(typed.toString(), isNot(contains('rm')));
    expect(typed.toString(), isNot(contains('\n')));
    expect(typed.toString(), isNot(contains('\r')));
  });

  testWidgets('a clean multi-line paste goes in line by line, and Cancel on '
      'a flagged one pastes nothing', (tester) async {
    final context = await pumpHost(tester);
    // Bash turns bracketed paste on at its prompt.
    engine.feed(Uint8List.fromList(utf8.encode('\x1b[?2004h')));

    clipboard = 'cd /tmp\nls';
    await tester.runAsync(() => terminalPaste(tab, context: context));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(typed.toString(), contains('cd /tmp'));
    expect(typed.toString(), contains('ls'));

    final before = typed.toString();
    clipboard = 'ls\nrm -rf /';
    final paste = terminalPaste(tab, context: context);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await paste;
    expect(typed.toString(), before);
  });

  testWidgets('without bracketed paste a clean multi-line paste asks, since '
      'each line would run as it arrives', (tester) async {
    final context = await pumpHost(tester);
    clipboard = 'cd build\nmake';

    final paste = terminalPaste(tab, context: context);
    await tester.pumpAndSettle();
    expect(find.text('Paste 2 lines?'), findsOneWidget);
    expect(typed.toString(), isEmpty);

    await tester.tap(find.text('Paste all'));
    await tester.pumpAndSettle();
    await paste;
    expect(typed.toString(), 'cd build\nmake');
  });
}
