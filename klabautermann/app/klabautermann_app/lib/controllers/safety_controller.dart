import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart'
    show SafetyPolicy, ServerPrefs, ServerSafety, kAdminExpiryChoices;

// The types [SafetySettings] speaks, for the settings window's files,
// which import nothing from the engine package themselves.
export 'package:klabautermann_core/klabautermann_core.dart'
    show SafetyPolicy, ServerSafety;

/// What the Safety tab and the server header's switches read and change,
/// apart from where they run: [SafetyController] in the app, and a copy
/// kept over the settings link in the desktop settings window. [value] is
/// the policy the engine enforces (M4 plan M4): until the user turns
/// management on, every server is observe-only.
abstract interface class SafetySettings
    implements ValueListenable<SafetyPolicy> {
  /// The name the Safety tab shows for [serverId]'s marks: its fleet
  /// label, or the id when it has left the fleet.
  String labelOf(String serverId);

  /// Turns global read-only on or off (03 §8.2): no server takes an action
  /// while it is on.
  Future<void> setGlobalReadOnly(bool readOnly);

  /// Sets admin mode's inactivity expiry, one of [kAdminExpiryChoices].
  Future<void> setAdminExpiry(Duration expiry);

  /// Replaces [serverId]'s preferences: management (SAF-01), read-only,
  /// the user's marks (SAF-22) and the host syslog line (SAF-13).
  Future<void> setServerSafety(String serverId, ServerSafety safety);
}

/// A safety change that applied but was not saved: the engine enforces
/// it now, and it lasts until the app restarts unless a later save
/// carries it. [message] is what the failed save printed.
final class SafetyNotSavedException implements Exception {
  const SafetyNotSavedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The synced side of the safety preferences (03 §4.8, M5 plan M06):
/// which servers keep their read-only switch, marks and syslog line switch
/// in their `pref` record, what the records hold, and the write that
/// changes one.
abstract interface class ServerPrefsSource implements Listenable {
  /// Whether [serverId]'s preferences sync: a synced server, not excluded.
  bool syncs(String serverId);

  /// Every `pref` record the engine reported, by server id.
  Map<String, ServerPrefs> get prefs;

  /// Seals [prefs] as [serverId]'s `pref` record, or its removal when
  /// null; throws when the engine refused it.
  Future<void> write(String serverId, ServerPrefs? prefs);
}

/// The app's safety concern (03 §10.1): this device's safety preferences,
/// which `settings.json` keeps, and the synced servers' read-only switches,
/// marks and syslog line switches, which their `pref` records keep
/// ([ServerPrefsSource], M5 plan M06, M19); management, global read-only
/// and the admin expiry stay on this device. The engine enforces the two
/// merged ([value]). Each change goes to the engine through [apply]
/// before it is saved, as the appearance repaints before it is saved, so
/// the engine never enforces less than the screen shows; the composition
/// root also applies the restored policy once at spawn, since the engine
/// starts observe-only.
///
/// A syncing server's read-only switch, marks or syslog line switch still
/// stored on this device, from before M06 or from before its server
/// synced, move to its `pref` record once, merged with what the record
/// holds; until then they count beside it. Merged, a read-only switch on
/// and a syslog line off win, each being the user's choice against the
/// default. A server that stops syncing keeps what its record held, on
/// this device.
final class SafetyController extends ChangeNotifier implements SafetySettings {
  SafetyController({
    SafetyPolicy initial = const SafetyPolicy(),
    required this._apply,
    this._labelOf,
    this._save,
    this._prefs,
  }) : _local = initial,
       _value = initial {
    _value = _merged();
    _apply(_value);
    _prefs?.addListener(_prefsChanged);
    _migrate();
  }

  /// What `settings.json` keeps.
  SafetyPolicy _local;
  SafetyPolicy _value;
  final void Function(SafetyPolicy policy) _apply;
  final String Function(String serverId)? _labelOf;
  final Future<void> Function(SafetyPolicy policy)? _save;
  final ServerPrefsSource? _prefs;

  /// The `pref` writes on their way to the engine, which count in place of
  /// the record and of anything still stored here until they answer.
  final Map<String, ServerPrefs?> _pending = {};
  final Set<String> _migrating = {};

  @override
  SafetyPolicy get value => _value;

  @override
  String labelOf(String serverId) => _labelOf?.call(serverId) ?? serverId;

  @override
  Future<void> setGlobalReadOnly(bool readOnly) {
    if (readOnly == _local.globalReadOnly) return Future.value();
    return _change(
      SafetyPolicy(
        globalReadOnly: readOnly,
        servers: _local.servers,
        adminExpiry: _local.adminExpiry,
      ),
    );
  }

  @override
  Future<void> setAdminExpiry(Duration expiry) {
    if (!kAdminExpiryChoices.contains(expiry)) {
      // The engine would refuse the policy; the tab offers only choices.
      throw ArgumentError.value(expiry);
    }
    if (expiry == _local.adminExpiry) return Future.value();
    return _change(
      SafetyPolicy(
        globalReadOnly: _local.globalReadOnly,
        servers: _local.servers,
        adminExpiry: expiry,
      ),
    );
  }

  @override
  Future<void> setServerSafety(String serverId, ServerSafety safety) async {
    final prefs = _prefs;
    if (prefs == null || !prefs.syncs(serverId)) {
      if (_isDefaultSafety(safety) && !_local.servers.containsKey(serverId)) {
        return;
      }
      return _change(_withLocal(serverId, safety));
    }

    // Management stays on this device; the switch and marks go in the
    // server's record, replacing anything still stored here once written.
    final base = _pending.containsKey(serverId)
        ? _pending[serverId]
        : prefs.prefs[serverId];
    final next = (base ?? const ServerPrefs()).copyWith(
      readOnly: safety.readOnly,
      marks: safety.marks,
      hostAuditLine: safety.hostAuditLine,
    );
    _pending[serverId] = _isDefault(next) ? null : next;
    final local = _local.servers[serverId];
    final saving = local?.management == safety.management
        ? null
        : _change(
            _withLocal(
              serverId,
              (local ?? const ServerSafety()).copyWith(
                management: safety.management,
              ),
            ),
          );
    _refresh();
    try {
      await prefs.write(serverId, _pending[serverId]);
    } on Object catch (error) {
      throw SafetyNotSavedException(
        'The safety settings were not saved: $error',
      );
    } finally {
      _pending.remove(serverId);
      _refresh();
    }
    await _forgetStored(serverId);
    await saving;
  }

  /// [_local] with [serverId]'s entry set to [safety]; a server back at
  /// the defaults leaves the map, so the file keeps only what the user
  /// chose.
  SafetyPolicy _withLocal(String serverId, ServerSafety safety) {
    final servers = {..._local.servers};
    if (_isDefaultSafety(safety)) {
      servers.remove(serverId);
    } else {
      servers[serverId] = safety;
    }
    return SafetyPolicy(
      globalReadOnly: _local.globalReadOnly,
      servers: Map.unmodifiable(servers),
      adminExpiry: _local.adminExpiry,
    );
  }

  /// The policy the engine enforces: this device's, with each syncing
  /// server's switch and marks from its record, or from the write on its
  /// way there. Anything still stored here for a syncing server counts
  /// beside its record until it moves, so the engine never enforces less
  /// than either holds.
  SafetyPolicy _merged() {
    final prefs = _prefs;
    if (prefs == null) return _local;
    final servers = {..._local.servers};
    for (final id in {...servers.keys, ...prefs.prefs.keys, ..._pending.keys}) {
      if (!prefs.syncs(id)) continue;
      final local = _local.servers[id];
      final pending = _pending.containsKey(id);
      final synced = pending ? _pending[id] : prefs.prefs[id];
      final stored = pending ? null : local;
      final safety = ServerSafety(
        management: local?.management ?? false,
        readOnly: (synced?.readOnly ?? false) || (stored?.readOnly ?? false),
        marks: Set.unmodifiable({...?synced?.marks, ...?stored?.marks}),
        hostAuditLine:
            (synced?.hostAuditLine ?? true) && (stored?.hostAuditLine ?? true),
      );
      if (_isDefaultSafety(safety)) {
        servers.remove(id);
      } else {
        servers[id] = safety;
      }
    }
    return SafetyPolicy(
      globalReadOnly: _local.globalReadOnly,
      servers: Map.unmodifiable(servers),
      adminExpiry: _local.adminExpiry,
    );
  }

  void _refresh() {
    _value = _merged();
    _apply(_value);
    notifyListeners();
  }

  void _prefsChanged() {
    _keepLeaving();
    _refresh();
    _migrate();
  }

  /// A server whose record the engine still reports but which no longer
  /// syncs (excluded, or gone from the account) keeps its switch and
  /// marks on this device.
  void _keepLeaving() {
    final prefs = _prefs!;
    var kept = false;
    for (final MapEntry(key: id, value: synced) in prefs.prefs.entries) {
      if (prefs.syncs(id) ||
          !_holdsSynced(
            ServerSafety(
              readOnly: synced.readOnly,
              marks: synced.marks,
              hostAuditLine: synced.hostAuditLine,
            ),
          )) {
        continue;
      }
      final stored = _local.servers[id];
      final safety = ServerSafety(
        management: stored?.management ?? false,
        readOnly: synced.readOnly || (stored?.readOnly ?? false),
        marks: Set.unmodifiable({...synced.marks, ...?stored?.marks}),
        hostAuditLine: synced.hostAuditLine && (stored?.hostAuditLine ?? true),
      );
      if (stored?.readOnly == safety.readOnly &&
          setEquals(stored?.marks, safety.marks) &&
          stored?.hostAuditLine == safety.hostAuditLine) {
        continue;
      }
      _local = _withLocal(id, safety);
      kept = true;
    }
    // Saved in the background: no caller waits on a record's change.
    if (kept) _persistQuietly();
  }

  /// Moves each syncing server's stored switches and marks into its record,
  /// once, merged with what the record holds. One that is refused stays
  /// stored, counted beside the record, and is tried again on the next
  /// change.
  void _migrate() {
    final prefs = _prefs;
    if (prefs == null) return;
    for (final MapEntry(key: id, value: stored) in _local.servers.entries) {
      if (!prefs.syncs(id) ||
          _migrating.contains(id) ||
          _pending.containsKey(id) ||
          !_holdsSynced(stored)) {
        continue;
      }
      final base = prefs.prefs[id] ?? const ServerPrefs();
      final merged = base.copyWith(
        readOnly: base.readOnly || stored.readOnly,
        marks: {...base.marks, ...stored.marks},
        hostAuditLine: base.hostAuditLine && stored.hostAuditLine,
      );
      _migrating.add(id);
      unawaited(_moveToRecord(id, merged));
    }
  }

  Future<void> _moveToRecord(String serverId, ServerPrefs merged) async {
    try {
      await _prefs!.write(serverId, merged);
      await _forgetStored(serverId);
    } on Object catch (error) {
      debugPrint('Safety preferences of $serverId stay on this device: $error');
    } finally {
      _migrating.remove(serverId);
    }
  }

  /// Drops [serverId]'s stored switches and marks, which its record now
  /// holds, keeping management.
  Future<void> _forgetStored(String serverId) async {
    final stored = _local.servers[serverId];
    if (stored == null || !_holdsSynced(stored)) return;
    _local = _withLocal(serverId, ServerSafety(management: stored.management));
    _refresh();
    await _persist();
  }

  void _persistQuietly() => unawaited(
    _persist().catchError((Object error) => debugPrint(error.toString())),
  );

  Future<void> _persist() async {
    try {
      await _save?.call(_local);
    } on Exception catch (error, stackTrace) {
      Error.throwWithStackTrace(
        SafetyNotSavedException('The safety settings were not saved: $error'),
        stackTrace,
      );
    }
  }

  Future<void> _change(SafetyPolicy local) {
    _local = local;
    _refresh();
    return _persist();
  }

  static bool _isDefaultSafety(ServerSafety safety) =>
      !safety.management && !_holdsSynced(safety);

  /// Whether [safety] holds anything a synced server keeps in its record:
  /// a field away from its default.
  static bool _holdsSynced(ServerSafety safety) =>
      safety.readOnly || safety.marks.isNotEmpty || !safety.hostAuditLine;

  /// Whether [prefs] says nothing a missing record does not.
  static bool _isDefault(ServerPrefs prefs) =>
      !prefs.readOnly &&
      prefs.cadence == null &&
      prefs.pinnedUnits.isEmpty &&
      prefs.pinnedContainers.isEmpty &&
      prefs.marks.isEmpty &&
      prefs.panelOrder.isEmpty &&
      prefs.hostAuditLine &&
      prefs.stackScanDirs.isEmpty;

  @override
  void dispose() {
    _prefs?.removeListener(_prefsChanged);
    super.dispose();
  }
}
