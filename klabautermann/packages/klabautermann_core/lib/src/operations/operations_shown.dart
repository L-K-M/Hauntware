// What this device remembers of detached operations (03 §4.10, §7.17, M4
// plan M11): the launch facts of the operations it started, which the
// result's audit record names, and the results it has shown whose files
// still wait for cleanup. Device-local, never synced; an entry goes once
// the operation's files are gone.
import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart'
    show OpDirectoryKind;
import 'package:meta/meta.dart';
import 'package:seance_core/seance_core.dart' show SecretRedactor;

import '../catalog/sync_state_file.dart';
import '../engine/protocol.dart' show ConfirmationTier;
import 'operation_plan.dart';
import '../settings/device_settings_store.dart' show writeFileAtomically;
import '../settings/instance_lock.dart' show SupportDirectoryAccess;

final _redactor = SecretRedactor();

/// The file under the support directory (03 §4.10).
const String operationsShownFileName = 'operations_shown.json';

/// What this device launched: the audit record's facts, steps redacted as
/// the audit log stores them.
@immutable
final class OperationLaunch {
  OperationLaunch({
    required this.action,
    required this.targetName,
    required Iterable<String> steps,
    required this.tier,
    required this.startedAt,
  }) : steps = List.unmodifiable(steps);

  /// [plan]'s launch facts, its steps redacted as `AuditLog.recordRun`
  /// redacts a run's: the record outlives the run and is audited later.
  factory OperationLaunch.ofPlan(
    OperationPlan plan, {
    required DateTime startedAt,
  }) => OperationLaunch(
    action: '${plan.intent.runtimeType}',
    targetName: plan.targetName,
    steps: [for (final step in plan.steps) _redactor.redact(step.display)],
    tier: plan.tier,
    startedAt: startedAt,
  );

  final String action;
  final String targetName;
  final List<String> steps;
  final ConfirmationTier tier;
  final DateTime startedAt;
}

/// One remembered operation.
@immutable
final class OperationNote {
  const OperationNote({
    required this.directory,
    this.acknowledged = false,
    this.launch,
  });

  final OpDirectoryKind directory;

  /// Its result was shown and audited here; only cleanup remains.
  final bool acknowledged;

  /// Set when this device launched it.
  final OperationLaunch? launch;

  OperationNote acknowledge() =>
      OperationNote(directory: directory, acknowledged: true, launch: launch);
}

/// `operations_shown.json`: under `servers`, each server id maps each
/// operation id to `{"directory", "acknowledged", "launch": {"action",
/// "target", "steps", "tier", "startedAt"}}`, beside `"version": 1`;
/// `launch` is left out for an operation another device started. Kept like the sync state files
/// ([SyncStateFile]): written only while this process holds the support
/// directory alone, a damaged file set aside. Losing it costs the launch
/// facts of a result's audit record and the reminder of a cleanup, which
/// the 7-day prune covers.
final class OperationsShownStore {
  OperationsShownStore._(this._file, this._servers);

  /// A store that keeps its notes in memory only.
  OperationsShownStore.memory() : _file = null, _servers = {};

  final SyncStateFile? _file;
  final Map<String, Map<String, OperationNote>> _servers;

  /// Opens the file in [supportDirectory]; never throws.
  static Future<OperationsShownStore> open(
    Directory supportDirectory, {
    required SupportDirectoryAccess access,
    SyncStateWriter? writer,
  }) async {
    final (file, servers) = await SyncStateFile.open(
      File(
        '${supportDirectory.path}${Platform.pathSeparator}'
        '$operationsShownFileName',
      ),
      access: access,
      decode: _decode,
      writer: writer ?? writeFileAtomically,
    );
    return OperationsShownStore._(file, servers ?? {});
  }

  /// The problem met while opening, or null.
  SyncStateIssue? get issue => _file?.issue;

  /// [serverId]'s notes by operation id.
  Map<String, OperationNote> notesOf(String serverId) =>
      Map.unmodifiable(_servers[serverId] ?? const {});

  /// Records [note] for [serverId]'s operation [id].
  Future<void> put(String serverId, String id, OperationNote note) {
    (_servers[serverId] ??= {})[id] = note;
    return _save();
  }

  /// Drops [serverId]'s notes of [ids].
  Future<void> remove(String serverId, Iterable<String> ids) {
    final notes = _servers[serverId];
    if (notes == null) return Future.value();

    var changed = false;
    for (final id in ids) {
      changed = notes.remove(id) != null || changed;
    }
    if (notes.isEmpty) _servers.remove(serverId);
    return changed ? _save() : Future.value();
  }

  /// Drops every note of the servers outside [fleet], which left it.
  Future<void> retain(Set<String> fleet) {
    final before = _servers.length;
    _servers.removeWhere((serverId, _) => !fleet.contains(serverId));
    return _servers.length == before ? Future.value() : _save();
  }

  Future<void> _save() {
    final file = _file;
    if (file == null) return Future.value();
    return file.save({
      'servers': {
        for (final MapEntry(key: serverId, value: notes) in _servers.entries)
          serverId: {
            for (final MapEntry(key: id, value: note) in notes.entries)
              id: _encode(note),
          },
      },
    });
  }

  static Map<String, Object?> _encode(OperationNote note) => {
    'directory': note.directory.name,
    'acknowledged': note.acknowledged,
    if (note.launch case final launch?)
      'launch': {
        'action': launch.action,
        'target': launch.targetName,
        'steps': launch.steps,
        'tier': launch.tier.name,
        'startedAt': launch.startedAt.toUtc().toIso8601String(),
      },
  };

  static Map<String, Map<String, OperationNote>> _decode(
    Map<String, Object?> body,
  ) {
    final servers = body['servers'];
    if (servers is! Map<String, Object?>) {
      throw const FormatException('servers is not an object');
    }
    return {
      for (final MapEntry(key: serverId, value: notes) in servers.entries)
        serverId: switch (notes) {
          final Map<String, Object?> notes => {
            for (final MapEntry(key: id, value: note) in notes.entries)
              id: _decodeNote(note),
          },
          _ => throw FormatException('$serverId is not an object'),
        },
    };
  }

  static OperationNote _decodeNote(Object? note) {
    if (note case {
      'directory': final String directory,
      'acknowledged': final bool acknowledged,
    }) {
      final kind = OpDirectoryKind.values.asNameMap()[directory];
      if (kind == null) throw FormatException('unknown directory $directory');
      return OperationNote(
        directory: kind,
        acknowledged: acknowledged,
        launch: switch ((note as Map)['launch']) {
          null => null,
          final Object launch => _decodeLaunch(launch),
        },
      );
    }
    throw const FormatException('not an operation note');
  }

  static OperationLaunch _decodeLaunch(Object launch) {
    if (launch case {
      'action': final String action,
      'target': final String target,
      'steps': final List<Object?> steps,
      'tier': final String tier,
      'startedAt': final String startedAt,
    }) {
      final parsedTier = ConfirmationTier.values.asNameMap()[tier];
      final started = DateTime.tryParse(startedAt);
      if (parsedTier != null &&
          started != null &&
          steps.every((s) => s is String)) {
        return OperationLaunch(
          action: action,
          targetName: target,
          steps: steps.cast<String>(),
          tier: parsedTier,
          startedAt: started.toUtc(),
        );
      }
    }
    throw const FormatException('not a launch');
  }
}
