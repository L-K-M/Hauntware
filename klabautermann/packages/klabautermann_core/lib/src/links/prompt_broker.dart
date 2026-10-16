import 'dart:async';

import 'package:seance_core/seance_core.dart' show uuidV4;

import '../engine/protocol.dart';

/// How long a prompt waits for its answer before the engine withdraws it
/// [E]: OpenSSH's default `LoginGraceTime` (sshd_config(5)), after which
/// such a server has dropped the unauthenticated connection anyway.
const Duration kPromptExpiry = Duration(minutes: 2);

/// What [PromptBroker.answer] did with an [AnswerPrompt].
enum PromptAnswerResult {
  /// The answer reached the prompt's waiter.
  answered,

  /// No prompt with that id is open: it expired, was withdrawn or
  /// answered, or this engine never sent it.
  notOpen,

  /// The answer does not fit the prompt: another [PromptKind]'s answer, or
  /// keyboard-interactive responses whose count is not the question
  /// count. The prompt stays open.
  doesNotFit,
}

/// Sends [Prompt] events and hands each [AnswerPrompt] to the code that
/// waits on it (03 §10.1). Prompts are keyed by `promptId`, a UUID, so an
/// answer meant for an earlier engine's prompt matches nothing here. A
/// prompt nobody answers within the expiry, or whose [PromptAttempt]
/// ends first, is withdrawn with a [PromptWithdrawn] event, and its waiter
/// gets no answer.
final class PromptBroker {
  /// `emit` sends an event to the app; `expiry` is how long a prompt
  /// waits. `startTimer` and `newPromptId` are test seams.
  PromptBroker({
    required this._emit,
    this._expiry = kPromptExpiry,
    this._startTimer = Timer.new,
    this._newPromptId = uuidV4,
  });

  final void Function(EngineEvent event) _emit;
  final Duration _expiry;
  final Timer Function(Duration duration, void Function() callback) _startTimer;
  final String Function() _newPromptId;
  final Map<String, _OpenPrompt> _open = {};

  /// Opens the scope of one connect attempt or operation on [serverId]:
  /// its prompts name that server and end with it. [onSent] sees each of
  /// its [Prompt]s right after the event goes out, so the attempt can say
  /// it waits on that prompt.
  PromptAttempt attempt(
    String serverId, {
    void Function(Prompt prompt)? onSent,
  }) => PromptAttempt._(this, serverId, onSent);

  /// Routes [answer] to the open prompt [promptId]. Any other result than
  /// [PromptAnswerResult.answered] leaves the request for the engine to
  /// reject.
  PromptAnswerResult answer(String promptId, PromptAnswer answer) {
    final prompt = _open[promptId];
    if (prompt == null) return PromptAnswerResult.notOpen;
    if (!_fits(prompt.request, answer)) return PromptAnswerResult.doesNotFit;

    _close(promptId, prompt).complete(answer);
    return PromptAnswerResult.answered;
  }

  Future<PromptAnswer?> _ask(
    PromptAttempt attempt, {
    required String host,
    required int port,
    required PromptRequest request,
  }) {
    final promptId = _newPromptId();
    assert(!_open.containsKey(promptId), 'prompt ids are unique');
    final prompt = _OpenPrompt(attempt, request);
    _open[promptId] = prompt;
    prompt.expiry = _startTimer(
      _expiry,
      () => _withdraw(promptId, PromptWithdrawnReason.expired),
    );
    final event = Prompt(
      promptId: promptId,
      serverId: attempt.serverId,
      host: host,
      port: port,
      request: request,
    );
    _emit(event);
    attempt._onSent?.call(event);
    return prompt.answer.future;
  }

  void _withdraw(String promptId, PromptWithdrawnReason reason) {
    final prompt = _open[promptId];
    if (prompt == null) return;

    _close(promptId, prompt).complete(null);
    _emit(PromptWithdrawn(promptId, reason));
  }

  void _end(PromptAttempt attempt) {
    final ids = [
      for (final MapEntry(:key, :value) in _open.entries)
        if (identical(value.attempt, attempt)) key,
    ];
    for (final promptId in ids) {
      _withdraw(promptId, PromptWithdrawnReason.attemptEnded);
    }
  }

  /// Forgets [prompt] and stops its expiry; returns its completer.
  Completer<PromptAnswer?> _close(String promptId, _OpenPrompt prompt) {
    _open.remove(promptId);
    prompt.expiry?.cancel();
    return prompt.answer;
  }

  static bool _fits(PromptRequest request, PromptAnswer answer) =>
      switch (request) {
        HostKeyPromptRequest() => answer is PromptTrustAnswer,
        // Declining takes a cancel: no response list stands for it, so an
        // empty one to questions does not fit.
        KeyboardInteractivePromptRequest(:final questions) =>
          answer is PromptCancelAnswer ||
              answer is PromptResponsesAnswer &&
                  answer.responses.length == questions.length,
        CredentialPromptRequest() ||
        ElevationPromptRequest() => answer is PromptSecretAnswer,
      };
}

/// The prompts of one connect attempt or operation on [serverId]
/// ([PromptBroker.attempt]). [end] withdraws those still open, so the app
/// closes them once nothing waits on their answers.
final class PromptAttempt {
  PromptAttempt._(this._broker, this.serverId, this._onSent);

  final PromptBroker _broker;
  final void Function(Prompt prompt)? _onSent;

  /// The fleet server the attempt belongs to, which every [Prompt] names.
  final String serverId;

  var _ended = false;

  /// Sends a [Prompt] for [request] from the machine at [host]:[port] (the
  /// server or one of its jump hosts) and waits for its answer, which
  /// [PromptBroker.answer] has checked fits [request]. Completes with null
  /// when the prompt is withdrawn, or at once after [end].
  Future<PromptAnswer?> ask({
    required String host,
    required int port,
    required PromptRequest request,
  }) {
    if (_ended) return Future.value();
    return _broker._ask(this, host: host, port: port, request: request);
  }

  /// Withdraws this attempt's open prompts with
  /// [PromptWithdrawnReason.attemptEnded]; later [ask]s get no answer.
  void end() {
    _ended = true;
    _broker._end(this);
  }
}

final class _OpenPrompt {
  _OpenPrompt(this.attempt, this.request);

  final PromptAttempt attempt;
  final PromptRequest request;
  final Completer<PromptAnswer?> answer = Completer();
  Timer? expiry;
}
