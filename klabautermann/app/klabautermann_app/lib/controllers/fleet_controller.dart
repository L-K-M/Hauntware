import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../services/ssh_config_source.dart';

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

/// The fleet concern (03 §10.1): the server list from [CatalogReplaced]
/// snapshots, per-server link statuses from [LinkState] and probe results
/// from [Reachability] events, the workspace's selection, the servers
/// pinned to the top of the list (03 §10.3), and the desktop ssh_config
/// import (FL-02).
/// Pull-only by construction (D14): the one request it sends,
/// [ImportSshConfig], changes the engine's device-local import store and
/// never a catalog record, and pins stay on this device.
final class FleetController extends ChangeNotifier {
  /// [servers] seeds the list until the engine's first [CatalogReplaced].
  /// [sshConfig] is null on platforms without an ssh_config, which hides
  /// the import (see [sshConfigSourceFor]). [pinnedServerIds] are the pins
  /// `settings.json` restored, and `savePins` writes the set back; without
  /// it, as in most tests, pins are held in memory only.
  FleetController(
    this._engine, {
    List<FleetServer> servers = const [],
    this._sshConfig,
    Set<String> pinnedServerIds = const {},
    this._savePins,
  }) : _servers = List.unmodifiable(servers),
       _serverIds = {for (final server in servers) server.id},
       _pinnedServerIds = Set.unmodifiable(pinnedServerIds) {
    _events = _engine.events.listen(_onEngineEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  final SshConfigSource? _sshConfig;
  late final StreamSubscription<EngineEvent> _events;

  List<FleetServer> _servers;

  /// The ids [_servers] lists: the only servers statuses are kept for.
  Set<String> _serverIds;

  /// Kept for servers the fleet does not list too, so a pinned server that
  /// a sync drops and brings back returns pinned, as in Séance.
  Set<String> _pinnedServerIds;
  final Future<void> Function(Set<String> ids)? _savePins;

  final Map<String, LinkStatus> _linkStatuses = {};
  final Map<String, ReachabilityStatus> _reachability = {};
  String? _selectedServerId;

  /// The running import, from reading the file to the engine's answer.
  Future<SshConfigImportOutcome>? _import;

  /// Completed by the engine's answer to the [ImportSshConfig] in flight.
  /// The engine answers requests in order and [_import] allows one at a
  /// time, so the next answer always belongs to this completer.
  Completer<SshConfigImportOutcome>? _importAnswer;

  bool _engineStopped = false;
  bool _disposed = false;

  List<FleetServer> get servers => _servers;

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
        _replaceFleet(entries);
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
      // EndpointChanged refreshes one entry once F3's catalog lands;
      // everything else belongs to other concerns.
      case EndpointChanged():
      case EngineEvent():
        break;
    }
  }

  void _replaceFleet(List<FleetEntry> entries) {
    _servers = List.unmodifiable(entries.map(FleetServer.fromEntry));
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
    _reachability.removeWhere((serverId, _) => !ids.contains(serverId));
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
  }

  @override
  void dispose() {
    _disposed = true;
    _completeImport(
      const SshConfigImportRejected('the fleet controller was disposed'),
    );
    unawaited(_events.cancel());
    super.dispose();
  }
}
