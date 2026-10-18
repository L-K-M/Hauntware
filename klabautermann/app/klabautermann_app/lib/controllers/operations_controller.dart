import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// What [OperationsController.plan] got from the engine.
sealed class PlanAnswer {
  const PlanAnswer();
}

/// The engine's preview of the plan [planId], which [RunAction] runs.
final class PlanReady extends PlanAnswer {
  const PlanReady(this.planId, this.preview);

  final String planId;
  final ActionPreview preview;
}

/// The engine would not plan the intent, for [reason].
final class PlanRefused extends PlanAnswer {
  const PlanRefused(this.reason);

  final ActionRefusalReason reason;
}

/// Where a run the user confirmed stands.
sealed class RunState {
  const RunState();
}

/// Running step [stepIndex] of [stepCount].
final class RunInProgress extends RunState {
  const RunInProgress(this.stepIndex, this.stepCount);

  final int stepIndex;
  final int stepCount;
}

/// The run ended; [finished] says how, in typed facts.
final class RunFinished extends RunState {
  const RunFinished(this.finished);

  final ActionFinished finished;
}

/// The engine refused to start the run, for [reason].
final class RunRefused extends RunState {
  const RunRefused(this.reason);

  final ActionRefusalReason reason;
}

/// The operations concern (03 §8.5, SAF-04): asks the engine for a plan's
/// preview, runs the plan the user confirmed, and follows each run.
///
/// One preview is asked for at a time: the engine answers [PlanAction]
/// with an [ActionPlanned] or an [ActionRefused] that carries no plan id
/// to match, and planning reads the host, so answers can arrive out of
/// order. The preview is modal, so the app never needs two; a second
/// [plan] while one is pending throws [StateError]. Runs are matched by
/// plan id. Like the other per-run controllers it lasts one engine run.
final class OperationsController extends ChangeNotifier {
  OperationsController(this._engine) {
    _events = _engine.events.listen(_onEngineEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;
  Completer<PlanAnswer>? _pending;
  final Map<String, RunState> _runs = {};
  final Map<String, String> _targets = {};
  final _ends = StreamController<(String planId, RunState state)>.broadcast();
  bool _engineStopped = false;

  /// Whether a preview is being asked for.
  bool get planning => _pending != null;

  /// The target name [planId]'s preview showed, for the result toast.
  String? targetOf(String planId) => _targets[planId];

  /// [planId]'s run, or null when it was never run this engine run.
  RunState? runOf(String planId) => _runs[planId];

  /// Each run's end, finished or refused, as it happens: the result toast
  /// listens here.
  Stream<(String planId, RunState state)> get ends => _ends.stream;

  /// Asks the engine to plan [intent]. A stopped engine answers
  /// [ActionRefusalReason.noLink].
  Future<PlanAnswer> plan(ActionIntent intent) {
    if (_pending != null) throw StateError('a preview is already pending');
    if (_engineStopped) return Future.value(_noEngine);
    final pending = _pending = Completer<PlanAnswer>();
    _send(PlanAction(intent));
    return pending.future;
  }

  /// Runs the plan [planId] with the user's [confirmation].
  void run(String planId, ActionConfirmation confirmation) {
    _runs[planId] = const RunInProgress(0, 0);
    notifyListeners();
    _send(RunAction(planId, confirmation));
  }

  /// What a request the engine cannot take gets: no engine means no link.
  static const _noEngine = PlanRefused(ActionRefusalReason.noLink);

  void _send(EngineRequest request) {
    if (_engineStopped) return;
    try {
      _engine.send(request);
    } on StateError {
      _onEngineDone();
    }
  }

  void _answer(PlanAnswer answer) {
    final pending = _pending;
    _pending = null;
    pending?.complete(answer);
  }

  void _end(String planId, RunState state) {
    _runs[planId] = state;
    notifyListeners();
    _ends.add((planId, state));
  }

  void _onEngineEvent(EngineEvent event) {
    switch (event) {
      case ActionPlanned(:final planId, :final preview):
        _targets[planId] = preview.targetName;
        _answer(PlanReady(planId, preview));
      case ActionRefused(:final reason, :final planId?):
        _end(planId, RunRefused(reason));
      case ActionRefused(:final reason):
        _answer(PlanRefused(reason));
      case ActionProgress(:final planId, :final stepIndex, :final stepCount):
        _runs[planId] = RunInProgress(stepIndex, stepCount);
        notifyListeners();
      case ActionFinished(:final planId):
        _end(planId, RunFinished(event));
      default:
    }
  }

  void _onEngineDone() {
    if (_engineStopped) return;
    _engineStopped = true;
    _answer(_noEngine);
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_events.cancel());
    unawaited(_ends.close());
    super.dispose();
  }
}
