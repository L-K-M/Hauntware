import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart'
    show SafetyPolicy, ServerSafety, kAdminExpiryChoices;

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

  /// Replaces [serverId]'s preferences: management (SAF-01), read-only
  /// and the user's marks (SAF-22).
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

/// The app's safety concern (03 §10.1): this device's safety preferences,
/// which `settings.json` keeps and the engine enforces. Each change goes
/// to the engine through [apply] before it is saved, as the appearance
/// repaints before it is saved, so the engine never enforces less than
/// the screen shows; the composition root also applies the restored
/// policy once at spawn, since the engine starts observe-only.
final class SafetyController extends ChangeNotifier implements SafetySettings {
  SafetyController({
    SafetyPolicy initial = const SafetyPolicy(),
    required this._apply,
    this._labelOf,
    this._save,
  }) : _value = initial {
    _apply(_value);
  }

  SafetyPolicy _value;
  final void Function(SafetyPolicy policy) _apply;
  final String Function(String serverId)? _labelOf;
  final Future<void> Function(SafetyPolicy policy)? _save;

  @override
  SafetyPolicy get value => _value;

  @override
  String labelOf(String serverId) => _labelOf?.call(serverId) ?? serverId;

  @override
  Future<void> setGlobalReadOnly(bool readOnly) {
    if (readOnly == _value.globalReadOnly) return Future.value();
    return _change(
      SafetyPolicy(
        globalReadOnly: readOnly,
        servers: _value.servers,
        adminExpiry: _value.adminExpiry,
      ),
    );
  }

  @override
  Future<void> setAdminExpiry(Duration expiry) {
    if (!kAdminExpiryChoices.contains(expiry)) {
      // The engine would refuse the policy; the tab offers only choices.
      throw ArgumentError.value(expiry);
    }
    if (expiry == _value.adminExpiry) return Future.value();
    return _change(
      SafetyPolicy(
        globalReadOnly: _value.globalReadOnly,
        servers: _value.servers,
        adminExpiry: expiry,
      ),
    );
  }

  @override
  Future<void> setServerSafety(String serverId, ServerSafety safety) {
    final servers = {..._value.servers};
    // A server back at the defaults leaves the map, so the file keeps
    // only what the user chose.
    if (!safety.management && !safety.readOnly && safety.marks.isEmpty) {
      if (servers.remove(serverId) == null) return Future.value();
    } else {
      servers[serverId] = safety;
    }
    return _change(
      SafetyPolicy(
        globalReadOnly: _value.globalReadOnly,
        servers: Map.unmodifiable(servers),
        adminExpiry: _value.adminExpiry,
      ),
    );
  }

  Future<void> _change(SafetyPolicy policy) async {
    _value = policy;
    _apply(policy);
    notifyListeners();
    try {
      await _save?.call(policy);
    } on Exception catch (error, stackTrace) {
      Error.throwWithStackTrace(
        SafetyNotSavedException('The safety settings were not saved: $error'),
        stackTrace,
      );
    }
  }
}
