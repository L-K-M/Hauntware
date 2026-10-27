// A read-only mirror of Séance's synced snippets (03 §7.21 AUT-01): the
// shared account carries `snippet:` records, which the catalog library
// leaves unread; Klabautermann runs them on a server but never edits,
// seals or deletes one.
import 'dart:io';

import 'package:seance_core/catalog.dart'
    show
        ApplyContext,
        ApplyOutcome,
        ApplyPhase,
        CatalogWriter,
        RecordHandler,
        SyncTuple,
        outranksMaterialized;
import 'package:seance_core/seance_core.dart'
    show DecryptedRecord, EncryptedRecord, RecordKind, Snippet;

import '../settings/device_settings_store.dart' show writeFileAtomically;
import '../settings/instance_lock.dart' show SupportDirectoryAccess;
import 'sync_state_file.dart';

/// The id prefix of Séance's snippet records.
const String snippetRecordPrefix = 'snippet';

/// The mirror's file in the support directory.
const String snippetMirrorFileName = 'snippet_mirror.json';

const String _snippetsKey = 'snippets';
const String _updatedAtKey = 'updatedAt';
const String _deviceIdKey = 'deviceId';
const String _snippetKey = 'snippet';
const String _removedKey = 'removed';

final class _Entry {
  const _Entry(this.tuple, this.snippet);

  final SyncTuple tuple;

  /// Null for a snippet a tombstone removed, kept for its tuple: an older
  /// live record pulled later must not bring it back.
  final Snippet? snippet;
}

/// `snippet_mirror.json`: each `snippet:` record the handler applied, by
/// record id, with the tuple it won with, so the tuple guard holds across
/// restarts.
final class SnippetMirror {
  SnippetMirror._(this._file, this._entries);

  final SyncStateFile _file;
  final Map<String, _Entry> _entries;

  /// Opens the file in [supportDirectory]. Never throws; a file it cannot
  /// use leaves the mirror empty and is reported in [issue].
  static Future<SnippetMirror> open(
    Directory supportDirectory, {
    required SupportDirectoryAccess access,
    SyncStateWriter writer = writeFileAtomically,
    DateTime Function() now = DateTime.now,
  }) async {
    final (file, entries) = await SyncStateFile.open(
      File(
        '${supportDirectory.path}${Platform.pathSeparator}'
        '$snippetMirrorFileName',
      ),
      access: access,
      decode: _decode,
      writer: writer,
      now: now,
    );
    return SnippetMirror._(file, entries ?? {});
  }

  /// The problem met while opening, or null when the file was fine or
  /// absent.
  SyncStateIssue? get issue => _file.issue;

  /// The live snippets, by title then id.
  List<Snippet> snippets() {
    final live = [
      for (final entry in _entries.values)
        if (entry.snippet case final snippet?) snippet,
    ];
    return live..sort((a, b) {
      final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      return byTitle != 0 ? byTitle : a.id.compareTo(b.id);
    });
  }

  SyncTuple? _tupleOf(String recordId) => _entries[recordId]?.tuple;

  Future<void> _put(String recordId, SyncTuple tuple, Snippet? snippet) {
    _entries[recordId] = _Entry(tuple, snippet);
    return _save();
  }

  Future<void> _save() => _file.save({
    _snippetsKey: {
      for (final id in _entries.keys.toList()..sort())
        id: {
          _updatedAtKey: _entries[id]!.tuple.updatedAt,
          _deviceIdKey: _entries[id]!.tuple.deviceId,
          if (_entries[id]!.snippet case final snippet?)
            _snippetKey: snippet.toJson()
          else
            _removedKey: true,
        },
    },
  });

  static Map<String, _Entry> _decode(Map<String, Object?> body) {
    final snippets = body[_snippetsKey];
    if (snippets == null) return {};
    if (snippets is! Map<String, Object?>) {
      throw const FormatException('snippets is not an object');
    }
    return {
      for (final MapEntry(:key, :value) in snippets.entries)
        key: switch (value) {
          {
            _updatedAtKey: final int updatedAt,
            _deviceIdKey: final String deviceId,
            _removedKey: true,
          } =>
            _Entry(SyncTuple(updatedAt: updatedAt, deviceId: deviceId), null),
          {
            _updatedAtKey: final int updatedAt,
            _deviceIdKey: final String deviceId,
            _snippetKey: final Map<String, Object?> snippet,
          } =>
            _Entry(
              SyncTuple(updatedAt: updatedAt, deviceId: deviceId),
              _snippetOf(key, snippet) ??
                  (throw FormatException('snippet $key is not a snippet')),
            ),
          _ => throw FormatException('snippet $key is not a stored snippet'),
        },
    };
  }
}

/// [data] as a snippet when it is one whose id matches [recordId], as
/// Séance's own apply requires; null otherwise. Like Séance, a missing
/// title or body reads as empty.
Snippet? _snippetOf(String recordId, Map<String, Object?> data) {
  if (data['id'] is! String ||
      data['title'] is! String? ||
      data['body'] is! String? ||
      data['createdAt'] is! num? ||
      data['updatedAt'] is! num?) {
    return null;
  }
  final snippet = Snippet.fromJson(data);
  if (recordId != '$snippetRecordPrefix:${snippet.id}') return null;
  return snippet;
}

/// Applies pulled `snippet:` records into [SnippetMirror] under the §3.2
/// tuple guard, as Séance's coordinator applies them: a tombstone removes
/// the snippet (it is non-secret settings, the risk class of a config),
/// and a payload that is not a snippet of its own id trips. Nothing is
/// ever sealed: Séance owns these records, so a store loss re-seals
/// nothing here and a pending record has no source.
final class SnippetMirrorHandler implements RecordHandler {
  SnippetMirrorHandler(this._mirror);

  final SnippetMirror _mirror;

  @override
  String? get prefix => snippetRecordPrefix;

  @override
  ApplyPhase get phase => ApplyPhase.configs;

  @override
  RecordKind get kind => RecordKind.snippet;

  /// The passphrase trial keeps to the records it already opened.
  @override
  bool get trialDecryptable => false;

  @override
  Future<ApplyOutcome> applyLive(
    EncryptedRecord record,
    ApplyContext context,
  ) async {
    final dec = await context.open(record);
    if (dec == null) {
      return context.holdActive ? ApplyOutcome.deferred : ApplyOutcome.skipped;
    }
    final snippet = dec.kind == RecordKind.snippet
        ? _snippetOf(record.id, dec.data)
        : null;
    if (snippet == null) {
      await context.tripwires.trip(record.id);
      return ApplyOutcome.skipped;
    }
    await context.tripwires.clear(record.id);
    return _materialize(record, snippet);
  }

  @override
  Future<ApplyOutcome> applyTombstone(
    EncryptedRecord record,
    ApplyContext context,
  ) => _materialize(record, null);

  @override
  Future<int> reSealAfterStoreLoss(CatalogWriter writer) async => 0;

  @override
  Future<DecryptedRecord?> reSourcePending(EncryptedRecord record) async =>
      null;

  Future<ApplyOutcome> _materialize(
    EncryptedRecord record,
    Snippet? snippet,
  ) async {
    if (!outranksMaterialized(record, _mirror._tupleOf(record.id))) {
      return ApplyOutcome.skipped;
    }
    await _mirror._put(
      record.id,
      SyncTuple(updatedAt: record.updatedAt, deviceId: record.deviceId),
      snippet,
    );
    return ApplyOutcome.applied;
  }
}
