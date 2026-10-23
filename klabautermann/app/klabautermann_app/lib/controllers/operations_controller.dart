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
  /// [auditInMemory] is what the engine's handshake said of its audit
  /// log: kept in memory for this run, without the support directory to
  /// itself (03 §8.10).
  OperationsController(this._engine, {this.auditInMemory = false}) {
    _events = _engine.events.listen(_onEngineEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;

  /// Whether the audit log lives in memory for this run only.
  final bool auditInMemory;

  /// Audit reads waiting on the engine, oldest first, by server: it
  /// answers each [AuditQuery] in order and names only the server.
  final Map<String, List<Completer<AuditRecords>>> _auditReads = {};

  /// Each server's footprint as the engine last verified it (SAF-14).
  final Map<String, FootprintState> _footprints = {};

  /// Servers with a [FootprintQuery] out and no answer yet.
  final Set<String> _footprintAsked = {};

  /// Servers whose last [FootprintQuery] the engine refused: no link, or
  /// not in the fleet.
  final Set<String> _footprintRefused = {};

  /// Edit reads waiting on the engine, by request id.
  final Map<String, Completer<EditReadResult>> _editReads = {};
  int _nextEditRead = 0;
  late final StreamSubscription<EngineEvent> _events;
  Completer<PlanAnswer>? _pending;
  final Map<String, RunState> _runs = {};
  final Map<String, OperationsChanged> _detached = {};
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

  /// [serverId]'s detached operations (03 §7.17) as the engine last listed
  /// them, launched here or elsewhere; none before the first list.
  List<DetachedOperation> detachedOf(String serverId) =>
      _detached[serverId]?.operations ?? const [];

  /// Whether [serverId]'s operation directories could not all be read, so
  /// the list may lack operations.
  bool detachedIncomplete(String serverId) {
    final changed = _detached[serverId];
    if (changed == null) return false;
    return changed.unavailable != null ||
        changed.directories.values.any(
          (listing) =>
              listing.state == OpDirectoryState.denied ||
              listing.state == OpDirectoryState.incomplete,
        );
  }

  /// Tells the engine the user saw [id]'s result, which audits it and
  /// deletes its files (at once in the user directory, the root one's
  /// once admin mode is on). The next list drops or marks it.
  void acknowledge(String serverId, String id) =>
      _send(AcknowledgeOperation(serverId, id));

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

  /// [serverId]'s audit records that ended before [before], newest first
  /// (SAF-11). A stopped engine answers none.
  Future<AuditRecords> readAudit(String serverId, {DateTime? before}) {
    if (_engineStopped) return Future.value(AuditRecords(serverId, const []));
    final read = Completer<AuditRecords>();
    (_auditReads[serverId] ??= []).add(read);
    _send(AuditQuery(serverId, before: before));
    return read.future;
  }

  /// Reads [target] on [serverId] for the editor (03 §8.5, SAF-12): its
  /// text and the hash an edit is planned against. A stopped engine
  /// answers no link.
  Future<EditReadResult> readEditable(String serverId, EditTarget target) {
    if (_engineStopped) return Future.value(_noEditRead);
    final requestId = 'edit-${_nextEditRead++}';
    final read = _editReads[requestId] = Completer<EditReadResult>();
    _send(
      ReadEditable(serverId: serverId, requestId: requestId, target: target),
    );
    return read.future;
  }

  static const _noEditRead = EditReadFailed(EditReadFailure.noLink);

  /// [serverId]'s footprint as the engine last verified it, on connect,
  /// when admin mode turned on, after an edit or a backup removal, or on
  /// [verifyFootprint]; null before the first.
  FootprintState? footprintOf(String serverId) => _footprints[serverId];

  /// Asks the engine to verify [serverId]'s footprint again; the answer
  /// replaces [footprintOf].
  void verifyFootprint(String serverId) {
    _footprintAsked.add(serverId);
    if (_footprintRefused.remove(serverId)) notifyListeners();
    _send(FootprintQuery(serverId));
  }

  /// Whether the engine refused [serverId]'s last [verifyFootprint], so
  /// no answer will come until it is asked again.
  bool footprintRefused(String serverId) =>
      _footprintRefused.contains(serverId);

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
      case OperationsChanged(:final serverId):
        _detached[serverId] = event;
        notifyListeners();
      case FootprintState(:final serverId):
        _footprints[serverId] = event;
        _footprintAsked.remove(serverId);
        _footprintRefused.remove(serverId);
        notifyListeners();
      case RequestRejected(:final requestName, :final reason)
          when requestName == '$FootprintQuery':
        // A rejection names no request, but the engine's reasons for this
        // one end with the server it was for (engine_isolate.dart).
        final refused = [
          for (final id in _footprintAsked)
            if (reason.endsWith(' $id')) id,
        ];
        if (refused.isEmpty) return;
        _footprintAsked.removeAll(refused);
        _footprintRefused.addAll(refused);
        notifyListeners();
      case EditRead(:final requestId, :final result):
        _editReads.remove(requestId)?.complete(result);
      case AuditRecords(:final serverId):
        final waiting = _auditReads[serverId];
        if (waiting == null || waiting.isEmpty) return;
        waiting.removeAt(0).complete(event);
      default:
    }
  }

  void _onEngineDone() {
    if (_engineStopped) return;
    _engineStopped = true;
    _answer(_noEngine);
    for (final MapEntry(key: serverId, value: waiting) in _auditReads.entries) {
      for (final read in waiting) {
        read.complete(AuditRecords(serverId, const []));
      }
    }
    _auditReads.clear();
    for (final read in _editReads.values) {
      read.complete(_noEditRead);
    }
    _editReads.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_events.cancel());
    unawaited(_ends.close());
    super.dispose();
  }
}
