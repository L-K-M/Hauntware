import 'dart:async';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/links/prompt_broker.dart';
import 'package:test/test.dart';

/// A timer the test fires by hand.
final class _ManualTimer implements Timer {
  _ManualTimer(this.duration, this._callback);

  final Duration duration;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

const _hostKey = HostKeyPromptRequest(
  keyType: 'ssh-ed25519',
  fingerprintSha256: 'SHA256:abc',
);

const _twoQuestions = KeyboardInteractivePromptRequest(
  name: 'otp',
  questions: ['Password:', 'Code:'],
);

void main() {
  late List<EngineEvent> events;
  late List<_ManualTimer> timers;
  late PromptBroker broker;

  setUp(() {
    events = [];
    timers = [];
    var next = 0;
    broker = PromptBroker(
      emit: events.add,
      startTimer: (duration, callback) {
        final timer = _ManualTimer(duration, callback);
        timers.add(timer);
        return timer;
      },
      newPromptId: () => 'prompt-${++next}',
    );
  });

  test('sends a prompt and hands its answer to the waiter', () async {
    final answer = broker
        .attempt('ssh-config:web')
        .ask(host: '198.51.100.1', port: 2222, request: _hostKey);

    final prompt = events.single as Prompt;
    expect(prompt.promptId, 'prompt-1');
    expect(prompt.serverId, 'ssh-config:web');
    expect(prompt.host, '198.51.100.1');
    expect(prompt.port, 2222);
    expect(prompt.request, same(_hostKey));
    expect(timers.single.duration, kPromptExpiry);

    expect(
      broker.answer('prompt-1', const PromptTrustAnswer(true)),
      PromptAnswerResult.answered,
    );
    expect(((await answer)! as PromptTrustAnswer).accepted, isTrue);
    expect(timers.single.isActive, isFalse);
    // Answered once; a second answer finds nothing open.
    expect(
      broker.answer('prompt-1', const PromptTrustAnswer(false)),
      PromptAnswerResult.notOpen,
    );
    expect(
      broker.answer('from-an-earlier-engine', const PromptTrustAnswer(true)),
      PromptAnswerResult.notOpen,
    );
    expect(events, hasLength(1));
  });

  test('onSent sees each prompt once its event is out', () {
    final seen = <(Prompt, int)>[];
    broker
        .attempt('ssh-config:web', onSent: (p) => seen.add((p, events.length)))
        .ask(host: 'h', port: 22, request: _hostKey);

    final (prompt, eventsSoFar) = seen.single;
    expect(prompt, same(events.single));
    expect(eventsSoFar, 1);
  });

  test('an unanswered prompt expires and is withdrawn', () async {
    final answer = broker
        .attempt('ssh-config:web')
        .ask(host: 'h', port: 22, request: _hostKey);

    timers.single.fire();

    expect(await answer, isNull);
    final withdrawn = events.last as PromptWithdrawn;
    expect(withdrawn.promptId, 'prompt-1');
    expect(withdrawn.reason, PromptWithdrawnReason.expired);
    expect(
      broker.answer('prompt-1', const PromptTrustAnswer(true)),
      PromptAnswerResult.notOpen,
    );
  });

  test('ending an attempt withdraws only its open prompts', () async {
    final attempt = broker.attempt('ssh-config:web');
    final other = broker.attempt('ssh-config:db');
    final first = attempt.ask(host: 'h', port: 22, request: _hostKey);
    final second = attempt.ask(host: 'jump', port: 22, request: _twoQuestions);
    final elsewhere = other.ask(host: 'db', port: 22, request: _hostKey);
    broker.answer('prompt-1', const PromptTrustAnswer(true));
    events.clear();

    attempt.end();

    expect(await first, isA<PromptTrustAnswer>());
    expect(await second, isNull);
    expect(
      [
        for (final event in events.cast<PromptWithdrawn>())
          (event.promptId, event.reason),
      ],
      [('prompt-2', PromptWithdrawnReason.attemptEnded)],
    );
    expect(timers[1].isActive, isFalse);

    // An ended attempt asks nothing more; the other attempt is untouched.
    expect(await attempt.ask(host: 'h', port: 22, request: _hostKey), isNull);
    expect(events, hasLength(1));
    expect(
      broker.answer('prompt-3', const PromptTrustAnswer(false)),
      PromptAnswerResult.answered,
    );
    expect(await elsewhere, isA<PromptTrustAnswer>());
  });

  test('an answer that does not fit leaves the prompt open', () async {
    final answer = broker
        .attempt('ssh-config:web')
        .ask(host: 'h', port: 22, request: _twoQuestions);

    expect(
      broker.answer('prompt-1', const PromptTrustAnswer(true)),
      PromptAnswerResult.doesNotFit,
    );
    expect(
      broker.answer('prompt-1', const PromptResponsesAnswer(['only one'])),
      PromptAnswerResult.doesNotFit,
    );
    expect(
      broker.answer('prompt-1', const PromptResponsesAnswer(['pw', '123456'])),
      PromptAnswerResult.answered,
    );
    expect(((await answer)! as PromptResponsesAnswer).responses, [
      'pw',
      '123456',
    ]);

    // Password prompts take a secret, or null to dismiss.
    final attempt = broker.attempt('ssh-config:web');
    final secrets = [
      for (final request in const [
        CredentialPromptRequest(user: 'me'),
        ElevationPromptRequest(user: 'me'),
      ])
        attempt.ask(host: 'h', port: 22, request: request),
    ];
    expect(
      broker.answer('prompt-2', const PromptResponsesAnswer([])),
      PromptAnswerResult.doesNotFit,
    );
    expect(
      broker.answer('prompt-2', const PromptSecretAnswer('pw')),
      PromptAnswerResult.answered,
    );
    expect(
      broker.answer('prompt-3', const PromptSecretAnswer(null)),
      PromptAnswerResult.answered,
    );
    expect(((await secrets[0])! as PromptSecretAnswer).secret, 'pw');
    // A dismissal is an answer, unlike a withdrawal's null.
    expect(((await secrets[1])! as PromptSecretAnswer).secret, isNull);
  });

  test('a keyboard-interactive cancel ends the prompt at once', () async {
    final answer = broker
        .attempt('ssh-config:web')
        .ask(host: 'h', port: 22, request: _twoQuestions);

    // No response list declines: an empty one is the wrong count.
    expect(
      broker.answer('prompt-1', const PromptResponsesAnswer([])),
      PromptAnswerResult.doesNotFit,
    );
    expect(
      broker.answer('prompt-1', const PromptCancelAnswer()),
      PromptAnswerResult.answered,
    );

    expect(await answer, isA<PromptCancelAnswer>());
    expect(timers.single.isActive, isFalse);
    // Answered, not withdrawn: the prompt event is the only one.
    expect(events.single, isA<Prompt>());
    expect(
      broker.answer('prompt-1', const PromptCancelAnswer()),
      PromptAnswerResult.notOpen,
    );
  });

  test('only a keyboard-interactive prompt takes a cancel', () async {
    final attempt = broker.attempt('ssh-config:web');
    for (final request in const <PromptRequest>[
      _hostKey,
      CredentialPromptRequest(user: 'me'),
      ElevationPromptRequest(user: 'me'),
    ]) {
      unawaited(attempt.ask(host: 'h', port: 22, request: request));
    }

    for (final promptId in ['prompt-1', 'prompt-2', 'prompt-3']) {
      expect(
        broker.answer(promptId, const PromptCancelAnswer()),
        PromptAnswerResult.doesNotFit,
        reason: promptId,
      );
    }
    attempt.end();
  });

  test('a host-key prompt takes only a trust answer', () async {
    final answer = broker
        .attempt('ssh-config:web')
        .ask(host: 'h', port: 22, request: _hostKey);

    for (final wrong in const <PromptAnswer>[
      PromptResponsesAnswer(['yes']),
      PromptSecretAnswer('yes'),
    ]) {
      expect(broker.answer('prompt-1', wrong), PromptAnswerResult.doesNotFit);
    }
    expect(
      broker.answer('prompt-1', const PromptTrustAnswer(false)),
      PromptAnswerResult.answered,
    );
    expect(((await answer)! as PromptTrustAnswer).accepted, isFalse);
  });

  test('ids are UUIDs by default', () {
    final real = PromptBroker(emit: events.add);
    final attempt = real.attempt('s');
    unawaited(attempt.ask(host: 'h', port: 22, request: _hostKey));
    unawaited(attempt.ask(host: 'h', port: 22, request: _hostKey));
    attempt.end();

    final [first, second] = [
      for (final event in events.whereType<Prompt>()) event.promptId,
    ];
    final uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-');
    expect(first, matches(uuid));
    expect(second, isNot(first));
  });
}
