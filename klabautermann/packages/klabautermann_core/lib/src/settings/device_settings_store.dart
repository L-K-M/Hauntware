import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:seance_core/catalog.dart' show syncLocalDirectory;
import 'package:seance_core/seance_core.dart' show uuidV4;

import '../certificates/tls_check.dart' show TlsEndpoint;
import '../docker/docker_ladder.dart' show dockerSocketPathProblem;
import '../engine/protocol.dart'
    show DockerEndpointCustom, DockerEndpointDetected, DockerEndpointSocket;

/// The device settings file under the app's support directory (03 §4.10).
const String deviceSettingsFileName = 'settings.json';

/// The schema this build reads and writes. A file with a higher version
/// came from a newer build and is never rewritten by this one
/// ([DeviceSettingsIssueKind.newerVersion]); the per-server device
/// preferences join the schema under new keys, as the monitor set did.
const int deviceSettingsSchemaVersion = 1;

// The keys sit under the `klabautermann.` prefix like every settings key
// (04 §12.3); the device id's name is fixed there and never changes.
const String _versionKey = 'klabautermann.settings.version';
const String _deviceIdKey = 'klabautermann.sync.deviceId';
const String _appearanceKey = 'klabautermann.appearance';
const String _firstRunCardKey = 'klabautermann.coverage.firstRunCardDismissed';
const String _announceBandsKey =
    'klabautermann.accessibility.announceThresholdBands';
const String _alertNotificationsKey = 'klabautermann.alerts.notifications';
const String _rootEquivalenceNoticeKey =
    'klabautermann.docker.rootEquivalenceNoticeDismissed';
const String _pinnedServersKey = 'klabautermann.fleet.pinnedServerIds';
const String _monitorSetKey = 'klabautermann.monitorSet';
const String _safetyKey = 'klabautermann.safety';
const String _syncSecretsKey = 'klabautermann.sync.secrets';
const String _deviceNameKey = 'klabautermann.audit.deviceName';
const String _appLockKey = 'klabautermann.appLock';

const String _endpointOverridesKey = 'klabautermann.docker.endpointOverrides';
const String _stackFoldersKey = 'klabautermann.docker.stackFolders';
const String _containerColumnsKey = 'klabautermann.docker.containerColumns';
const String _thresholdsKey = 'klabautermann.overview.thresholds';
const String _tlsEndpointsKey = 'klabautermann.certificates.endpoints';
const String _cadenceKey = 'klabautermann.sampling.cadence';
const String _attentionKey = 'klabautermann.attention.acknowledged';

// The fields of one server's entry under [_endpointOverridesKey].
const String _overrideChoiceField = 'choice';
const String _overrideSocketField = 'socketPath';
const String _overrideEndpointField = 'endpoint';
const String _overrideDetected = 'detected';
const String _overrideCustom = 'custom';

/// Replaces a file's contents. [DeviceSettingsStore] writes the settings
/// document and the copy of a damaged file through it.
typedef DeviceSettingsWriter =
    Future<void> Function(File target, List<int> bytes);

/// One server's engine socket chosen on this device (CN-09, D54), with
/// the endpoint it was chosen for, so a server that now names another
/// machine (SYN-08) loses it even when the change happened while the app
/// was not running.
@immutable
final class DockerEndpointOverride {
  const DockerEndpointOverride(this.choice, {required this.endpoint});

  final DockerEndpointSocket choice;

  /// The server's endpoint as the app keys it when the choice was made;
  /// opaque to the store, which only compares it.
  final String endpoint;

  @override
  bool operator ==(Object other) =>
      other is DockerEndpointOverride &&
      other.choice == choice &&
      other.endpoint == endpoint;

  @override
  int get hashCode => Object.hash(choice, endpoint);
}

/// What went wrong with `settings.json` when the store opened.
enum DeviceSettingsIssueKind {
  /// The file was not a settings document this build can read. Its bytes
  /// were copied to [DeviceSettingsIssue.preservedAs] before anything was
  /// written, and the store started from the defaults, keeping the device
  /// id when the damaged text still showed one.
  recovered,

  /// As [recovered], but the defaults could not be written over the
  /// damaged file, which stays in place for the next launch to recover
  /// again (with another copy). Later changes try the write again.
  recoveredNotSaved,

  /// The file exists but could not be read. It is left as it is, and
  /// nothing is saved this session.
  unreadable,

  /// The file was not a settings document, and its copy could not be
  /// written. It is left as it is, and nothing is saved this session.
  unpreserved,

  /// A newer build wrote the file. What this build knows is read from it;
  /// it is left as it is, and nothing is saved this session.
  newerVersion,

  /// The settings could not be written while the store opened (the first
  /// device id). Later changes try again.
  notSaved;

  /// Whether the store refuses every write for the rest of the session.
  bool get readOnly => switch (this) {
    unreadable || unpreserved || newerVersion => true,
    recovered || recoveredNotSaved || notSaved => false,
  };
}

/// The one problem [DeviceSettingsStore.open] met, for the app to report.
@immutable
final class DeviceSettingsIssue {
  const DeviceSettingsIssue(this.kind, {this.preservedAs, this.error});

  final DeviceSettingsIssueKind kind;

  /// Where the damaged file's bytes were kept; set for
  /// [DeviceSettingsIssueKind.recovered] and
  /// [DeviceSettingsIssueKind.recoveredNotSaved] only.
  final String? preservedAs;

  /// The failure behind [kind], for diagnostics: for
  /// [DeviceSettingsIssueKind.recoveredNotSaved], the failed write rather
  /// than the parse error.
  final Object? error;
}

/// A change the store applied in memory but did not save, because this
/// session leaves `settings.json` as it is ([DeviceSettingsIssueKind.readOnly]).
final class DeviceSettingsReadOnlyException implements Exception {
  const DeviceSettingsReadOnlyException(this.kind);

  final DeviceSettingsIssueKind kind;

  @override
  String toString() =>
      'DeviceSettingsReadOnlyException: settings.json is left as it is '
      'this session (${kind.name}), so the change was not saved';
}

/// This device's `settings.json` (03 §4.10): the device id, the appearance,
/// whether the first-run coverage card was dismissed, whether screen
/// readers hear threshold-band changes (D60), whether the Docker tab's
/// root-equivalence notice was dismissed (SAF-08), the servers pinned to
/// the top of the fleet list (03 §10.3), FL-21's monitor set, each
/// server's engine socket chosen on this device (CN-09) and, later,
/// other per-server device preferences.
///
/// The app's isolate owns it: the composition root opens it once and the
/// controllers write through it. The desktop settings window runs no store
/// of its own; its changes reach the app's controllers over the settings
/// link (D32) and are saved here.
///
/// Every write replaces the whole document atomically (a sibling temp file,
/// flushed, renamed over the target, then the directory synced) and writes
/// queue, so the file holds the last change this process made. The store
/// assumes it is the only writer, which the desktops' instance lock
/// provides (see [open]); a phone runs one process per app. A change is
/// applied in memory before it is written and stays applied when the write
/// fails: the call throws, and the next successful write carries it.
///
/// Keys this build does not know are kept and written back, so a newer
/// build's settings survive a write by this one within the same schema
/// version.
final class DeviceSettingsStore {
  DeviceSettingsStore._(this._file, this._writer, this._values, [this._issue]);

  final File _file;
  final DeviceSettingsWriter _writer;

  /// Every key of the document but the version, unknown keys included.
  final Map<String, Object?> _values;
  DeviceSettingsIssue? _issue;
  Future<void> _writeTail = Future<void>.value();

  /// Opens [file], creating it on first launch. Never throws: a file it
  /// cannot use leaves the defaults in place and is reported in [issue].
  ///
  /// A damaged file is copied aside to `settings.json.corrupt-<UTC time>`
  /// (a later damage never overwrites an earlier copy) before anything
  /// replaces it, and its device id is kept when the text still shows one.
  /// When the copy fails, or the file cannot be read at all, the store
  /// leaves the file untouched and refuses writes for the session.
  ///
  /// The device id is minted here, on the first launch, rather than when a
  /// consumer first asks: once persisted it exists before any reader does,
  /// so the catalog library's enrollment and every later reader only ever
  /// read it, and no two readers in this process can race to mint
  /// different ids. An id is only handed out once it is on disk. The store
  /// itself does not guard against a second process: two that opened a
  /// missing file at once would each mint and hand out an id, and the last
  /// rename would win on disk. The composition root opens it only after
  /// taking the `InstanceLock`, so a second desktop instance never gets
  /// here; when the lock cannot be taken at all, the app runs unguarded
  /// and says so.
  ///
  /// [writer] and [now] are seams for tests.
  static Future<DeviceSettingsStore> open(
    File file, {
    DeviceSettingsWriter writer = writeFileAtomically,
    DateTime Function() now = DateTime.now,
  }) async {
    final List<int> raw;
    try {
      raw = await file.readAsBytes();
    } on PathNotFoundException {
      return _openUsable(file, writer, {});
    } on FileSystemException catch (error) {
      return DeviceSettingsStore._(
        file,
        writer,
        {},
        DeviceSettingsIssue(DeviceSettingsIssueKind.unreadable, error: error),
      );
    }

    final Map<String, Object?> document;
    try {
      document = _decode(raw);
    } on FormatException catch (error) {
      return _recover(file, writer, raw, error, now());
    }

    final version = document.remove(_versionKey)! as int;
    if (version > deviceSettingsSchemaVersion) {
      return DeviceSettingsStore._(
        file,
        writer,
        document,
        const DeviceSettingsIssue(DeviceSettingsIssueKind.newerVersion),
      );
    }

    return _openUsable(file, writer, document);
  }

  /// A store over [values] read from a usable file, or none: mints the
  /// device id when there is none and reports a failed save as
  /// [DeviceSettingsIssueKind.notSaved].
  static Future<DeviceSettingsStore> _openUsable(
    File file,
    DeviceSettingsWriter writer,
    Map<String, Object?> values,
  ) async {
    final store = DeviceSettingsStore._(file, writer, values);
    if (await store._persistAtOpen(rewrite: false) case final Object error) {
      store._issue = DeviceSettingsIssue(
        DeviceSettingsIssueKind.notSaved,
        error: error,
      );
    }
    return store;
  }

  /// The problem met while opening, or null when the file was fine.
  DeviceSettingsIssue? get issue => _issue;

  /// This install's sync authorship id, `klabautermann.sync.deviceId`: a
  /// UUID v4 minted once and never regenerated while the file can be read
  /// (03 §4.10; the catalog library's `SyncEnrollmentState.deviceId`
  /// contract). A damaged file whose text shows no id gets a new one; its
  /// old bytes stay in the corrupt copy. Null only when it could not be
  /// read or saved this session; no id is invented then.
  String? get deviceId => _values[_deviceIdKey] as String?;

  /// The appearance as the app stored it: an opaque JSON object the app
  /// encodes and decodes, or null when there is none (or the stored value
  /// is not an object, which reads as none rather than failing the file).
  Map<String, Object?>? get appearance => switch (_values[_appearanceKey]) {
    final Map<String, Object?> json => Map.unmodifiable(json),
    _ => null,
  };

  /// Stores a copy of [appearance] and writes the document. Throws when the
  /// write fails or this session is read-only; the value stays in memory
  /// either way. The copy is deep, through JSON, because the write runs
  /// later from the queue: a caller changing its map afterwards cannot
  /// change what is saved, and a value JSON cannot hold fails here.
  Future<void> setAppearance(Map<String, Object?> appearance) async {
    _values[_appearanceKey] =
        jsonDecode(jsonEncode(appearance)) as Map<String, Object?>;
    await _save();
  }

  /// Whether the user dismissed the first-run coverage card (03 §9.5 item
  /// 1). Anything but `true` reads as not dismissed, so a damaged value
  /// shows the card again rather than failing the file.
  bool get firstRunCardDismissed => _values[_firstRunCardKey] == true;

  /// Records the card's dismissal and writes the document. Throws when the
  /// write fails or this session is read-only; the dismissal stays in
  /// memory either way.
  Future<void> dismissFirstRunCard() async {
    _values[_firstRunCardKey] = true;
    await _save();
  }

  /// Whether screen readers hear a value cross into or out of a warning or
  /// critical band (A11Y-15, D60): on unless the user turned it off, so
  /// anything but `false` reads as on rather than failing the file.
  bool get announceThresholdBands => _values[_announceBandsKey] != false;

  /// Stores [announce] and writes the document. Throws when the write
  /// fails or this session is read-only; the value stays in memory either
  /// way.
  Future<void> setAnnounceThresholdBands(bool announce) async {
    _values[_announceBandsKey] = announce;
    await _save();
  }

  /// Whether raised alerts post a system notification (ALR-01): off until
  /// the user turns it on and the system allows it, so anything but
  /// `true` reads as off and a damaged file posts nothing unasked.
  bool get alertNotifications => _values[_alertNotificationsKey] == true;

  /// Stores [enabled] and writes the document. Throws when the write
  /// fails or this session is read-only; the value stays in memory either
  /// way.
  Future<void> setAlertNotifications(bool enabled) async {
    _values[_alertNotificationsKey] = enabled;
    await _save();
  }

  /// The device's "sync passwords" switch (03 §4.5, SYN-02),
  /// `klabautermann.sync.secrets`: off unless the user turned it on, so
  /// anything but `true` reads as off and a damaged file syncs no
  /// passwords.
  bool get syncSecrets => _values[_syncSecretsKey] == true;

  /// Stores [enabled] and writes the document. Throws when the write
  /// fails or this session is read-only; the value stays in memory either
  /// way.
  Future<void> setSyncSecrets(bool enabled) async {
    _values[_syncSecretsKey] = enabled;
    await _save();
  }

  /// The device's polling budget preset (SAF-19),
  /// `klabautermann.sampling.cadence`, as the name the app stored, or null
  /// when there is none or it is not a string; the app reads a name it
  /// does not know as its default.
  String? get cadence => switch (_values[_cadenceKey]) {
    final String name => name,
    _ => null,
  };

  /// Stores [name] and writes the document. Throws when the write fails
  /// or this session is read-only; the value stays in memory either way.
  Future<void> setCadence(String name) async {
    _values[_cadenceKey] = name;
    await _save();
  }

  /// The device's app lock (SAF-20), `klabautermann.appLock`: off until
  /// the user turns it on. Any other value than `false` that is there
  /// reads as on, so a damaged value can never drop the lock; an absent
  /// one, as on a fresh install, reads as off.
  bool get appLock => switch (_values[_appLockKey]) {
    null || false => false,
    _ => true,
  };

  /// Stores [enabled] and writes the document. Throws when the write
  /// fails or this session is read-only; the value stays in memory either
  /// way.
  Future<void> setAppLock(bool enabled) async {
    _values[_appLockKey] = enabled;
    await _save();
  }

  /// The name the host syslog line gives this device (SAF-13, M5 plan
  /// Q6), `klabautermann.audit.deviceName`; null for the app's default,
  /// as is anything but a non-blank string.
  String? get deviceName => switch (_values[_deviceNameKey]) {
    final String name when name.trim().isNotEmpty => name,
    _ => null,
  };

  /// Stores [name], null removing it, and writes the document. Throws
  /// when the write fails or this session is read-only; the value stays
  /// in memory either way.
  Future<void> setDeviceName(String? name) async {
    if (name == null) {
      _values.remove(_deviceNameKey);
    } else {
      _values[_deviceNameKey] = name;
    }
    await _save();
  }

  /// Whether the user dismissed the Docker tab's root-equivalence notice
  /// (SAF-08, 03 §8.4). As for the coverage card, anything but `true`
  /// reads as not dismissed, so a damaged value shows the notice again.
  bool get rootEquivalenceNoticeDismissed =>
      _values[_rootEquivalenceNoticeKey] == true;

  /// Records the notice's dismissal and writes the document. Throws when
  /// the write fails or this session is read-only; the dismissal stays in
  /// memory either way.
  Future<void> dismissRootEquivalenceNotice() async {
    _values[_rootEquivalenceNoticeKey] = true;
    await _save();
  }

  /// The ids of the servers pinned to the top of this device's fleet list
  /// (03 §10.3). Device-local, as Séance keeps its pins: they are never
  /// synced. A value that is not a list reads as none and items that are
  /// not strings are skipped, rather than failing the file.
  Set<String> get pinnedServerIds => switch (_values[_pinnedServersKey]) {
    final List<Object?> ids => Set.unmodifiable(ids.whereType<String>()),
    _ => const {},
  };

  /// Stores [ids], sorted so the document does not churn with pin order,
  /// and writes the document. Throws when the write fails or this session
  /// is read-only; the value stays in memory either way.
  Future<void> setPinnedServerIds(Set<String> ids) async {
    _values[_pinnedServersKey] = ids.toList()..sort();
    await _save();
  }

  /// The ids of FL-21's monitor set as the user chose it on this device
  /// (03 §4.3 step 4), or null when the user never chose one and the
  /// platform's default applies. Device-local: never synced (03 §4.9). A
  /// value that is not a list reads as never chosen and items that are
  /// not strings are skipped, rather than failing the file; the app drops
  /// ids that are no longer eligible when it next saves.
  Set<String>? get monitorSet => switch (_values[_monitorSetKey]) {
    final List<Object?> ids => Set.unmodifiable(ids.whereType<String>()),
    _ => null,
  };

  /// Stores [ids] as the user's monitor set, sorted so the document does
  /// not churn with toggle order, and writes the document. Throws when
  /// the write fails or this session is read-only; the value stays in
  /// memory either way.
  Future<void> setMonitorSet(Set<String> ids) async {
    _values[_monitorSetKey] = ids.toList()..sort();
    await _save();
  }

  /// The Containers tab's columns as the user chose them (CTR-08),
  /// `klabautermann.docker.containerColumns`: the shown ones by name, in
  /// order, which the app reads against its own column set. Null when
  /// there is no list, or the value is not one, which the app reads as
  /// its default columns rather than failing the file.
  List<String>? get containerColumns => switch (_values[_containerColumnsKey]) {
    final List<Object?> names => List.unmodifiable(names.whereType<String>()),
    _ => null,
  };

  /// Stores [names] as the shown columns, in order, and writes the
  /// document. Throws when the write fails or this session is read-only;
  /// the value stays in memory either way.
  Future<void> setContainerColumns(List<String> names) async {
    _values[_containerColumnsKey] = [...names];
    await _save();
  }

  /// OV-11's threshold levels by metric name,
  /// `klabautermann.overview.thresholds`: each its careful, warning and
  /// critical percent, which the app reads against its own metrics. An
  /// entry that is not three numbers is skipped, as is a value that is
  /// not an object, rather than failing the file.
  Map<String, List<double>> get thresholds => switch (_values[_thresholdsKey]) {
    final Map<String, Object?> byMetric => {
      for (final MapEntry(:key, :value) in byMetric.entries)
        if (value case [
          final num careful,
          final num warning,
          final num critical,
        ])
          key: List.unmodifiable([
            careful.toDouble(),
            warning.toDouble(),
            critical.toDouble(),
          ]),
    },
    _ => const {},
  };

  /// Stores [levels] as the threshold levels, replacing every metric's,
  /// and writes the document. Throws when the write fails or this
  /// session is read-only; the value stays in memory either way.
  Future<void> setThresholds(Map<String, List<double>> levels) async {
    _values[_thresholdsKey] = {
      for (final MapEntry(:key, :value) in levels.entries) key: [...value],
    };
    await _save();
  }

  /// The engine socket chosen for each server on this device (CN-09,
  /// D54), by server id: `klabautermann.docker.endpointOverrides`. A
  /// server without an entry finds its socket itself. Entries read
  /// leniently: one that is not an object, names no known choice, holds
  /// a path [dockerSocketPathProblem] refuses or no endpoint is skipped,
  /// as is a value that is not an object, rather than failing the file.
  Map<String, DockerEndpointOverride> get dockerEndpointOverrides => {
    for (final MapEntry(:key, :value) in _rawEndpointOverrides.entries)
      if (_readOverride(value) case final override?) key: override,
  };

  /// Stores [override] as [serverId]'s choice, or removes it when null
  /// (the engine finds the socket itself), and writes the document. The
  /// other servers' entries stay as they were read, a newer build's
  /// included. Throws when the write fails or this session is
  /// read-only; the value stays in memory either way.
  Future<void> setDockerEndpointOverride(
    String serverId,
    DockerEndpointOverride? override,
  ) async {
    final entries = _rawEndpointOverrides;
    if (override == null) {
      entries.remove(serverId);
    } else {
      entries[serverId] = {
        _overrideChoiceField: switch (override.choice) {
          DockerEndpointDetected() => _overrideDetected,
          DockerEndpointCustom() => _overrideCustom,
        },
        _overrideSocketField: override.choice.socketPath,
        _overrideEndpointField: override.endpoint,
      };
    }
    _values[_endpointOverridesKey] = entries;
    await _save();
  }

  /// Drops the choice of every server [endpoints] does not list, or whose
  /// stored endpoint differs from the one it lists (SYN-08): the fleet
  /// lost the server, or its id now names another machine. [endpoints]
  /// is the whole fleet, keyed as [DockerEndpointOverride.endpoint] is.
  /// Returns the server ids dropped, and writes the document only when
  /// there are any; throws as [setDockerEndpointOverride] does.
  Future<Set<String>> purgeDockerEndpointOverrides(
    Map<String, String> endpoints,
  ) async {
    final entries = _rawEndpointOverrides;
    final dropped = {
      for (final MapEntry(:key, :value) in entries.entries)
        if (endpoints[key] == null ||
            switch (value) {
              {_overrideEndpointField: final String endpoint} =>
                endpoint != endpoints[key],
              _ => true,
            })
          key,
    };
    if (dropped.isEmpty) return dropped;

    entries.removeWhere((serverId, _) => dropped.contains(serverId));
    _values[_endpointOverridesKey] = entries;
    await _save();
    return dropped;
  }

  /// A copy of the stored entries, each as read; none when the value is
  /// not an object.
  Map<String, Object?> get _rawEndpointOverrides =>
      switch (_values[_endpointOverridesKey]) {
        final Map<String, Object?> entries => {...entries},
        _ => {},
      };

  static DockerEndpointOverride? _readOverride(Object? value) {
    if (value case {
      _overrideChoiceField: final String choice,
      _overrideSocketField: final String path,
      _overrideEndpointField: final String endpoint,
    } when dockerSocketPathProblem(path) == null) {
      final socket = switch (choice) {
        _overrideDetected => DockerEndpointDetected(path),
        _overrideCustom => DockerEndpointCustom(path),
        _ => null,
      };
      if (socket == null) return null;
      return DockerEndpointOverride(socket, endpoint: endpoint);
    }
    return null;
  }

  /// The folders STK-08's scan searches on each server, by server id:
  /// `klabautermann.docker.stackFolders`. Device-local until the `pref`
  /// record carries them (M5 plan M05). Read leniently: a value that is
  /// not an object, an entry that is not a list and items that are not
  /// absolute paths are skipped, rather than failing the file.
  Map<String, List<String>> get stackFolders => {
    for (final MapEntry(:key, :value) in _rawStackFolders.entries)
      if (value case final List<Object?> folders)
        if ([
              for (final folder in folders)
                if (folder case final String path when path.startsWith('/'))
                  path,
            ]
            case final paths when paths.isNotEmpty)
          key: List.unmodifiable(paths),
  };

  /// Stores [folders] as [serverId]'s, or removes its entry when empty,
  /// and writes the document. The other servers' entries stay as they
  /// were read. Throws when the write fails or this session is
  /// read-only; the value stays in memory either way.
  Future<void> setStackFolders(String serverId, List<String> folders) async {
    final entries = _rawStackFolders;
    if (folders.isEmpty) {
      entries.remove(serverId);
    } else {
      entries[serverId] = [...folders];
    }
    _values[_stackFoldersKey] = entries;
    await _save();
  }

  Map<String, Object?> get _rawStackFolders =>
      switch (_values[_stackFoldersKey]) {
        final Map<String, Object?> entries => {...entries},
        _ => {},
      };

  /// The endpoints CRT-01 checks for each server, by server id, as
  /// `host:port` labels: `klabautermann.certificates.endpoints`.
  /// Device-local, since the check runs from this device. Read leniently,
  /// as [stackFolders]: an entry that is not a list and items that are
  /// not endpoints are skipped, rather than failing the file.
  Map<String, List<TlsEndpoint>> get tlsEndpoints => {
    for (final MapEntry(:key, :value) in _rawTlsEndpoints.entries)
      if (value case final List<Object?> labels)
        if ([
              for (final label in labels)
                if (label case final String text)
                  if (TlsEndpoint.parse(text) case final endpoint?) endpoint,
            ]
            case final endpoints when endpoints.isNotEmpty)
          key: List.unmodifiable(endpoints),
  };

  /// Stores [endpoints] as [serverId]'s, or removes its entry when empty,
  /// and writes the document, as [setStackFolders] does.
  Future<void> setTlsEndpoints(
    String serverId,
    List<TlsEndpoint> endpoints,
  ) async {
    final entries = _rawTlsEndpoints;
    if (endpoints.isEmpty) {
      entries.remove(serverId);
    } else {
      entries[serverId] = [for (final endpoint in endpoints) endpoint.label];
    }
    _values[_tlsEndpointsKey] = entries;
    await _save();
  }

  Map<String, Object?> get _rawTlsEndpoints =>
      switch (_values[_tlsEndpointsKey]) {
        final Map<String, Object?> entries => {...entries},
        _ => {},
      };

  /// The safety preferences as the app stored them (M4 plan M4): an
  /// opaque JSON object the app encodes and decodes, or null when there
  /// is none (or the stored value is not an object, which reads as none,
  /// every server observe-only, rather than failing the file).
  Map<String, Object?>? get safety => switch (_values[_safetyKey]) {
    final Map<String, Object?> json => Map.unmodifiable(json),
    _ => null,
  };

  /// Stores a deep copy of [safety] and writes the document, as
  /// [setAppearance] does. Throws when the write fails or this session is
  /// read-only; the value stays in memory either way.
  Future<void> setSafety(Map<String, Object?> safety) async {
    _values[_safetyKey] =
        jsonDecode(jsonEncode(safety)) as Map<String, Object?>;
    await _save();
  }

  /// TRI-03's acknowledged problems as the app stored them: an opaque
  /// JSON object the app encodes and decodes, or null when there is none
  /// (or the stored value is not an object, which reads as none, every
  /// problem unacknowledged, rather than failing the file). Device-local
  /// (02 TRI-03).
  Map<String, Object?>? get attention => switch (_values[_attentionKey]) {
    final Map<String, Object?> json => Map.unmodifiable(json),
    _ => null,
  };

  /// Stores a deep copy of [attention] and writes the document, as
  /// [setSafety] does.
  Future<void> setAttention(Map<String, Object?> attention) async {
    _values[_attentionKey] =
        jsonDecode(jsonEncode(attention)) as Map<String, Object?>;
    await _save();
  }

  /// Mints the device id when there is none and writes the document when
  /// it changed or [rewrite] asks for it. Returns the write's failure, or
  /// null when it saved or had nothing to save; the caller reports it. A
  /// failure keeps the store usable: a minted id is dropped again, since it
  /// never reached the disk.
  Future<Object?> _persistAtOpen({required bool rewrite}) async {
    final mint = deviceId == null;
    if (!mint && !rewrite) return null;

    if (mint) _values[_deviceIdKey] = uuidV4();
    try {
      await _save();
      return null;
    } on Object catch (error) {
      if (mint) _values.remove(_deviceIdKey);
      return error;
    }
  }

  /// Queues a write of the whole document as it is when the write starts,
  /// so overlapping saves land in order and the last one wins.
  Future<void> _save() {
    if (_issue case DeviceSettingsIssue(:final kind) when kind.readOnly) {
      return Future.error(DeviceSettingsReadOnlyException(kind));
    }

    final write = _writeTail.then(
      (_) => _writer(
        _file,
        utf8.encode(
          jsonEncode({_versionKey: deviceSettingsSchemaVersion, ..._values}),
        ),
      ),
    );
    // Each caller gets its own write's failure; the queue itself moves on.
    _writeTail = write.then<void>((_) {}, onError: (Object _) {});
    return write;
  }

  /// The settings document in [raw], or a [FormatException] when it is not
  /// one: not UTF-8 JSON, not an object, no usable version, or a device id
  /// that is not a non-empty string. The device id and version are checked
  /// strictly because a wrong guess at either costs the install its
  /// identity; the appearance is read leniently by its getter instead.
  static Map<String, Object?> _decode(List<int> raw) {
    final decoded = jsonDecode(utf8.decode(raw));
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('settings.json is not a JSON object');
    }

    final version = decoded[_versionKey];
    if (version is! int || version < 1) {
      throw const FormatException('settings.json has no usable version');
    }

    final deviceId = decoded[_deviceIdKey];
    if (deviceId != null && (deviceId is! String || deviceId.isEmpty)) {
      throw const FormatException('settings.json has an unusable device id');
    }

    return decoded;
  }

  /// Séance's settings recovery (keep the device id the damaged text still
  /// shows, write the defaults back at once so the next launch does not
  /// mint a new one), with Poltergeist's time-stamped copy name, and one
  /// change of order: the damaged bytes are copied aside before anything
  /// is written, and the original is never moved. A failed write-back
  /// therefore leaves the damaged file in place for the next launch to
  /// recover again, device id included, instead of an empty directory.
  static Future<DeviceSettingsStore> _recover(
    File file,
    DeviceSettingsWriter writer,
    List<int> raw,
    FormatException error,
    DateTime time,
  ) async {
    final salvaged = _salvageDeviceId(raw);
    final values = <String, Object?>{_deviceIdKey: ?salvaged};

    final String preservedAs;
    try {
      preservedAs = await unusedCorruptCopyPath(file, time);
      await writer(File(preservedAs), raw);
    } on Object catch (copyError) {
      return DeviceSettingsStore._(
        file,
        writer,
        values,
        DeviceSettingsIssue(
          DeviceSettingsIssueKind.unpreserved,
          error: copyError,
        ),
      );
    }

    final store = DeviceSettingsStore._(file, writer, values);
    final writeError = await store._persistAtOpen(rewrite: true);
    store._issue = writeError == null
        ? DeviceSettingsIssue(
            DeviceSettingsIssueKind.recovered,
            preservedAs: preservedAs,
            error: error,
          )
        : DeviceSettingsIssue(
            DeviceSettingsIssueKind.recoveredNotSaved,
            preservedAs: preservedAs,
            error: writeError,
          );
    return store;
  }

  /// The device id from text that did not parse, when it still shows one
  /// where a key can sit (Séance's `salvageSettings` rule). The value goes
  /// through JSON string decoding so escapes survive.
  static String? _salvageDeviceId(List<int> raw) {
    final text = utf8.decode(raw, allowMalformed: true);
    final match = RegExp(
      '(?:^|[,{])\\s*"${RegExp.escape(_deviceIdKey)}"\\s*:\\s*'
      '"((?:[^"\\\\]|\\\\.)*)"',
    ).firstMatch(text);
    final escaped = match?.group(1);
    if (escaped == null) return null;

    try {
      final value = jsonDecode('"$escaped"') as String;
      return value.isEmpty ? null : value;
    } on FormatException {
      return null;
    }
  }
}

/// `<file>.corrupt-<UTC time>` (`settings.json.corrupt-20261013T230529Z`),
/// with a counter when that name is taken, so a damaged file kept aside
/// never replaces an earlier one. The settings store copies its damaged
/// file there and the engine's import store renames its own. Internal:
/// the barrel hides it.
Future<String> unusedCorruptCopyPath(File file, DateTime time) async {
  final stamp = time
      .toUtc()
      .toIso8601String()
      .replaceAll('-', '')
      .replaceAll(':', '')
      .replaceAll('.', '');
  final base = '${file.path}.corrupt-$stamp';
  var candidate = base;
  for (var counter = 2; ; counter++) {
    final type = await FileSystemEntity.type(candidate, followLinks: false);
    if (type == FileSystemEntityType.notFound) return candidate;
    candidate = '$base-$counter';
  }
}

/// The store's default [DeviceSettingsWriter], and the writer for the
/// other device-local files: the app's `window_state.json` and the
/// engine's import store. It follows the catalog stores' write order
/// (`AtomicFileWriter` in `seance_core`, which its barrel does not
/// export). A sibling temp file with a random name is written and
/// flushed, renamed over [target], and the directory synced through
/// `seance_core`'s [syncLocalDirectory] so the rename survives power loss.
/// A reader, or a crash, sees the old file or the new one, never a partial
/// one. A failure deletes the temp file and rethrows. Concurrent writes to
/// one target are the caller's to order: each lands whole, and the last
/// rename wins.
Future<void> writeFileAtomically(File target, List<int> bytes) async {
  await target.parent.create(recursive: true);
  final temporary = File('${target.path}.tmp-${uuidV4()}');
  try {
    final handle = await temporary.open(mode: FileMode.writeOnly);
    try {
      await handle.writeFrom(bytes);
      await handle.flush();
    } finally {
      await handle.close();
    }
    await temporary.rename(target.path);
    await syncLocalDirectory(target.parent);
  } on Object {
    try {
      if (await temporary.exists()) await temporary.delete();
    } on Object {
      // The write's own failure is the one to report.
    }
    rethrow;
  }
}
