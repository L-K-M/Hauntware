import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'admin_controller.dart';
import 'app_lock_controller.dart' show AppLockSettings;

/// What Settings reads and changes of FL-16's admin memory, apart from
/// where it runs: [AdminMemoryController] in the app, and a copy kept
/// over the settings link in the desktop settings window. The value holds
/// the ids of the servers whose switch is on.
abstract interface class AdminMemorySettings
    implements ValueListenable<Set<String>> {
  /// Turns [serverId]'s switch on or off; a no-op when that is in force
  /// and saved. Throws [AdminMemoryNotSavedException] for a change that
  /// applied but was not saved.
  Future<void> setRemembered(String serverId, {required bool remembered});
}

/// An admin memory change that applied but was not saved: it lasts until
/// the app quits. [message] is what the failed save printed.
final class AdminMemoryNotSavedException implements Exception {
  const AdminMemoryNotSavedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The app's admin memory (FL-16, 03 §8.2, D69): the composition root
/// restores it from `settings.json` and saves every change there; off for
/// every server until the user turns a switch on. It stays on this device:
/// nothing here reaches the engine, whose sync is the only writer of
/// `pref` records, and nothing reads it from one, so another device can
/// never turn admin mode on here. [AdminRearm] acts on it. Without a save
/// callback, as in tests, it is held in memory only. A change applies
/// before it is saved.
final class AdminMemoryController extends ChangeNotifier
    implements AdminMemorySettings {
  AdminMemoryController({Set<String> remembered = const {}, this._save})
    : _value = Set.unmodifiable(remembered),
      _saved = Set.unmodifiable(remembered);

  Set<String> _value;

  /// The switches last known to be in `settings.json`.
  Set<String> _saved;
  final Future<void> Function(Set<String> serverIds)? _save;

  @override
  Set<String> get value => _value;

  @override
  Future<void> setRemembered(
    String serverId, {
    required bool remembered,
  }) async {
    if (_value.contains(serverId) == remembered &&
        _saved.contains(serverId) == remembered) {
      return;
    }
    if (_value.contains(serverId) != remembered) {
      _value = Set.unmodifiable(
        remembered ? {..._value, serverId} : _value.difference({serverId}),
      );
      notifyListeners();
    }
    final writing = _value;
    try {
      await _save?.call(writing);
      _saved = writing;
    } on Exception catch (error, stackTrace) {
      Error.throwWithStackTrace(
        AdminMemoryNotSavedException(
          'Remembered admin mode was not saved: $error',
        ),
        stackTrace,
      );
    }
  }
}

/// Turns admin mode back on once per launch on each server whose admin
/// memory switch is on (FL-16, 03 §8.2, D69).
///
/// Each server gets one decision per launch, at its first user-visible
/// connect: the first moment a view of it is open where the user can see
/// it (the app in the foreground and unlocked) while its link is up and
/// has answered a probe in this engine run, which admin mode needs to know
/// how to elevate. A link the monitor set dialed unattended decides
/// nothing until the user opens the server. At that moment, when the
/// switch is on, actions are allowed there, nothing is read-only and
/// admin mode was not asked for yet, it asks the engine as the header's
/// chip does, so the engine shows the password prompt when the host needs
/// one. Whatever follows ends the server's turn for the launch: a
/// cancelled prompt leaves it observe-only, and an end through
/// inactivity, the background, link loss or the lock is final until the
/// next launch, as for admin mode the user turned on. A switch turned on
/// after the decision applies from the next launch.
///
/// The engine is spawned once per launch (`main.dart`), so the decisions
/// last the engine run, like [AdminController].
final class AdminRearm {
  AdminRearm({
    required EngineClient engine,
    required this._admin,
    required this._remembered,
    required this._visibleServers,
    required this._safety,
    this._appLock,
  }) {
    _events = engine.events.listen(_onEngineEvent);
    _visibleServers.addListener(_considerVisible);
    _appLock?.addListener(_considerVisible);
  }

  final AdminController _admin;
  final ValueListenable<Set<String>> _remembered;
  final ValueListenable<Set<String>> _visibleServers;
  final ValueListenable<SafetyPolicy> _safety;
  final AppLockSettings? _appLock;
  late final StreamSubscription<EngineEvent> _events;

  /// The servers whose current link answered a probe in this run.
  final Set<String> _probed = {};

  /// The servers whose one decision this launch is made.
  final Set<String> _decided = {};

  void _onEngineEvent(EngineEvent event) {
    switch (event) {
      // A cached profile (D59) comes before the link is up and is not one
      // the engine elevates by: only this run's probe answer counts.
      case HostProfileChanged(:final serverId, cachedAt: null):
        _probed.add(serverId);
        _consider(serverId);
      case LinkState(status: LinkReady() || LinkDegraded()):
        // The probe the new link runs decides, not the link alone.
        break;
      case LinkState(:final serverId):
        _probed.remove(serverId);
      default:
    }
  }

  void _considerVisible() => _visibleServers.value.forEach(_consider);

  void _consider(String serverId) {
    if (_decided.contains(serverId)) return;
    if (!_visibleServers.value.contains(serverId)) return;
    if (!_probed.contains(serverId)) return;
    if (_appLock?.locked ?? false) return;

    _decided.add(serverId);
    if (!_remembered.value.contains(serverId)) return;
    if (!_allowsAdmin(_safety.value, serverId)) return;
    // Asked for already this run, by the user or the engine's answer.
    if (_admin.stateFor(serverId) != null) return;
    _admin.setEnabled(serverId, enabled: true);
  }

  /// Whether the engine would take [serverId]'s admin mode under [policy]:
  /// actions allowed (SAF-01) and neither the server nor the app
  /// read-only (SAF-06). Checked here so a remembered switch on an
  /// observe-only server stays silent rather than reporting a refusal.
  static bool _allowsAdmin(SafetyPolicy policy, String serverId) {
    final server = policy.servers[serverId] ?? const ServerSafety();
    return server.management && !server.readOnly && !policy.globalReadOnly;
  }

  void dispose() {
    unawaited(_events.cancel());
    _visibleServers.removeListener(_considerVisible);
    _appLock?.removeListener(_considerVisible);
  }
}
