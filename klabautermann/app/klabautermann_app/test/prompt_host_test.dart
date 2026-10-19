import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/ghost_fonts.dart' show ghostMonoFontFamily;
import 'package:klabautermann_app/controllers/prompt_controller.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';
import 'support/harness.dart';

const _hostKey = HostKeyPromptRequest(
  keyType: 'ssh-ed25519',
  fingerprintSha256: 'SHA256:abc',
);

/// The re-pin review of a key that replaced the pinned one (D61), under
/// another algorithm.
const _changedKey = HostKeyPromptRequest(
  keyType: 'ecdsa-sha2-nistp256',
  fingerprintSha256: 'SHA256:new',
  pinnedFingerprintSha256: 'SHA256:abc',
  pinnedKeyType: 'ssh-ed25519',
);

const _questions = KeyboardInteractivePromptRequest(
  user: 'deploy',
  name: 'otp',
  instruction: 'Enter your code',
  questions: ['Password:', 'Code:'],
);

Prompt _prompt(
  String promptId,
  PromptRequest request, {
  String host = 'web-1.example',
  int port = 22,
}) => Prompt(
  promptId: promptId,
  serverId: 'srv-1',
  host: host,
  port: port,
  request: request,
);

String _describe(PromptAnswer answer) => switch (answer) {
  PromptTrustAnswer(:final accepted) => 'trust $accepted',
  PromptResponsesAnswer(:final responses) => 'responses $responses',
  PromptCancelAnswer() => 'cancel',
  PromptSecretAnswer(:final secret) => 'secret $secret',
};

/// Every [AnswerPrompt] the app sent, in order.
List<String> _answers(FakeEngineClient engine) => [
  for (final AnswerPrompt(:promptId, :answer)
      in engine.sentOfType<AnswerPrompt>().cast<AnswerPrompt>())
    '$promptId: ${_describe(answer)}',
];

final _hostKeyTitle = find.text('Unknown host key');
final _keyboardTitle = find.text('Authentication');

void main() {
  group('the host-key prompt', () {
    testWidgets('shows a first-seen key for review, and trusting it answers '
        'true', (tester) async {
      final harness = await pumpApp(tester, servers: twoServers);

      harness.engine.emit(_prompt('p-1', _hostKey));
      await tester.pumpAndSettle();

      expect(_hostKeyTitle, findsOneWidget);
      expect(find.text('web-1.example:22'), findsOneWidget);
      expect(find.text('Fingerprint'), findsOneWidget);
      // The fingerprint in the bundled monospace face (P10).
      final fingerprint = tester.widget<SelectableText>(
        find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText &&
              widget.data == 'ssh-ed25519\nSHA256:abc',
        ),
      );
      expect(fingerprint.style?.fontFamily, ghostMonoFontFamily);
      expect(_answers(harness.engine), isEmpty);

      await tester.tap(find.text('Trust and connect'));
      await tester.pumpAndSettle();

      expect(_hostKeyTitle, findsNothing);
      expect(_answers(harness.engine), ['p-1: trust true']);
    });

    testWidgets('Cancel declines the key', (tester) async {
      final harness = await pumpApp(tester, servers: twoServers);

      harness.engine.emit(_prompt('p-1', _hostKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(_hostKeyTitle, findsNothing);
      expect(_answers(harness.engine), ['p-1: trust false']);
    });

    for (final (button, trusted) in [
      ('Trust the new key', true),
      ('Cancel', false),
    ]) {
      testWidgets('shows a changed key as the changed-key review beside the '
          'pinned one, and $button answers $trusted', (tester) async {
        final harness = await pumpApp(tester, servers: twoServers);

        harness.engine.emit(_prompt('p-1', _changedKey));
        await tester.pumpAndSettle();

        expect(find.text('HOST KEY CHANGED'), findsOneWidget);
        expect(_hostKeyTitle, findsNothing);
        expect(
          find.textContaining('The key for web-1.example does not match'),
          findsOneWidget,
        );
        expect(find.text('New key'), findsOneWidget);
        expect(find.text('Previously trusted'), findsOneWidget);
        // Each fingerprint under its own key's type.
        for (final text in [
          'ecdsa-sha2-nistp256\nSHA256:new',
          'ssh-ed25519\nSHA256:abc',
        ]) {
          expect(
            find.byWidgetPredicate(
              (widget) => widget is SelectableText && widget.data == text,
            ),
            findsOneWidget,
            reason: text,
          );
        }

        await tester.tap(find.text(button));
        await tester.pumpAndSettle();

        expect(find.text('HOST KEY CHANGED'), findsNothing);
        expect(_answers(harness.engine), ['p-1: trust $trusted']);
      });
    }

    testWidgets('brackets a bare IPv6 host before its port', (tester) async {
      final harness = await pumpApp(tester, servers: twoServers);

      harness.engine.emit(
        _prompt('p-1', _hostKey, host: '2001:db8::5', port: 2222),
      );
      await tester.pumpAndSettle();

      expect(find.text('[2001:db8::5]:2222'), findsOneWidget);
    });
  });

  group('the keyboard-interactive prompt', () {
    testWidgets('names who asks and sends the responses in question '
        'order', (tester) async {
      final harness = await pumpApp(tester, servers: twoServers);

      // A jump host asks, under its own user.
      harness.engine.emit(
        _prompt('p-1', _questions, host: 'bastion.example', port: 2200),
      );
      await tester.pumpAndSettle();

      expect(_keyboardTitle, findsOneWidget);
      expect(find.text('deploy@bastion.example:2200'), findsOneWidget);
      expect(find.text('otp'), findsOneWidget);
      expect(find.text('Enter your code'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Password:'),
        'hunter2',
      );
      await tester.enterText(find.widgetWithText(TextField, 'Code:'), '123456');
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();

      expect(_keyboardTitle, findsNothing);
      expect(_answers(harness.engine), ['p-1: responses [hunter2, 123456]']);
    });

    testWidgets('Cancel sends the explicit cancel answer', (tester) async {
      final harness = await pumpApp(tester, servers: twoServers);

      harness.engine.emit(_prompt('p-1', _questions));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(_keyboardTitle, findsNothing);
      expect(_answers(harness.engine), ['p-1: cancel']);
    });

    testWidgets('without a user, the endpoint is the host and port', (
      tester,
    ) async {
      final harness = await pumpApp(tester, servers: twoServers);

      harness.engine.emit(
        _prompt(
          'p-1',
          const KeyboardInteractivePromptRequest(questions: ['Code:']),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('web-1.example:22'), findsOneWidget);
    });
  });

  group('the queue', () {
    testWidgets('shows one prompt at a time, oldest first', (tester) async {
      final harness = await pumpApp(tester, servers: twoServers);

      harness.engine
        ..emit(_prompt('p-1', _hostKey))
        ..emit(
          _prompt(
            'p-2',
            const KeyboardInteractivePromptRequest(questions: ['Code:']),
          ),
        )
        ..emit(
          _prompt(
            'p-3',
            const HostKeyPromptRequest(
              keyType: 'ssh-ed25519',
              fingerprintSha256: 'SHA256:third',
            ),
          ),
        );
      await tester.pumpAndSettle();

      expect(find.text('ssh-ed25519\nSHA256:abc'), findsOneWidget);
      expect(_keyboardTitle, findsNothing);
      await tester.tap(find.text('Trust and connect'));
      await tester.pumpAndSettle();

      expect(_hostKeyTitle, findsNothing);
      expect(_keyboardTitle, findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Code:'), '42');
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();

      expect(_keyboardTitle, findsNothing);
      expect(find.text('ssh-ed25519\nSHA256:third'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(_hostKeyTitle, findsNothing);
      expect(_answers(harness.engine), [
        'p-1: trust true',
        'p-2: responses [42]',
        'p-3: trust false',
      ]);
    });

    for (final reason in PromptWithdrawnReason.values) {
      testWidgets('a prompt withdrawn as ${reason.name} closes its dialog '
          'unanswered, and a queued one never shows', (tester) async {
        final harness = await pumpApp(tester, servers: twoServers);
        harness.engine
          ..emit(_prompt('p-1', _hostKey))
          ..emit(_prompt('p-2', _questions))
          ..emit(
            _prompt(
              'p-3',
              const HostKeyPromptRequest(
                keyType: 'ssh-ed25519',
                fingerprintSha256: 'SHA256:third',
              ),
            ),
          );
        await tester.pumpAndSettle();
        expect(find.text('ssh-ed25519\nSHA256:abc'), findsOneWidget);

        harness.engine
          ..emit(PromptWithdrawn('p-2', reason))
          ..emit(PromptWithdrawn('p-1', reason));
        await tester.pumpAndSettle();

        // p-1's dialog went without an answer; p-2 was dropped unseen.
        expect(find.text('ssh-ed25519\nSHA256:abc'), findsNothing);
        expect(_keyboardTitle, findsNothing);
        expect(find.text('ssh-ed25519\nSHA256:third'), findsOneWidget);
        expect(_answers(harness.engine), isEmpty);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(_answers(harness.engine), ['p-3: trust false']);
      });
    }

    testWidgets('a withdrawal while the dialog opens sends nothing, though '
        'the closed dialog returns its cancel value', (tester) async {
      final harness = await pumpApp(tester, servers: twoServers);

      harness.engine.emit(_prompt('p-1', _questions));
      // The event arrives, then one frame builds the dialog, which is
      // still animating in.
      await tester.pump();
      await tester.pump();
      expect(_keyboardTitle, findsOneWidget);
      harness.engine.emit(
        const PromptWithdrawn('p-1', PromptWithdrawnReason.expired),
      );
      await tester.pumpAndSettle();

      expect(_keyboardTitle, findsNothing);
      expect(_answers(harness.engine), isEmpty);
    });

    testWidgets('a prompt withdrawn in the turn it arrives does not stay '
        'up', (tester) async {
      final harness = await pumpApp(tester, servers: twoServers);

      // The dialog's route is pushed before its widget builds.
      harness.engine
        ..emit(_prompt('p-1', _hostKey))
        ..emit(
          const PromptWithdrawn('p-1', PromptWithdrawnReason.attemptEnded),
        );
      await tester.pumpAndSettle();

      expect(_hostKeyTitle, findsNothing);
      expect(_answers(harness.engine), isEmpty);
    });

    testWidgets('a withdrawal under another route removes only the '
        'dialog', (tester) async {
      final harness = await pumpApp(tester, servers: twoServers);
      harness.engine.emit(_prompt('p-1', _hostKey));
      await tester.pumpAndSettle();
      final navigator = Navigator.of(tester.element(_hostKeyTitle));
      // Not awaited: the page's future ends only when it is popped.
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Covering page')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      harness.engine.emit(
        const PromptWithdrawn('p-1', PromptWithdrawnReason.expired),
      );
      await tester.pumpAndSettle();

      expect(find.text('Covering page'), findsOneWidget);
      expect(find.text('Unknown host key', skipOffstage: false), findsNothing);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(_hostKeyTitle, findsNothing);
      expect(find.text('Covering page'), findsNothing);
      expect(_answers(harness.engine), isEmpty);
    });

    testWidgets('credential prompts are dismissed without a dialog', (
      tester,
    ) async {
      final harness = await pumpApp(tester, servers: twoServers);

      harness.engine
        ..emit(_prompt('p-1', const CredentialPromptRequest(user: 'me')))
        ..emit(_prompt('p-3', _hostKey));
      await tester.pumpAndSettle();

      expect(_answers(harness.engine), ['p-1: secret null']);
      expect(_hostKeyTitle, findsOneWidget);
    });

    testWidgets('an engine that stops closes the dialog unanswered', (
      tester,
    ) async {
      final harness = await pumpApp(tester, servers: twoServers);
      harness.engine.emit(_prompt('p-1', _hostKey));
      await tester.pumpAndSettle();

      // Not awaited: its done event goes out as the test pumps.
      unawaited(harness.engine.close());
      await tester.pumpAndSettle();

      expect(_hostKeyTitle, findsNothing);
      expect(_answers(harness.engine), isEmpty);
    });
  });

  group('PromptController', () {
    late FakeEngineClient engine;
    late PromptController prompts;

    setUp(() {
      engine = FakeEngineClient();
      prompts = PromptController(engine);
    });

    tearDown(() async {
      prompts.dispose();
      await engine.close();
    });

    test('answers only an open prompt, and once', () async {
      engine
        ..emit(_prompt('p-1', _hostKey))
        ..emit(_prompt('p-2', _hostKey));
      await pumpEventQueue();
      expect(prompts.current?.promptId, 'p-1');

      engine.emit(const PromptWithdrawn('p-1', PromptWithdrawnReason.expired));
      await pumpEventQueue();
      expect(prompts.isOpen('p-1'), isFalse);
      expect(prompts.current?.promptId, 'p-2');

      expect(prompts.answer('p-1', const PromptTrustAnswer(true)), isFalse);
      expect(prompts.answer('p-2', const PromptTrustAnswer(true)), isTrue);
      expect(prompts.answer('p-2', const PromptTrustAnswer(false)), isFalse);
      expect(prompts.current, isNull);
      expect(_answers(engine), ['p-2: trust true']);
    });

    test('an engine that stops closes every prompt', () async {
      engine.emit(_prompt('p-1', _hostKey));
      await pumpEventQueue();

      await engine.close();
      await pumpEventQueue();

      expect(prompts.current, isNull);
      expect(prompts.answer('p-1', const PromptTrustAnswer(true)), isFalse);
      expect(engine.sent, isEmpty);
    });
  });

  group('the admin mode password prompt (SAF-02)', () {
    final title = find.text('Admin password for web-1.example');
    final password = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );

    testWidgets('sends the password, and no "remember" is offered', (
      tester,
    ) async {
      final harness = await pumpApp(tester, servers: twoServers);
      harness.engine.emit(
        _prompt('p-1', const ElevationPromptRequest(user: 'deploy')),
      );
      await tester.pumpAndSettle();

      expect(title, findsOneWidget);
      expect(find.textContaining('as deploy'), findsOneWidget);
      expect(find.text('That password did not work. Try again.'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(Checkbox),
        ),
        findsNothing,
      );
      final turnOn = find.widgetWithText(FilledButton, 'Turn on');
      expect(tester.widget<FilledButton>(turnOn).onPressed, isNull);

      await tester.enterText(password, 'hunter2');
      await tester.pump();
      final field = tester.widget<TextField>(password);
      expect(field.obscureText, isTrue);
      expect(field.enableSuggestions, isFalse);
      await tester.tap(turnOn);
      await tester.pumpAndSettle();

      expect(_answers(harness.engine), ['p-1: secret hunter2']);
      expect(title, findsNothing);
    });

    testWidgets('says when the last password was refused, and Cancel '
        'answers none', (tester) async {
      final harness = await pumpApp(tester, servers: twoServers);
      harness.engine.emit(
        _prompt(
          'p-1',
          const ElevationPromptRequest(user: 'deploy', retry: true),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('That password did not work. Try again.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(_answers(harness.engine), ['p-1: secret null']);
    });

    testWidgets('a withdrawn prompt closes the dialog unanswered', (
      tester,
    ) async {
      final harness = await pumpApp(tester, servers: twoServers);
      harness.engine.emit(
        _prompt('p-1', const ElevationPromptRequest(user: 'deploy')),
      );
      await tester.pumpAndSettle();
      harness.engine.emit(
        const PromptWithdrawn('p-1', PromptWithdrawnReason.expired),
      );
      await tester.pumpAndSettle();

      expect(title, findsNothing);
      expect(_answers(harness.engine), isEmpty);
    });
  });
}
