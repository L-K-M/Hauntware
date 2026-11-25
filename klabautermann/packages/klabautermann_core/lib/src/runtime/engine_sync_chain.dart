import 'dart:async';
import 'dart:convert' show jsonEncode;

import 'package:seance_core/catalog.dart' show EndpointPinStore;

import '../alerts/alert_evaluator.dart';
import '../catalog/engine_sync.dart';
import '../catalog/klabautermann_records.dart'
    show diffServerPrefs, encodeSyncedRule;
import '../engine/protocol.dart';
import '../engine/serial_chain.dart';
import '../fleet/synced_fleet.dart';

/// The engine's sync chain (ENG-11 step 3, ARC-05): sync operations, catalog
/// writes and pin publication, one at a time in request order beside the
/// request queue rather than in it, so an enrollment waits on the network, a
/// key derivation and the app's keystore answers, which arrive as requests,
/// while links, sampling and imports go on meanwhile.
///
/// Every dependency is fixed at construction. [sync] is read through a
/// getter because the engine assigns it once startup has opened it, and the
/// fleet accessors stay with the code that owns their state.
final class EngineSyncChain {
  EngineSyncChain({
    required this._sync,
    required this._send,
    required this._alerts,
    required this._fleetEntries,
    required this._syncedFleet,
    required this._refreshSynced,
    required this._relistSynced,
    required this._endpointPins,
    required this._pinPublicationRelease,
    required this._fault,
  });

  final EngineSync Function() _sync;
  final void Function(EngineEvent event) _send;
  final AlertEvaluator _alerts;
  final List<FleetEntry> Function() _fleetEntries;
  final SyncedFleet Function() _syncedFleet;
  final Future<void> Function() _refreshSynced;
  final Future<void> Function() _relistSynced;
  final EndpointPinStore _endpointPins;
  final String? _pinPublicationRelease;
  final void Function(Object error, StackTrace stack) _fault;

  // The synced preferences the app last heard, so a round sends only
  // what changed.
  var _prefsSent = <String, String>{};
  // The alert rules the app last heard, encoded; none to start with.
  var _rulesSent = '[]';
  // The snippets the app last heard, encoded likewise.
  var _snippetsSent = '[]';

  Future<void> _syncTail = Future<void>.value();

  // Each link completes normally whatever its body throws: [onError]
  // answers the request that asked, and without one the error is
  // reported as a fault.
  void chain(
    Future<void> Function() body, {
    void Function(Object error)? onError,
  }) {
    _syncTail = chainAfter(_syncTail, body, onError: onError, onFault: _fault);
  }

  // Null while no release is offered: the app's default state says so.
  PinPublicationState? pinPublicationState() {
    final release = _pinPublicationRelease;
    if (release == null) return null;
    return PinPublicationState(
      release: release,
      asserted: _sync().pinPublicationAsserted(release),
    );
  }

  // [requestId] is the request's own, echoed on each status; null for a
  // round the engine starts itself.
  void runSync(
    SyncOperation operation,
    Future<SyncStatus> Function() body, {
    String? requestId,
  }) {
    chain(() async {
      _send(
        SyncStatus(
          SyncPhase.running,
          operation: operation,
          requestId: requestId,
          account: _sync().account,
        ),
      );
      final SyncStatus status;
      try {
        status = await body();
        // The fleet first, so it shows the servers when the answer arrives.
        if (status.phase == SyncPhase.succeeded) {
          await _refreshSynced();
        }
      } on Object catch (error) {
        // EngineSync answers every failure itself; this keeps the chain
        // alive should that, or the fleet refresh, ever slip: a chained
        // operation runs only after the one before it completes normally.
        _send(
          SyncStatus(
            SyncPhase.failed,
            operation: operation,
            requestId: requestId,
            account: _sync().account,
            failure: SyncFailure.other,
            detail: '$error',
          ),
        );
        return;
      }
      if (status.phase == SyncPhase.succeeded) {
        _send(CatalogReplaced(_fleetEntries()));
        // The round took, so it is answered as it ended even when the
        // preferences it pulled cannot be sent on: records from other
        // devices are encoded there, and the next round sends them again.
        try {
          await sendServerPrefs();
        } on Object catch (error, stack) {
          _fault(error, stack);
        }
      }
      _send(status.answering(requestId));
    });
  }

  // A catalog write runs on the sync chain too, so it never overlaps a
  // round. One that took shows in the fleet and the preferences before
  // its answer, and a round queued behind it pushes it. A saved server's
  // endpoint counts as confirmed on this device: the user typed it (M5
  // plan P16).
  void runWrite(
    String requestId,
    Future<EngineEvent> Function() body, {
    String? confirm,
    bool confirmWritten = false,
  }) {
    chain(() async {
      final EngineEvent answer;
      try {
        answer = await body();
      } on Object catch (error) {
        // EngineSync answers every refusal itself; this keeps the chain
        // alive should a write slip past that.
        _send(
          CatalogWriteRefused(
            requestId: requestId,
            failure: CatalogWriteFailure.other,
            detail: '$error',
          ),
        );
        return;
      }
      if (answer is CatalogWritten) {
        // The write is sealed, so it is answered as written and pushed
        // even when its fleet refresh, a pin's save or the preferences
        // throw; the next round's refresh shows what this one missed. A
        // throw here would also end the chain: a chained operation runs
        // only after the one before it completes normally.
        try {
          await _refreshSynced();
          final confirmed =
              confirm ?? (confirmWritten ? answer.serverId : null);
          if (confirmed != null) {
            for (final pin in _syncedFleet().pinsFor([
              confirmed,
            ], DateTime.now())) {
              await _endpointPins.confirm(pin);
            }
            await _relistSynced();
          }
          _send(CatalogReplaced(_fleetEntries()));
          await sendServerPrefs();
        } on Object {
          // Recovered as above.
        }
      }
      _send(answer);
      if (answer is CatalogWritten) {
        runSync(SyncOperation.round, _sync().runRound);
      }
    });
  }

  Future<void> sendServerPrefs() async {
    final sync = _sync();
    final (changes, sent) = diffServerPrefs(
      _prefsSent,
      await sync.serverPrefs(),
    );
    changes.forEach(_send);
    _prefsSent = sent;
    // By id, so a reload that lists the same rules in another order
    // sends nothing.
    final rules = [...await sync.rules()]..sort((a, b) => a.id.compareTo(b.id));
    final encoded = jsonEncode([
      for (final rule in rules) encodeSyncedRule(rule),
    ]);
    if (encoded != _rulesSent) {
      _send(AlertRulesChanged(List.unmodifiable(rules)));
      _rulesSent = encoded;
    }
    _alerts.setRules(rules, DateTime.now().toUtc()).forEach(_send);

    final snippets = sync.snippets();
    final snippetsEncoded = jsonEncode([
      for (final snippet in snippets) snippet.toJson(),
    ]);
    if (snippetsEncoded != _snippetsSent) {
      _send(SnippetsChanged(List.unmodifiable(snippets)));
      _snippetsSent = snippetsEncoded;
    }
  }
}
