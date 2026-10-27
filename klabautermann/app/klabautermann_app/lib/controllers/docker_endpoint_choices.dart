import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'fleet_controller.dart';

/// Saves one server's settings, or removes them when null:
/// `DeviceSettingsStore.setDockerEndpointOverride`.
typedef SaveDockerEndpointChoice =
    Future<void> Function(String serverId, DockerEndpointOverride? override);

/// Drops the stored choices the fleet no longer backs:
/// `DeviceSettingsStore.purgeDockerEndpointOverrides`.
typedef PurgeDockerEndpointChoices =
    Future<Set<String>> Function(Map<String, String> endpoints);

/// CN-09's engine socket per server, chosen on this device (D54, 03 §4.10):
/// automatic unless the user picked one of the sockets the probe found or
/// typed a path in the Docker tab's engine strip; and CN-16's `docker`
/// program, the one on the exec `PATH` unless the user typed a path
/// there. The composition root
/// restores the choices from `settings.json` and saves each change there;
/// without callbacks, as in most tests, they are held in memory only. Like
/// the SAF-08 notice's state, it outlives an engine run: each run's
/// `DockerController` sends the choices to its engine.
///
/// Each choice keeps the endpoint ([FleetServer.endpoint]) it was made
/// for, and [followFleet] drops it once the fleet lists the server no
/// more or under another endpoint (SYN-08), as the engine forgets its
/// copy, so a server id that now names another machine never inherits a
/// socket chosen for the old one.
final class DockerEndpointChoices extends ChangeNotifier {
  DockerEndpointChoices({
    Map<String, DockerEndpointOverride> stored = const {},
    this._save,
    this._purge,
  }) : _overrides = {...stored};

  final Map<String, DockerEndpointOverride> _overrides;
  final SaveDockerEndpointChoice? _save;

  /// The servers whose last save failed: choosing the same again saves
  /// again rather than changing nothing.
  final Set<String> _unsaved = {};
  final PurgeDockerEndpointChoices? _purge;

  FleetController? _fleet;

  /// The fleet list last purged against, or the one [followFleet] started
  /// from, which may be a seed rather than the engine's fleet.
  List<FleetServer> _servers = const [];

  /// [serverId]'s choice: automatic unless one was made on this device.
  DockerEndpointChoice choiceFor(String serverId) =>
      _overrides[serverId]?.choice ?? const DockerEndpointAuto();

  /// [serverId]'s `docker` program (CN-16): null for the one on the exec
  /// `PATH` unless a path was set on this device.
  String? programFor(String serverId) => _overrides[serverId]?.program;

  /// Makes [choice] [serverId]'s, at once, and saves it. A save that fails
  /// rethrows, and the choice holds until the app quits, so the caller can
  /// say it was not kept; choosing it again tries the save again.
  Future<void> choose(String serverId, DockerEndpointChoice choice) async {
    if (choiceFor(serverId) == choice && !_unsaved.contains(serverId)) return;

    await _put(serverId, switch (choice) {
      DockerEndpointAuto() => null,
      final DockerEndpointSocket socket => socket,
    }, programFor(serverId));
  }

  /// Makes [program] [serverId]'s `docker` (CN-16), or the one on the exec
  /// `PATH` when null, and saves it as [choose] saves a choice.
  Future<void> chooseProgram(String serverId, String? program) async {
    if (programFor(serverId) == program && !_unsaved.contains(serverId)) {
      return;
    }

    await _put(serverId, _overrides[serverId]?.choice, program);
  }

  Future<void> _put(
    String serverId,
    DockerEndpointSocket? socket,
    String? program,
  ) async {
    final override = socket == null && program == null
        ? null
        : DockerEndpointOverride(
            socket,
            endpoint: _endpointOf(serverId),
            program: program,
          );
    if (override == null) {
      _overrides.remove(serverId);
    } else {
      _overrides[serverId] = override;
    }
    notifyListeners();
    final save = _save;
    if (save == null) return;
    try {
      await save(serverId, override);
      _unsaved.remove(serverId);
    } catch (_) {
      _unsaved.add(serverId);
      rethrow;
    }
  }

  /// Drops the choices [fleet] no longer backs whenever its list changes.
  /// The list it has now is taken as it is, since before the engine's
  /// first fleet it is only a seed.
  void followFleet(FleetController fleet) {
    _fleet?.removeListener(_onFleet);
    _fleet = fleet;
    _servers = fleet.servers;
    fleet.addListener(_onFleet);
  }

  void _onFleet() {
    final servers = _fleet!.servers;
    // The controller notifies for selections and statuses too; only a new
    // list is a new fleet.
    if (identical(servers, _servers)) return;
    _purgeAgainst(servers);
  }

  /// Drops each choice whose server [servers] does not list, or lists
  /// under another endpoint, and has the store drop the same.
  void _purgeAgainst(List<FleetServer> servers) {
    _servers = servers;
    final endpoints = {for (final s in servers) s.id: s.endpoint};
    final before = _overrides.length;
    _overrides.removeWhere(
      (serverId, override) => endpoints[serverId] != override.endpoint,
    );
    if (_overrides.length != before) notifyListeners();

    final purge = _purge;
    if (purge == null) return;
    unawaited(
      purge(endpoints).then<void>(
        (_) {},
        onError: (Object error) =>
            debugPrint('The Docker socket choices were not saved: $error'),
      ),
    );
  }

  /// [serverId]'s endpoint in the fleet last seen; empty for a server it
  /// does not list, which a later fleet then drops.
  String _endpointOf(String serverId) {
    for (final server in _fleet?.servers ?? _servers) {
      if (server.id == serverId) return server.endpoint;
    }
    return '';
  }

  @override
  void dispose() {
    _fleet?.removeListener(_onFleet);
    super.dispose();
  }
}
