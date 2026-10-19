// Admin mode (03 §8.2, SAF-02; M4 plan M5): per server, explicit, off by
// default. Turning it on detects how the account elevates from the probe's
// facts, asks for the password only when that needs one, validates it, and
// keeps it in this isolate's memory until admin mode ends: after a period
// without elevated work, when the app goes to the background, when the
// link drops, or when the server leaves the fleet. Dart strings cannot be
// zeroed, so ending drops every reference instead.
//
//   off -> detecting -> (awaitingPassword -> validating)* -> on(expiresAt)
//                    \-> failed(failure)              on -> expired(end)
import 'dart:async';

import 'package:klabautermann_host/klabautermann_host.dart' show HostProfile;
import 'package:meta/meta.dart';
import 'package:seance_core/seance_core.dart'
    show
        ChannelOpenException,
        ElevatedExecutor,
        ElevationException,
        ElevationFailureKind,
        ElevationProbe,
        RemoteCommandException,
        SshLink;

import '../engine/protocol.dart';
import '../links/prompt_broker.dart';

/// How often a wrong password may be retried before admin mode fails.
const kAdminPasswordAttempts = 3;

/// Checks that [password] (null when no rung needs one) elevates on
/// [link], and throws [ElevationException] when it does not.
///
/// The default runs `true` through the executor. Under sudo's
/// `timestamp_type=global` a cached record lets a wrong password through
/// that check (03 D65); E04's executor validation ignores cached records,
/// and replaces this default when it lands.
typedef AdminValidator =
    Future<void> Function(SshLink link, ElevationProbe probe, String? password);

/// What elevated work needs while admin mode is on: the executor and the
/// password, which never leave the engine.
final class AdminSession {
  AdminSession._(this.executor, this._password);

  /// A session over [executor], for the runner's tests.
  @visibleForTesting
  AdminSession.test(this.executor, this._password);

  final ElevatedExecutor executor;
  final String? _password;

  /// The password for [executor]'s prelude rungs, or null when the rung
  /// needs none.
  String? get password => _password;

  @override
  String toString() => 'AdminSession(${executor.runtimeType})';
}

/// The elevation facts of [profile] as the executor reads them (03 §6.1).
/// An unknown fact enables nothing.
ElevationProbe elevationProbeOf(HostProfile profile) {
  final sudo = profile.sudoVersionLine;
  final doas = profile.doasPresent ?? false;
  return ElevationProbe(
    isRoot: profile.uid == 0,
    sudoVersionLine: sudo,
    sudoIsRs: sudo != null && sudo.startsWith('sudo-rs'),
    sudoNopasswd: sudo != null && (profile.sudoNonInteractive ?? false),
    doasPresent: doas,
    doasNopasswd: doas && (profile.doasNonInteractive ?? false),
    run0Present: profile.run0Present ?? false,
    printfIsBuiltin: profile.printfBuiltin ?? false,
  );
}

/// Whether elevation on [probe] goes through the password prelude
/// (03 §8.3 rung 3): sudo, no blanket NOPASSWD and no root login.
bool needsPassword(ElevationProbe probe) =>
    !probe.isRoot &&
    probe.sudoVersionLine != null &&
    !probe.sudoNopasswd &&
    probe.printfIsBuiltin;

/// Runs admin mode for every server. It holds no policy: the engine
/// refuses [enable] for an observe-only or read-only server first.
final class AdminModeController {
  AdminModeController({
    required this._linkFor,
    required this._endpointOf,
    required this._prompts,
    required this._emit,
    AdminValidator? validate,
    DateTime Function()? now,
    Timer Function(Duration duration, void Function() callback)? startTimer,
  }) : _validate = validate ?? _validateWithTrue,
       _now = now ?? DateTime.now,
       _startTimer = startTimer ?? Timer.new;

  final SshLink? Function(String serverId) _linkFor;
  final ({String host, int port, String user})? Function(String serverId)
  _endpointOf;
  final PromptBroker _prompts;
  final void Function(EngineEvent event) _emit;
  final AdminValidator _validate;
  final DateTime Function() _now;
  final Timer Function(Duration duration, void Function() callback) _startTimer;

  final Map<String, HostProfile> _profiles = {};
  final Map<String, _Server> _servers = {};

  /// How long admin mode lasts without elevated work (03 §8.2).
  Duration expiry = kDefaultAdminExpiry;

  /// The servers whose admin mode is on or turning on.
  Iterable<String> get servers => _servers.keys;

  /// The session's elevation for [serverId] while admin mode is on.
  AdminSession? session(String serverId) => _servers[serverId]?.session;

  /// Keeps [profile] as [serverId]'s elevation facts.
  void probed(String serverId, HostProfile profile) =>
      _profiles[serverId] = profile;

  /// Turns admin mode on for [serverId]: a server already on only has its
  /// clock reset, and one already turning on is left to finish.
  Future<void> enable(String serverId) async {
    final current = _servers[serverId];
    if (current != null) {
      if (current.session != null) touch(serverId);
      return;
    }
    final server = _servers[serverId] = _Server();
    _send(serverId, AdminModePhase.detecting);

    final link = _linkFor(serverId);
    final profile = _profiles[serverId];
    final endpoint = _endpointOf(serverId);
    if (link == null || endpoint == null) {
      return _fail(serverId, server, AdminFailure.noLink);
    }
    if (profile == null) return _fail(serverId, server, AdminFailure.notProbed);
    final probe = elevationProbeOf(profile);

    if (!needsPassword(probe)) {
      final failure = await _check(link, probe, null);
      if (!_current(serverId, server)) return;
      if (failure != null) return _fail(serverId, server, failure);
      return _turnOn(serverId, server, link, probe, null);
    }

    final attempt = server.prompt = _prompts.attempt(serverId);
    for (var i = 0; i < kAdminPasswordAttempts; i++) {
      _send(serverId, AdminModePhase.awaitingPassword, retry: i > 0);
      final answer = await attempt.ask(
        host: endpoint.host,
        port: endpoint.port,
        request: ElevationPromptRequest(
          user: profile.user ?? endpoint.user,
          retry: i > 0,
        ),
      );
      if (!_current(serverId, server)) return;
      final password = switch (answer) {
        PromptSecretAnswer(:final secret?) when secret.isNotEmpty => secret,
        _ => null,
      };
      if (password == null) {
        return _fail(serverId, server, AdminFailure.cancelled);
      }

      _send(serverId, AdminModePhase.validating);
      final failure = await _check(link, probe, password);
      if (!_current(serverId, server)) return;
      if (failure == null) {
        attempt.end();
        return _turnOn(serverId, server, link, probe, password);
      }
      if (failure != AdminFailure.wrongPassword) {
        return _fail(serverId, server, failure);
      }
    }
    _fail(serverId, server, AdminFailure.wrongPassword);
  }

  /// Turns admin mode off for [serverId], at once and from any phase.
  void disable(String serverId) {
    final server = _servers.remove(serverId);
    if (server == null) return;
    server.end();
    _send(serverId, AdminModePhase.off);
  }

  /// Resets [serverId]'s inactivity clock after elevated work: a run plan
  /// or an elevated read.
  void touch(String serverId) {
    final server = _servers[serverId];
    if (server?.session == null) return;
    _arm(serverId, server!);
  }

  /// The server's link dropped: elevation over it is gone.
  void linkLost(String serverId) => _expire(serverId, AdminEnd.linkLost);

  /// The app went to the background (03 §8.2): every admin mode ends.
  void setActivity(AppActivity activity) {
    if (activity != AppActivity.background) return;
    for (final serverId in _servers.keys.toList()) {
      _expire(serverId, AdminEnd.background);
    }
  }

  /// [serverIds] left the fleet or changed endpoint.
  void forget(Set<String> serverIds) {
    for (final serverId in serverIds) {
      _profiles.remove(serverId);
      _expire(serverId, AdminEnd.serverRemoved);
    }
  }

  // Validates and maps a refusal to what admin mode reports.
  Future<AdminFailure?> _check(
    SshLink link,
    ElevationProbe probe,
    String? password,
  ) async {
    try {
      await _validate(link, probe, password);
      return null;
    } on ElevationException catch (e) {
      return switch (e.kind) {
        ElevationFailureKind.wrongPassword => AdminFailure.wrongPassword,
        ElevationFailureKind.notInSudoers => AdminFailure.notInSudoers,
        ElevationFailureKind.ttyRequired => AdminFailure.ttyRequired,
        ElevationFailureKind.passwordRequired ||
        ElevationFailureKind.unavailable => AdminFailure.unavailable,
      };
    } on RemoteCommandException {
      return AdminFailure.noLink;
    } on ChannelOpenException {
      // The link refused the channel, at its session limit or closing.
      return AdminFailure.noLink;
    }
  }

  void _turnOn(
    String serverId,
    _Server server,
    SshLink link,
    ElevationProbe probe,
    String? password,
  ) {
    server.session = AdminSession._(ElevatedExecutor(link, probe), password);
    _arm(serverId, server);
  }

  void _arm(String serverId, _Server server) {
    server.timer?.cancel();
    final expiresAt = _now().add(expiry);
    server.timer = _startTimer(
      expiry,
      () => _expire(serverId, AdminEnd.inactivity),
    );
    _send(serverId, AdminModePhase.on, expiresAt: expiresAt);
  }

  void _expire(String serverId, AdminEnd end) {
    final server = _servers.remove(serverId);
    if (server == null) return;
    server.end();
    _send(serverId, AdminModePhase.expired, ended: end);
  }

  void _fail(String serverId, _Server server, AdminFailure failure) {
    _servers.remove(serverId);
    server.end();
    _send(serverId, AdminModePhase.failed, failure: failure);
  }

  // Whether [server] is still [serverId]'s, after an await that disable,
  // expiry or forget may have overtaken.
  bool _current(String serverId, _Server server) =>
      identical(_servers[serverId], server);

  void _send(
    String serverId,
    AdminModePhase phase, {
    DateTime? expiresAt,
    bool retry = false,
    AdminFailure? failure,
    AdminEnd? ended,
  }) => _emit(
    AdminModeState(
      serverId,
      phase,
      expiresAt: expiresAt,
      retry: retry,
      failure: failure,
      ended: ended,
    ),
  );

  static Future<void> _validateWithTrue(
    SshLink link,
    ElevationProbe probe,
    String? password,
  ) async {
    final result = await ElevatedExecutor(
      link,
      probe,
    ).run(const ['true'], password: password);
    if (result.exitCode != 0) {
      throw ElevationException(ElevationFailureKind.unavailable, result.stderr);
    }
  }
}

final class _Server {
  AdminSession? session;
  PromptAttempt? prompt;
  Timer? timer;

  void end() {
    timer?.cancel();
    prompt?.end();
    session = null;
  }
}
