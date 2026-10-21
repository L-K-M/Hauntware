import 'package:klabautermann_core/klabautermann_core.dart'
    show
        DeviceSettingsStore,
        EngineClient,
        SafetyPolicy,
        ServerSafety,
        SetSafetyPolicy,
        kAdminExpiryChoices,
        kDefaultAdminExpiry;

import '../controllers/safety_controller.dart';

/// The keys of the safety object in `settings.json`.
enum _SafetyKey { globalReadOnly, adminExpiryMinutes, servers }

/// The keys of one server's entry under [_SafetyKey.servers].
enum _ServerKey { management, readOnly, marks }

/// The app's safety preferences over [settings], applied to [engine] at
/// once and on every change, and saved on every change.
/// [prefs] carries the synced servers' switches and marks (M5 plan M06).
SafetyController safetyFromSettings(
  DeviceSettingsStore settings,
  EngineClient engine, {
  String Function(String serverId)? labelOf,
  ServerPrefsSource? prefs,
}) => SafetyController(
  initial: decodeStoredSafety(settings.safety),
  apply: (policy) {
    try {
      engine.send(SetSafetyPolicy(policy));
    } on StateError {
      // A stopped engine enforces nothing; the next one gets the policy
      // at its spawn.
    }
  },
  labelOf: labelOf,
  save: (policy) => settings.setSafety(encodeStoredSafety(policy)),
  prefs: prefs,
);

/// The policy [json] holds, leniently: anything unreadable reads as the
/// safe default (management off, the default expiry), so a damaged file
/// can only take actions away, never grant them. A read-only switch that
/// is there but not a bool reads as on: as off it would hand actions
/// back.
SafetyPolicy decodeStoredSafety(Map<String, Object?>? json) {
  final minutes = json?[_SafetyKey.adminExpiryMinutes.name];
  final expiry = minutes is int ? Duration(minutes: minutes) : null;
  final servers = <String, ServerSafety>{};
  if (json?[_SafetyKey.servers.name] case final Map<String, Object?> map) {
    for (final MapEntry(key: id, :value) in map.entries) {
      if (value is! Map<String, Object?>) continue;
      final safety = decodeServerSafety(value);
      servers[id] = safety;
    }
  }
  return SafetyPolicy(
    globalReadOnly: _readOnly(json?[_SafetyKey.globalReadOnly.name]),
    servers: Map.unmodifiable(servers),
    adminExpiry: kAdminExpiryChoices.contains(expiry)
        ? expiry!
        : kDefaultAdminExpiry,
  );
}

/// The inverse of [decodeStoredSafety], with marks sorted so the file does
/// not churn with the order they were added in.
Map<String, Object?> encodeStoredSafety(SafetyPolicy policy) => {
  _SafetyKey.globalReadOnly.name: policy.globalReadOnly,
  _SafetyKey.adminExpiryMinutes.name: policy.adminExpiry.inMinutes,
  _SafetyKey.servers.name: {
    for (final MapEntry(key: id, value: safety) in policy.servers.entries)
      id: encodeServerSafety(safety),
  },
};

/// One server's preferences as [encodeStoredSafety] stores them.
Map<String, Object?> encodeServerSafety(ServerSafety safety) => {
  _ServerKey.management.name: safety.management,
  _ServerKey.readOnly.name: safety.readOnly,
  _ServerKey.marks.name: safety.marks.toList()..sort(),
};

/// The inverse of [encodeServerSafety], as leniently as
/// [decodeStoredSafety]: a damaged read-only switch turns management off.
ServerSafety decodeServerSafety(Map<String, Object?> json) {
  final readOnly = json[_ServerKey.readOnly.name];
  final damaged = readOnly != null && readOnly is! bool;
  return ServerSafety(
    management: !damaged && json[_ServerKey.management.name] == true,
    readOnly: readOnly == true,
    marks: switch (json[_ServerKey.marks.name]) {
      final List<Object?> marks => Set.unmodifiable(marks.whereType<String>()),
      _ => const {},
    },
  );
}

/// A stored read-only switch: off only when absent or false.
bool _readOnly(Object? value) => value != null && value != false;
