import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_servers/ghost_servers.dart';

/// Widget tests for the keyboard-interactive prompt, moved here from Séance
/// with the dialog. The moved cases run in Séance's configuration,
/// `submitOnEnter: false`; the cases at the end cover the package's own
/// parameters.
void main() {
  GhostKeyboardPrompt challenge(List<String> prompts) => GhostKeyboardPrompt(
    username: 'deploy',
    host: 'jump.example.com',
    port: 2222,
    prompts: prompts,
    name: 'Server authentication',
    instruction: 'Answer the server challenge.',
  );

  Future<void> openDialog(
    WidgetTester tester, {
    List<String> prompts = const ['Password', 'One-time code'],
    GhostKeyboardPrompt? customChallenge,
    ValueChanged<List<String>>? onResult,
    GhostKeyboardInteractiveStrings strings =
        const GhostKeyboardInteractiveStrings(),
    GlobalKey? dialogKey,
    bool submitOnEnter = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final result = await showGhostKeyboardInteractiveDialog(
                  context,
                  customChallenge ?? challenge(prompts),
                  strings: strings,
                  dialogKey: dialogKey,
                  submitOnEnter: submitOnEnter,
                );
                onResult?.call(result);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the trusted endpoint separately from server text', (
    tester,
  ) async {
    await openDialog(tester);

    expect(find.text('deploy@jump.example.com:2222'), findsOneWidget);
    expect(find.text('Authentication'), findsOneWidget);
    expect(find.text('Answer the server challenge.'), findsOneWidget);
  });

  testWidgets('separates the trusted endpoint from prompt-only challenges', (
    tester,
  ) async {
    await openDialog(
      tester,
      customChallenge: const GhostKeyboardPrompt(
        username: 'deploy',
        host: 'jump.example.com',
        port: 2222,
        prompts: ['Password'],
        name: '',
        instruction: '',
      ),
    );

    final endpointBottom = tester
        .getBottomLeft(find.text('deploy@jump.example.com:2222'))
        .dy;
    final promptTop = tester.getTopLeft(find.byType(TextField)).dy;

    expect(promptTop - endpointBottom, greaterThanOrEqualTo(12));
  });

  testWidgets('brackets a bare IPv6 host in the trusted target', (
    tester,
  ) async {
    await openDialog(
      tester,
      customChallenge: const GhostKeyboardPrompt(
        username: 'root',
        host: '2001:db8::1',
        port: 22,
        prompts: ['Password'],
        name: '',
        instruction: '',
      ),
    );

    expect(find.text('root@[2001:db8::1]:22'), findsOneWidget);
  });

  /// Opens the dialog above a pushed page, as a real prompt does, so the
  /// page below is a concrete route a stray pop could take with it.
  Future<List<List<String>>> openAbovePushedPage(
    WidgetTester tester, {
    required GlobalKey<NavigatorState> navigatorKey,
  }) async {
    final recorded = <List<String>>[];
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Center(child: Text('home-page'))),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () async => recorded.add(
                  await showGhostKeyboardInteractiveDialog(
                    context,
                    challenge(const ['Password', 'One-time code']),
                    submitOnEnter: false,
                  ),
                ),
                child: const Text('open-dialog'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open-dialog'));
    await tester.pumpAndSettle();
    return recorded;
  }

  testWidgets('a rapid double submit cannot pop the page below the dialog', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final recorded = await openAbovePushedPage(
      tester,
      navigatorKey: navigatorKey,
    );
    await tester.enterText(find.byType(TextField).at(0), 'a password');
    await tester.enterText(find.byType(TextField).at(1), '012345');

    // Two activations in one turn: the first starts the exit animation, and
    // the second must not pop whatever sits below the half-dismissed dialog.
    final submit = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Submit'),
    );
    submit.onPressed!();
    submit.onPressed!();
    await tester.pumpAndSettle();

    expect(recorded, [
      ['a password', '012345'],
    ]); // the first answer survives, unchanged
    expect(
      find.text('home-page'),
      findsNothing,
    ); // the pushed page was not popped
    expect(find.text('open-dialog'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a rapid double cancel keeps the empty-list answer', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final recorded = await openAbovePushedPage(
      tester,
      navigatorKey: navigatorKey,
    );

    final cancel = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Cancel'),
    );
    cancel.onPressed!();
    cancel.onPressed!();
    await tester.pumpAndSettle();

    expect(recorded, [
      <String>[],
    ]); // one cancel; the second activation is a no-op
    expect(find.text('home-page'), findsNothing);
    expect(find.text('open-dialog'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a callback from an obscured dialog cannot answer the newer route',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      final recorded = await openAbovePushedPage(
        tester,
        navigatorKey: navigatorKey,
      );
      await tester.enterText(find.byType(TextField).at(0), 'a password');
      await tester.enterText(find.byType(TextField).at(1), '012345');
      final submit = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Submit'),
      );

      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              const Scaffold(body: Center(child: Text('newer-page'))),
        ),
      );
      await tester.pumpAndSettle();

      // The dialog is no longer the current route, so its submit must be a
      // no-op — an unguarded pop would dismiss and answer the *newer* page.
      submit.onPressed!();
      await tester.pumpAndSettle();

      expect(find.text('newer-page'), findsOneWidget);
      expect(recorded, isEmpty); // the dialog was never answered
      expect(tester.takeException(), isNull);

      // Unwind: the dialog itself is intact and still answerable underneath.
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'other');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(recorded, [<String>[]]);
    },
  );

  testWidgets('answers are hidden and excluded from keyboard learning', (
    tester,
  ) async {
    await openDialog(tester);
    for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
      expect(field.obscureText, isTrue);
      expect(field.keyboardType, TextInputType.visiblePassword);
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
    }
  });

  testWidgets('reveals only the chosen answer and can hide it again', (
    tester,
  ) async {
    await openDialog(tester);
    await tester.enterText(find.byType(TextField).first, 'operator');
    await tester.tap(find.byTooltip('Show answer').first);
    await tester.pump();

    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields.first.obscureText, isFalse);
    expect(fields.first.controller!.text, 'operator');
    expect(fields.last.obscureText, isTrue);
    expect(fields.first.enableIMEPersonalizedLearning, isFalse);
    final editable = tester.widget<EditableText>(
      find.descendant(
        of: find.byType(TextField).first,
        matching: find.byType(EditableText),
      ),
    );
    expect(editable.focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(find.byTooltip('Hide answer'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).obscureText,
      isTrue,
    );
  });

  testWidgets('submits every answer in prompt order', (tester) async {
    List<String>? result;
    await openDialog(tester, onResult: (value) => result = value);
    await tester.enterText(find.byType(TextField).at(0), 'a password');
    await tester.enterText(find.byType(TextField).at(1), '012345');
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();
    expect(result, ['a password', '012345']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel with active composition returns no answers', (
    tester,
  ) async {
    List<String>? result;
    await openDialog(tester, onResult: (value) => result = value);
    await tester.showKeyboard(find.byType(TextField).first);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'secret',
        selection: TextSelection.collapsed(offset: 6),
        composing: TextRange(start: 0, end: 6),
      ),
    );
    await tester.pump();
    final controller = tester
        .widget<TextField>(find.byType(TextField).first)
        .controller!;
    expect(controller.text, 'secret');
    expect(controller.value.composing, const TextRange(start: 0, end: 6));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long challenges fit above a phone keyboard', (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 160);
    addTearDown(tester.view.reset);
    await openDialog(
      tester,
      prompts: List.generate(10, (index) => 'Challenge $index'),
    );
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byType(TextField).last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'last');
    final keyboardTop =
        (tester.view.physicalSize.height - tester.view.viewInsets.bottom) /
        tester.view.devicePixelRatio;
    expect(tester.getRect(find.text('Submit')).bottom, lessThan(keyboardTop));
    expect(tester.getRect(find.text('Cancel')).bottom, lessThan(keyboardTop));
    expect(
      tester.getRect(find.byType(TextField).last).bottom,
      lessThan(keyboardTop),
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the dialog cannot be dismissed by tapping outside', (
    tester,
  ) async {
    await openDialog(tester);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(find.text('Authentication'), findsOneWidget);
  });

  testWidgets("a host's words and dialog key reach the dialog", (tester) async {
    final dialogKey = GlobalKey();
    final endpoints = <(String?, String, int)>[];
    final strings = GhostKeyboardInteractiveStrings(
      title: 'title',
      requestFrom: 'from',
      serverMessage: 'message',
      endpoint: (username, host, port) {
        endpoints.add((username, host, port));
        return '$host port $port as $username';
      },
      showAnswer: 'show',
      hideAnswer: 'hide',
      cancel: 'no',
      submit: 'yes',
    );
    await openDialog(
      tester,
      customChallenge: const GhostKeyboardPrompt(
        username: 'root',
        host: '2001:db8::1',
        port: 22,
        name: 'Server authentication',
        instruction: '',
        prompts: ['Password'],
      ),
      strings: strings,
      dialogKey: dialogKey,
    );

    expect(
      find.descendant(
        of: find.byKey(dialogKey),
        matching: find.byType(AlertDialog),
      ),
      findsOneWidget,
    );
    // The formatter receives the host already bracketed.
    expect(endpoints.toSet(), {('root', '[2001:db8::1]', 22)});
    for (final text in [
      'title',
      'from',
      '[2001:db8::1] port 22 as root',
      'message',
      'no',
      'yes',
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    expect(find.byTooltip('show'), findsOneWidget);

    await tester.tap(find.byTooltip('show'));
    await tester.pump();
    expect(find.byTooltip('hide'), findsOneWidget);
  });

  testWidgets('an endpoint without a username shows the host and port', (
    tester,
  ) async {
    await openDialog(
      tester,
      customChallenge: const GhostKeyboardPrompt(
        host: 'jump.example.com',
        port: 2222,
        name: '',
        instruction: '',
        prompts: ['Password'],
      ),
    );

    expect(find.text('jump.example.com:2222'), findsOneWidget);
  });

  testWidgets('a bracketed IPv6 host is not bracketed again', (tester) async {
    await openDialog(
      tester,
      customChallenge: const GhostKeyboardPrompt(
        username: 'root',
        host: '[2001:db8::1]',
        port: 22,
        name: '',
        instruction: '',
        prompts: ['Password'],
      ),
    );

    expect(find.text('root@[2001:db8::1]:22'), findsOneWidget);
  });

  testWidgets('submitOnEnter advances through the answers and submits', (
    tester,
  ) async {
    List<String>? result;
    await openDialog(
      tester,
      onResult: (value) => result = value,
      submitOnEnter: true,
    );

    final fields = find.byType(TextField);
    expect(
      tester
          .widgetList<TextField>(fields)
          .map((field) => field.textInputAction),
      [TextInputAction.next, TextInputAction.done],
    );

    await tester.enterText(fields.at(0), 'a password');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    final secondFocused = find.descendant(
      of: fields.at(1),
      matching: find.byWidgetPredicate(
        (widget) => widget is EditableText && widget.focusNode.hasFocus,
      ),
    );
    expect(secondFocused, findsOneWidget);

    await tester.enterText(fields.at(1), '012345');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(result, ['a password', '012345']);
  });

  testWidgets('without submitOnEnter only the buttons answer', (tester) async {
    List<String>? result;
    await openDialog(tester, onResult: (value) => result = value);

    for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
      expect(field.textInputAction, isNull);
      expect(field.onSubmitted, isNull);
    }

    await tester.enterText(find.byType(TextField).at(1), '012345');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text('Authentication'), findsOneWidget);
  });
}
