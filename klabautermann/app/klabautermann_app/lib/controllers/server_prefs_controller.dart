import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'safety_controller.dart' show ServerPrefsSource;

/// A preferences write the engine refused or never answered (03 §4.8).
final class ServerPrefsNotSavedException implements Exception {
  const ServerPrefsNotSavedException(this.failure, [this.detail]);

  /// Null when the engine stopped before it answered.
  final CatalogWriteFailure? failure;
  final String? detail;

  /// A diagnostic; a null failure means the engine stopped.
  @override
  String toString() => 'ServerPrefsNotSavedException: $failure, $detail';
}

/// The synced servers' preferences (03 §4.8, SYN-04, M5 plan M06): which
/// fleet servers' preferences sync, what their `pref` records hold as the
/// engine reports them, and the writes that change one. A server syncs
/// its preferences while the fleet lists it as synced and not excluded.
final class ServerPrefsController extends ChangeNotifier
    implements ServerPrefsSource {
  ServerPrefsController(this._engine) {
    _events = _engine.events.listen(_onEngineEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;

  final Map<String, ServerPrefs> _prefs = {};
  Set<String> _syncing = const {};
  final Map<String, Completer<void>> _writes = {};
  var _count = 0;

  @override
  Map<String, ServerPrefs> get prefs => Map.unmodifiable(_prefs);

  @override
  bool syncs(String serverId) => _syncing.contains(serverId);

  /// Seals [prefs] as [serverId]'s `pref` record, or its removal when
  /// null; completes once the engine wrote it, after the
  /// [ServerPrefsChanged] that shows it, and throws
  /// [ServerPrefsNotSavedException] when it was refused.
  @override
  Future<void> write(String serverId, ServerPrefs? prefs) {
    final requestId = 'prefs-${_count++}';
    final written = Completer<void>();
    _writes[requestId] = written;
    try {
      _engine.send(
        SetServerPrefs(requestId: requestId, serverId: serverId, prefs: prefs),
      );
    } on StateError {
      _writes.remove(requestId);
      return Future.error(const ServerPrefsNotSavedException(null));
    }
    return written.future;
  }

  void _onEngineEvent(EngineEvent event) {
    switch (event) {
      case CatalogReplaced(:final entries):
        final syncing = {
          for (final entry in entries)
            if (entry.origin == FleetEntryOrigin.synced &&
                !entry.excludedFromSync)
              entry.serverId,
        };
        if (setEquals(syncing, _syncing)) return;
        _syncing = Set.unmodifiable(syncing);
        notifyListeners();
      case ServerPrefsChanged(:final serverId, :final prefs):
        if (prefs == null) {
          if (_prefs.remove(serverId) == null) return;
        } else {
          _prefs[serverId] = prefs;
        }
        notifyListeners();
      case CatalogWritten(:final requestId):
        _writes.remove(requestId)?.complete();
      case CatalogWriteRefused(:final requestId, :final failure, :final detail):
        _writes
            .remove(requestId)
            ?.completeError(ServerPrefsNotSavedException(failure, detail));
      case _:
    }
  }

  void _onEngineDone() {
    for (final written in _writes.values) {
      written.completeError(const ServerPrefsNotSavedException(null));
    }
    _writes.clear();
  }

  @override
  void dispose() {
    unawaited(_events.cancel());
    _onEngineDone();
    super.dispose();
  }
}
