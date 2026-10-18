import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../services/ssh_config_source.dart';
import 'monitor_set.dart';

/// One fleet entry as the rail renders it: the engine's [FleetEntry]
/// reduced to what a row shows (03 §10.3).
final class FleetServer {
  const FleetServer({
    required this.id,
    required this.displayName,
    this.origin = FleetEntryOrigin.synced,
    this.group,
    this.address,
    this.searchText,
    this.locatorConflict,
    this.monitorEligibility = MonitorEligibility.eligible,
  });

  /// The row for [entry]; its address leaves out the default port.
  factory FleetServer.fromEntry(FleetEntry entry) {
    return FleetServer(
      id: entry.serverId,
      displayName: entry.label,
      origin: entry.origin,
      group: entry.group,
      address: _address(entry),
      searchText: entry.searchText,
      locatorConflict: entry.locatorConflict,
      monitorEligibility: monitorEligibilityOf(entry),
    );
  }

  /// The catalog/server id every engine request uses.
  final String id;

  final String displayName;

  /// Where the entry came from: the rail sections synced servers by their
  /// groups and pins, and lists imports in a section of their own.
  final FleetEntryOrigin origin;

  /// The synced record's group as the user spelled it, or null; see
  /// [FleetEntry.group].
  final String? group;

  /// Host or `user@host` for the row's subtitle (03 §10.3), with `:port`
  /// when the port is not 22.
  final String? address;

  /// What the rail's filter matches (FL-05); see [FleetEntry.searchText].
  final String? searchText;

  /// The ids of the servers whose host-key pins would collide with this
  /// one's (03 §4.6); see [FleetEntry.locatorConflict].
  final List<String>? locatorConflict;

  /// Whether the server may join FL-21's monitor set, by the engine's
  /// rule ([monitorEligibilityOf]).
  final MonitorEligibility monitorEligibility;

  static String _address(FleetEntry entry) {
    final login = entry.user == null ? '' : '${entry.user}@';
    if (entry.port == kSshDefaultPort) return '$login${entry.host}';

    // An IPv6 literal is bracketed so the port suffix stays unambiguous.
    final host = entry.host.contains(':') ? '[${entry.host}]' : entry.host;
    return '$login$host:${entry.port}';
  }
}

/// How one FL-02 import ended, for the surface that started it.
@immutable
sealed class SshConfigImportOutcome {
  const SshConfigImportOutcome();
}

/// The engine imported the config; the fleet already lists the entries.
final class SshConfigImportSucceeded extends SshConfigImportOutcome {
  const SshConfigImportSucceeded({
    required this.importedCount,
    required this.skippedCount,
    required this.saved,
  });

  /// See [SshConfigImported.importedCount].
  final int importedCount;

  /// See [SshConfigImported.skippedCount].
  final int skippedCount;

  /// See [SshConfigImported.saved]: false means this import is not kept
  /// after a restart.
  final bool saved;
}

/// The app could not read the config, so nothing reached the engine.
final class SshConfigImportUnreadable extends SshConfigImportOutcome {
  const SshConfigImportUnreadable(this.failure);

  final SshConfigReadFailure failure;
}

/// The engine refused the import or stopped before answering. [reason] is
/// a diagnostic for developers; surfaces show their own localized text.
final class SshConfigImportRejected extends SshConfigImportOutcome {
  const SshConfigImportRejected(this.reason);

  final String reason;
}

/// How one [FleetController.confirmEndpoints] ended.
enum EndpointConfirmResult {
  /// Every server asked for is confirmed, or left the fleet meanwhile.
  confirmed,

  /// Some are still waiting: a jump host they connect through changed
  /// and needs its own confirmation (D64).
  stillPending,

  /// The engine could not save a pin, or stopped before it answered;
  /// those servers stay unconfirmed.
  failed,
}

/// The fleet concern (03 §10.1): the server list from [CatalogReplaced]
/// snapshots, per-server link statuses from [LinkState] and probe results
/// from [Reachability] events, the workspace's selection, the servers
/// pinned to the top of the list (03 §10.3), FL-21's monitor set (03
/// §4.3 step 4), the desktop ssh_config import (FL-02) and the synced
/// servers' endpoint confirmation (03 §4.3 step 3, §4.7).
/// Pull-only by construction (D14): the requests it sends,
/// [ImportSshConfig], [ConfirmEndpoints] and [SetMonitorSet], change the
/// engine's device-local files and state and never a catalog record, and
/// pins and the monitor set stay on this device.
final class FleetController extends ChangeNotifier {
  /// [servers] seeds the list until the engine's first [CatalogReplaced].
  /// [sshConfig] is null on platforms without an ssh_config, which hides
  /// the import (see [sshConfigSourceFor]). [pinnedServerIds] are the pins
  /// `settings.json` restored, and `savePins` writes the set back; without
  /// it, as in most tests, pins are held in memory only. [monitorSet] is
  /// the monitor set `settings.json` restored, null while the user has
  /// chosen none and [monitorSetDefault] applies, and `saveMonitorSet`
  /// writes a choice back; without it, the choice is held in memory only.
  FleetController(
    this._engine, {
    List<FleetServer> servers = const [],
    this._sshConfig,
    Set<String> pinnedServerIds = const {},
    this._savePins,
    Set<String>? monitorSet,
    this._monitorSetDefault = MonitorSetDefault.none,
    this._saveMonitorSet,
  }) : _servers = List.unmodifiable(servers),
       _serverIds = {for (final server in servers) server.id},
       _pinnedServerIds = Set.unmodifiable(pinnedServerIds),
       _chosenMonitorSet = monitorSet == null
           ? null
           : Set.unmodifiable(monitorSet) {
    _applyMonitorSet();
    _events = _engine.events.listen(_onEngineEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  final SshConfigSource? _sshConfig;
  late final StreamSubscription<EngineEvent> _events;

  List<FleetServer> _servers;

  /// The synced servers whose endpoints wait for confirmation.
  List<FleetEntry> _pendingEndpoints = const [];

  /// The ids [_servers] lists: the only servers statuses are kept for.
  Set<String> _serverIds;

  /// Kept for servers the fleet does not list too, so a pinned server that
  /// a sync drops and brings back returns pinned, as in Séance.
  Set<String> _pinnedServerIds;
  final Future<void> Function(Set<String> ids)? _savePins;

  /// The monitor set the user chose on this device, which may still name
  /// servers that left the fleet or stopped being eligible until the next
  /// choice saves it; null while the default applies.
  Set<String>? _chosenMonitorSet;
  final MonitorSetDefault _monitorSetDefault;
  final Future<void> Function(Set<String> ids)? _saveMonitorSet;

  /// The monitor set in force, and the one the engine was last sent: the
  /// engine starts with none, and hears a set only once it sent a fleet,
  /// so eligibility is the engine's own.
  Set<String> _monitored = const {};
  Set<String> _sentMonitorSet = const {};
  bool _heardFleet = false;
  late final _MonitorCandidates _monitorCandidates = _MonitorCandidates(
    setMonitored,
  );

  final Map<String, LinkStatus> _linkStatuses = {};
  final Map<String, ReachabilityStatus> _reachability = {};
  String? _selectedServerId;

  /// The running import, from reading the file to the engine's answer.
  Future<SshConfigImportOutcome>? _import;

  /// Completed by the engine's answer to the [ImportSshConfig] in flight.
  /// The engine answers requests in order and [_import] allows one at a
  /// time, so the next answer always belongs to this completer.
  Completer<SshConfigImportOutcome>? _importAnswer;

  /// The servers the [ConfirmEndpoints] in flight names, and its answer.
  /// The dialog sends one at a time.
  Set<String> _confirming = const {};
  Completer<EndpointConfirmResult>? _confirmAnswer;

  bool _engineStopped = false;
  bool _disposed = false;

  List<FleetServer> get servers => _servers;

  /// The synced servers this device has not confirmed, or whose endpoint
  /// changed since (03 §4.7), in fleet order: the confirmation list.
  /// The engine dials none of them. Imports never appear: they count as
  /// confirmed on the device that imported them.
  List<FleetEntry> get pendingEndpoints => _pendingEndpoints;

  /// The workspace's server, or null for its empty state.
  String? get selectedServerId => _selectedServerId;

  FleetServer? get selectedServer {
    for (final server in _servers) {
      if (server.id == _selectedServerId) return server;
    }
    return null;
  }

  /// The last link status the engine reported for [serverId]; a server
  /// with none, listed or not, reads as [LinkIdle].
  LinkStatus linkStatusFor(String serverId) =>
      _linkStatuses[serverId] ?? const LinkIdle();

  /// The last probe answer for [serverId], or null when it has none (the
  /// engine probes only confirmed endpoints, 03 §5.12).
  ReachabilityStatus? reachabilityFor(String serverId) =>
      _reachability[serverId];

  /// Whether this device offers the ssh_config import: desktops do, phones
  /// have no ssh_config (FL-02).
  bool get canImportSshConfig => _sshConfig != null;

  /// Whether an import is running; surfaces disable their entry meanwhile.
  bool get isImportingSshConfig => _import != null;

  /// The ids pinned to the top of the list on this device (03 §10.3).
  /// The list pins synced servers only; see [FleetServer.origin].
  Set<String> get pinnedServerIds => _pinnedServerIds;

  /// Pins [serverId] to the top of the list; see [_setPins].
  Future<void> pin(String serverId) =>
      _setPins({..._pinnedServerIds, serverId});

  /// Takes [serverId] off the pinned shortlist; see [_setPins].
  Future<void> unpin(String serverId) =>
      _setPins({..._pinnedServerIds}..remove(serverId));

  /// Applies [ids] at once and saves them. A save that fails rethrows and
  /// the change stays until the app quits, so the caller can say it was
  /// not kept. Nothing is saved when [ids] changes nothing.
  Future<void> _setPins(Set<String> ids) async {
    if (setEquals(ids, _pinnedServerIds)) return;
    _pinnedServerIds = Set.unmodifiable(ids);
    notifyListeners();
    await _savePins?.call(_pinnedServerIds);
  }

  /// The servers FL-21's monitor set holds (03 §4.3 step 4): sampled for
  /// their rows while the app is in the foreground, whether or not a view
  /// shows them. Eligible fleet servers only, at most [kMonitorSetLimit].
  Set<String> get monitoredServerIds => _monitored;

  /// The monitor set as Settings > Servers shows and changes it. It
  /// notifies only when its list changes, not with every link status.
  MonitorSetSettings get monitorSettings => _monitorCandidates;

  /// Adds [serverId] to the monitor set or takes it out, at once, and
  /// saves the choice, which drops the servers that left the fleet or
  /// stopped being eligible. See [MonitorSetSettings.setMonitored] for
  /// what it throws; a server that is not an eligible fleet server throws
  /// [ArgumentError].
  Future<void> setMonitored(String serverId, {required bool monitored}) async {
    final inForce = _monitored;
    if (inForce.contains(serverId) == monitored) return;

    if (monitored) {
      final eligible = _servers.any(
        (server) =>
            server.id == serverId &&
            server.monitorEligibility == MonitorEligibility.eligible,
      );
      if (!eligible) {
        throw ArgumentError.value(serverId, 'serverId', 'not eligible');
      }
      if (inForce.length >= kMonitorSetLimit) {
        throw const MonitorSetFullException();
      }
    }

    final chosen = _chosenMonitorSet = Set.unmodifiable(
      monitored ? {...inForce, serverId} : ({...inForce}..remove(serverId)),
    );
    _applyMonitorSet();
    notifyListeners();
    try {
      await _saveMonitorSet?.call(chosen);
    } on Exception catch (error, stackTrace) {
      Error.throwWithStackTrace(
        MonitorSetNotSavedException('The monitor set was not saved: $error'),
        stackTrace,
      );
    }
  }

  /// Works out the monitor set in force from the fleet and the choice,
  /// refreshes [monitorSettings], and tells the engine when the set
  /// changed since it last heard one.
  void _applyMonitorSet() {
    final inForce = _monitored = monitorSetInForce(
      eligible: [
        for (final server in _servers)
          if (server.monitorEligibility == MonitorEligibility.eligible)
            server.id,
      ],
      chosen: _chosenMonitorSet,
      fallback: _monitorSetDefault,
    );
    final candidates = List<MonitorCandidate>.unmodifiable([
      for (final server in _servers)
        MonitorCandidate(
          serverId: server.id,
          label: server.displayName,
          eligibility: server.monitorEligibility,
          monitored: inForce.contains(server.id),
        ),
    ]);
    if (!listEquals(candidates, _monitorCandidates.value)) {
      _monitorCandidates.value = candidates;
    }

    if (!_heardFleet || _engineStopped || _disposed) return;
    if (setEquals(inForce, _sentMonitorSet)) return;
    _sentMonitorSet = inForce;
    try {
      _engine.send(SetMonitorSet(inForce.toList()));
    } on StateError {
      // The engine stopped; its done event follows.
    }
  }

  void select(String? serverId) {
    if (serverId == _selectedServerId) return;
    _selectedServerId = serverId;
    notifyListeners();
  }

  /// Reads the ssh_config through the app's source and has the engine
  /// import its hosts (FL-02). Completes once the engine has answered, when
  /// [servers] already shows the result; a call while one runs joins it.
  ///
  /// Throws [StateError] when [canImportSshConfig] is false.
  Future<SshConfigImportOutcome> importSshConfig() {
    final source = _sshConfig;
    if (source == null) {
      throw StateError('this platform has no ssh_config to import');
    }
    final running = _import;
    if (running != null) return running;

    final started = _import = _runImport(source);
    notifyListeners();
    return started;
  }

  Future<SshConfigImportOutcome> _runImport(SshConfigSource source) async {
    try {
      final read = await source.read();
      final String text;
      switch (read) {
        case SshConfigUnavailable(:final failure):
          return SshConfigImportUnreadable(failure);
        case SshConfigText():
          text = read.text;
      }

      if (_disposed || _engineStopped) {
        return const SshConfigImportRejected('the engine is not running');
      }
      final answer = _importAnswer = Completer<SshConfigImportOutcome>();
      try {
        _engine.send(ImportSshConfig(text));
      } on StateError catch (error) {
        return SshConfigImportRejected(error.message);
      }
      return await answer.future;
    } finally {
      _import = null;
      _importAnswer = null;
      if (!_disposed) notifyListeners();
    }
  }

  /// Confirms the endpoints of [serverIds] as listed (03 §4.3 step 3,
  /// SAF-09) and completes once the engine answered. A call while one
  /// runs joins it.
  Future<EndpointConfirmResult> confirmEndpoints(Iterable<String> serverIds) {
    if (_confirmAnswer case final running?) return running.future;
    if (_disposed || _engineStopped) {
      return Future.value(EndpointConfirmResult.failed);
    }

    final ids = serverIds.toList();
    try {
      _engine.send(ConfirmEndpoints(ids));
    } on StateError {
      return Future.value(EndpointConfirmResult.failed);
    }
    _confirming = ids.toSet();
    return (_confirmAnswer = Completer()).future;
  }

  /// Ends the confirmation in flight with [result]. The engine answers
  /// with the fleet, after a rejection when a pin was not saved; a sync
  /// round's fleet arriving first answers it as well, which only shows
  /// pins the engine already saved.
  void _completeConfirm(EndpointConfirmResult result) {
    final answer = _confirmAnswer;
    if (answer == null) return;
    _confirmAnswer = null;
    _confirming = const {};
    answer.complete(result);
  }

  void _completeImport(SshConfigImportOutcome outcome) {
    final answer = _importAnswer;
    if (answer == null || answer.isCompleted) return;
    answer.complete(outcome);
  }

  void _onEngineEvent(EngineEvent event) {
    switch (event) {
      case LinkState(:final serverId, :final status):
        _keep(_linkStatuses, serverId, status);
      case Reachability(:final serverId, :final status):
        _keep(_reachability, serverId, status);
      case CatalogReplaced(:final entries):
        _heardFleet = true;
        _replaceFleet(entries);
        // Any fleet settles a confirm in flight, including one a sync
        // round or an import sent ahead of this confirm's answer: it can
        // only miss the pins just saved, so a wrong verdict is at worst
        // the conservative stillPending, never a false confirmed.
        final pending = {for (final entry in _pendingEndpoints) entry.serverId};
        _completeConfirm(
          _confirming.any(pending.contains)
              ? EndpointConfirmResult.stillPending
              : EndpointConfirmResult.confirmed,
        );
      case SshConfigImported(
        :final importedCount,
        :final skippedCount,
        :final saved,
      ):
        _completeImport(
          SshConfigImportSucceeded(
            importedCount: importedCount,
            skippedCount: skippedCount,
            saved: saved,
          ),
        );
      case RequestRejected(:final requestName, :final reason)
          when requestName == '$ImportSshConfig':
        _completeImport(SshConfigImportRejected(reason));
      case RequestRejected(:final requestName)
          when requestName == '$ConfirmEndpoints':
        _completeConfirm(EndpointConfirmResult.failed);
      // The engine saw another fleet than the one the set came from; the
      // fleet it sends next brings the set in step.
      case RequestRejected(:final requestName, :final reason)
          when requestName == '$SetMonitorSet':
        debugPrint('$requestName: $reason');
      // The fleet after an EndpointChanged lists the server as pending;
      // everything else belongs to other concerns.
      case EngineEvent():
        break;
    }
  }

  void _replaceFleet(List<FleetEntry> entries) {
    _servers = List.unmodifiable(entries.map(FleetServer.fromEntry));
    _pendingEndpoints = List.unmodifiable(
      entries.where(
        (entry) =>
            entry.endpoint != null &&
            entry.endpoint != EndpointConfirmation.confirmed,
      ),
    );
    // A selection the new fleet no longer lists would leave the workspace
    // titled after a server that is gone.
    if (_selectedServerId != null &&
        !_servers.any((server) => server.id == _selectedServerId)) {
      _selectedServerId = null;
    }
    // A status kept for a dropped server would resurface if its id came
    // back in a later fleet, and the maps would grow with every churn.
    final ids = _serverIds = {for (final server in _servers) server.id};
    _linkStatuses.removeWhere((serverId, _) => !ids.contains(serverId));
    // A server waiting for confirmation is not probed (03 §5.12), so an
    // answer kept from before a sync changed its endpoint would describe
    // the old one.
    final pending = {for (final entry in _pendingEndpoints) entry.serverId};
    _reachability.removeWhere(
      (serverId, _) => !ids.contains(serverId) || pending.contains(serverId),
    );
    _applyMonitorSet();
    notifyListeners();
  }

  /// Records [value] as [serverId]'s latest in [values], notifying only on
  /// a change. A server the fleet does not list is ignored: its value
  /// would otherwise wait in the map and surface if a later fleet listed
  /// that id.
  void _keep<T>(Map<String, T> values, String serverId, T value) {
    if (!_serverIds.contains(serverId)) return;
    if (values[serverId] == value) return;
    values[serverId] = value;
    notifyListeners();
  }

  void _onEngineDone() {
    _engineStopped = true;
    _completeImport(const SshConfigImportRejected('the engine stopped'));
    _completeConfirm(EndpointConfirmResult.failed);
  }

  @override
  void dispose() {
    _disposed = true;
    _completeImport(
      const SshConfigImportRejected('the fleet controller was disposed'),
    );
    _completeConfirm(EndpointConfirmResult.failed);
    unawaited(_events.cancel());
    _monitorCandidates.dispose();
    super.dispose();
  }
}

/// [FleetController.monitorSettings]: the candidates as a listenable of
/// their own, so the settings window hears the monitor set change and not
/// every link status.
final class _MonitorCandidates extends ValueNotifier<List<MonitorCandidate>>
    implements MonitorSetSettings {
  _MonitorCandidates(this._setMonitored) : super(const []);

  final Future<void> Function(String serverId, {required bool monitored})
  _setMonitored;

  @override
  Future<void> setMonitored(String serverId, {required bool monitored}) =>
      _setMonitored(serverId, monitored: monitored);
}
