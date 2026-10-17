import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// The prompt concern (03 §10.1, version 3 M2 prompts): the engine's
/// [Prompt]s still waiting on the user, oldest first, and their answers.
/// The app shows [current] alone, so dialogs never stack: the next prompt
/// waits until the one before it is answered or withdrawn.
///
/// A prompt leaves the queue when [answer] sends its answer, when the
/// engine withdraws it ([PromptWithdrawn]: it expired, or its attempt
/// ended), and when the engine stops. A surface that awaits the user
/// checks [isOpen] once the await returns, before it answers: a dialog
/// closed under it returns its cancel value, which is not the user's.
///
/// Pull-only (D14): its one request, [AnswerPrompt], answers the engine's
/// own question and writes no catalog record. Like the other controllers
/// it lasts one engine run.
final class PromptController extends ChangeNotifier {
  PromptController(this._engine) {
    _events = _engine.events.listen(_onEngineEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;

  /// The open prompts in the order the engine sent them.
  final List<Prompt> _queue = [];
  bool _engineStopped = false;

  /// The prompt to show now: the oldest open one, or null.
  Prompt? get current => _queue.firstOrNull;

  /// Whether [promptId] still waits on an answer.
  bool isOpen(String promptId) => _indexOf(promptId) >= 0;

  /// Sends [answer] to the open prompt [promptId], which leaves the queue.
  /// Returns false, sending nothing, when the prompt is no longer open.
  ///
  /// The engine may still reject the answer: one that crossed the prompt's
  /// withdrawal finds nothing open there. Its [RequestRejected] needs no
  /// handling, since the withdrawal that follows it closes the prompt here.
  bool answer(String promptId, PromptAnswer answer) {
    final index = _indexOf(promptId);
    if (index < 0) return false;

    _queue.removeAt(index);
    _send(AnswerPrompt(promptId, answer));
    notifyListeners();
    return true;
  }

  int _indexOf(String promptId) =>
      _queue.indexWhere((prompt) => prompt.promptId == promptId);

  /// Sends [request] unless the engine has stopped.
  void _send(EngineRequest request) {
    if (_engineStopped) return;
    try {
      _engine.send(request);
    } on StateError {
      _onEngineDone();
    }
  }

  void _onEngineEvent(EngineEvent event) {
    switch (event) {
      case Prompt():
        _queue.add(event);
        notifyListeners();
      case PromptWithdrawn(:final promptId):
        final index = _indexOf(promptId);
        if (index < 0) return;
        _queue.removeAt(index);
        notifyListeners();
      default:
        break;
    }
  }

  /// A stopped engine waits on nothing, so every prompt closes unanswered.
  void _onEngineDone() {
    _engineStopped = true;
    if (_queue.isEmpty) return;

    _queue.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _queue.clear();
    unawaited(_events.cancel());
    super.dispose();
  }
}
