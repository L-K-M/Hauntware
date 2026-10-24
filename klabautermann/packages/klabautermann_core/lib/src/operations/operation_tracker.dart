// The detached runner (03 §7.17, SAF-23, M4 plan M11), second half:
// re-attach, results and cleanup. Each `ops` read becomes the server's
// list of detached operations: a running record is checked against its
// wrapper's PID and start ticks, a done one shows its result. A result
// the app has shown is audited, then its files are deleted: the user
// directory's at once, the root directory's through the elevation prelude
// while admin mode is on, otherwise the next time it is. Files older than
// 7 days are pruned on each link, the root directory's in admin mode.
import 'dart:async';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart'
    show RemoteCommandException, RemoteCommandResult, SshLink, quoteShellWord;

import '../admin/admin_mode.dart' show AdminSession;
import '../audit/audit_log.dart';
import '../engine/protocol.dart';
import '../sampling/sample_results.dart' show collectorUnavailable;
import 'operations_shown.dart';

/// How often a server with a running operation reads `ops` again [E]:
/// the `units` period, so a result shows about as soon as a unit change.
const kRunningOperationsReread = Duration(seconds: 15);

/// How long after a launch its operation keeps `ops` read again while no
/// listing shows it [E]: the wrapper writes its record only once
/// `systemd-run` or the setsid launch has returned, so the read the launch
/// asks for can miss it. A wrapper that fails before its first record
/// never shows, and the re-reads stop after this.
const kLaunchListingGrace = Duration(minutes: 1);

/// The exit of `HostCommands.startTicks` for a PID that names no process.
const _kProcessGone = 3;

/// One server's latest list and its link bookkeeping.
final class _Server {
  /// The latest `ops` listing, and the operations made of it by id.
  OpsListing? listing;
  Map<String, DetachedOperation> operations = const {};

  /// The link the user directory was last pruned on.
  SshLink? prunedOn;

  /// The admin session the root directory was last pruned in.
  AdminSession? rootPrunedIn;

  Timer? reread;

  /// The operations this device launched that no listing has shown yet,
  /// with when each launched.
  final Map<String, DateTime> unlisted = {};

  /// The tail of this server's steps, run one after another (see
  /// [OperationTracker._serially]).
  Future<void> steps = Future.value();
}

/// Follows every server's detached operations. The engine isolate owns
/// it and tells it each `ops` section ([listed]), each acknowledgement,
/// each launch, each admin session that starts ([adminOn]), and each link
/// that ends.
final class OperationTracker {
  /// [linkFor] gives a server's ready link; [sessionFor] its admin
  /// session, null while admin mode is off; [readOps] asks the scheduler
  /// for another `ops` read. [startTimer] and [now] are test seams.
  OperationTracker({
    required this._linkFor,
    required this._sessionFor,
    required this._readOps,
    required this._store,
    required this._audit,
    required this._emit,
    this._deviceId,
    this._startTimer = Timer.new,
    this._now = DateTime.now,
  });

  final SshLink? Function(String serverId) _linkFor;
  final AdminSession? Function(String serverId) _sessionFor;
  final void Function(String serverId) _readOps;
  final OperationsShownStore _store;
  final AuditLog _audit;
  final void Function(EngineEvent event) _emit;
  final String? _deviceId;
  final Timer Function(Duration duration, void Function() callback) _startTimer;
  final DateTime Function() _now;

  final Map<String, _Server> _servers = {};

  /// Follows [serverId]'s `ops` [section], read on its current link.
  Future<void> listed(String serverId, HwsSection section) {
    _servers.putIfAbsent(serverId, _Server.new);
    return _serially(serverId, () => _listed(serverId, section));
  }

  Future<void> _listed(String serverId, HwsSection section) async {
    final server = _servers[serverId];
    if (server == null) return;
    server.reread?.cancel();
    server.reread = null;

    if (collectorUnavailable(section) case final unavailable?) {
      server.listing = null;
      server.operations = const {};
      _emit(OperationsChanged(serverId, unavailable: unavailable));
      return;
    }
    final listing = parseOps(section.payload).value;

    final link = _linkFor(serverId);
    if (link == null) return;

    final operations = <String, DetachedOperation>{};
    for (final record in listing.records) {
      operations[record.id] = await _operation(link, record);
    }
    server.listing = listing;
    server.operations = operations;
    final launchedSince = _now().subtract(kLaunchListingGrace);
    server.unlisted.removeWhere(
      (id, at) =>
          operations.containsKey(id) ||
          listing.rejected.any((r) => r.id == id) ||
          !at.isAfter(launchedSince),
    );
    await _forgetCleaned(serverId, listing);
    await _cleanUp(serverId, link);
    await _pruneUser(server, link, listing);
    _report(serverId);

    if (server.unlisted.isNotEmpty ||
        operations.values.any(
          (o) => o.state == DetachedOperationState.running,
        )) {
      server.reread = _startTimer(
        kRunningOperationsReread,
        () => _readOps(serverId),
      );
    }
  }

  /// Records that this device launched [serverId]'s operation [id] in
  /// [directory], with the facts its result's audit record names, and
  /// reads `ops` again to show it.
  Future<void> launched(
    String serverId,
    String id, {
    required OpDirectoryKind directory,
    required OperationLaunch launch,
  }) {
    _servers.putIfAbsent(serverId, _Server.new);
    return _serially(serverId, () async {
      _servers[serverId]?.unlisted[id] = _now();
      // A note the file misses is kept in memory.
      await _quietly(
        () => _store.put(
          serverId,
          id,
          OperationNote(directory: directory, launch: launch),
        ),
      );
      _readOps(serverId);
    });
  }

  /// Audits the shown result of [serverId]'s operation [id], then deletes
  /// its files where it can. Returns why it refused, or null, once the
  /// audit record and note are written; the deletion follows, since a
  /// slow link must not hold up the answer.
  Future<String?> acknowledge(String serverId, String id) {
    if (!_servers.containsKey(serverId)) {
      return Future.value('unknown operation');
    }
    return _serially(serverId, () => _acknowledge(serverId, id));
  }

  Future<String?> _acknowledge(String serverId, String id) async {
    final server = _servers[serverId];
    final operation = server?.operations[id];
    if (server == null || operation == null) return 'unknown operation';
    if (operation.acknowledged) return null;
    if (operation.state
        case DetachedOperationState.running || DetachedOperationState.unknown) {
      return 'operation not finished';
    }

    final note = _store.notesOf(serverId)[id];
    // A record that cannot be written is lost; the result stands. A note
    // the file misses is kept in memory, and the next listing retries the
    // cleanup.
    await _quietly(
      () => _audit.append(_auditRecord(serverId, operation, note?.launch)),
    );
    await _quietly(
      () => _store.put(
        serverId,
        id,
        (note ?? OperationNote(directory: operation.directory)).acknowledge(),
      ),
    );
    server.operations = {
      ...server.operations,
      id: _withNote(operation, _store.notesOf(serverId)[id]),
    };

    _report(serverId);

    unawaited(
      _serially(serverId, () async {
        final link = _linkFor(serverId);
        if (link == null) return;
        await _cleanUp(serverId, link);
        _report(serverId);
      }),
    );
    return null;
  }

  /// Follows admin mode turning on for [serverId]: the root directory's
  /// acknowledged operations are deleted, and its old files pruned once
  /// per admin session.
  Future<void> adminOn(String serverId) {
    if (!_servers.containsKey(serverId)) return Future.value();
    return _serially(serverId, () => _adminOn(serverId));
  }

  Future<void> _adminOn(String serverId) async {
    final server = _servers[serverId];
    final link = _linkFor(serverId);
    if (server == null || link == null) return;

    await _cleanUp(serverId, link);
    final session = _sessionFor(serverId);
    final root = server.listing?.directories[OpDirectoryKind.root];
    if (session != null &&
        !identical(server.rootPrunedIn, session) &&
        root?.state == OpDirectoryState.ok) {
      server.rootPrunedIn = session;
      await _quietly(
        () => session.executor.run(
          OperationCommands.opPrune(kRootOpsDir),
          password: session.password,
        ),
      );
    }
    _report(serverId);
  }

  /// The output file of [serverId]'s operation [id] in the directory the
  /// latest `ops` read listed it in, or null when that read did not list
  /// it.
  String? logPath(String serverId, String id) {
    final server = _servers[serverId];
    final operation = server?.operations[id];
    if (operation == null) return null;
    final dir = server!.listing?.directories[operation.directory]?.path;
    return dir == null ? null : '$dir/$id.log';
  }

  /// Follows the end of [serverId]'s link: no re-read is due until the
  /// next one is ready.
  void linkLost(String serverId) {
    final server = _servers[serverId];
    server?.reread?.cancel();
    server?.reread = null;
  }

  /// Forgets every server outside [fleet] and its notes.
  void retain(Set<String> fleet) {
    _servers.removeWhere((serverId, server) {
      if (fleet.contains(serverId)) return false;
      server.reread?.cancel();
      return true;
    });
    unawaited(_store.retain(fleet).catchError((Object _) {}));
  }

  /// Stops every re-read.
  void close() {
    for (final server in _servers.values) {
      server.reread?.cancel();
    }
    _servers.clear();
  }

  /// Runs [step] after every earlier step of [serverId]'s. A listing
  /// awaits the link per running record before it stores its operations,
  /// so an acknowledgement or cleanup that landed in between would be
  /// written back over: the cleaned-up result would show again, and
  /// acknowledging it again would audit it twice. Each step looks its
  /// server up again, since [retain] or [close] may have dropped it, and
  /// a step queued after that, such as an acknowledgement's cleanup,
  /// finds nothing to do.
  Future<T> _serially<T>(String serverId, Future<T> Function() step) {
    final server = _servers[serverId];
    if (server == null) return step();
    final result = server.steps.then((_) => step());
    server.steps = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  // -- listing ----------------------------------------------------------

  /// [record] as an operation: a running one is checked against its
  /// wrapper, which lives exactly while its PID shows the record's start
  /// ticks. A record without start ticks (the wrapper could not read
  /// them) reads as running while the PID exists.
  Future<DetachedOperation> _operation(SshLink link, OpRecord record) async {
    var state = switch (record.state) {
      OpState.done => DetachedOperationState.done,
      OpState.running => DetachedOperationState.unknown,
    };
    if (record.state == OpState.running) {
      try {
        final result = await link.run(
          _line(HostCommands.startTicks(record.pid)),
          stdin: const [],
        );
        state = switch (result.exitCode) {
          0
              when record.startTicks == null ||
                  int.tryParse(result.stdout.trim()) == record.startTicks =>
            DetachedOperationState.running,
          0 || _kProcessGone => DetachedOperationState.lost,
          _ => DetachedOperationState.unknown,
        };
      } on RemoteCommandException {
        // Unknown until the next read.
      }
    }
    return DetachedOperation(
      id: record.id,
      directory: record.directory,
      state: state,
      unit: record.unit,
      startedAt: record.startedAt,
      endedAt: record.endedAt,
      exitCode: record.exitCode,
    );
  }

  /// Drops the notes of operations whose files are gone: a directory read
  /// to its end that no longer lists them, which another device cleaned
  /// up or the prune removed. A launch no listing has shown yet is
  /// spared: an ops read in flight when the launch landed also reads to
  /// its end without the record, and losing the note there would audit
  /// the result without its launch facts. The launch grace ([_Server
  /// .unlisted]) bounds this exactly as it bounds the re-reads.
  Future<void> _forgetCleaned(String serverId, OpsListing listing) async {
    final server = _servers[serverId];
    final listed = {
      for (final r in listing.records) r.id,
      for (final r in listing.rejected) r.id,
    };
    bool readToEnd(OpDirectoryKind kind) => switch (listing.directories[kind]) {
      final d? =>
        (d.state == OpDirectoryState.ok ||
                d.state == OpDirectoryState.absent) &&
            !d.capped,
      null => false,
    };
    final gone = [
      for (final MapEntry(key: id, value: note)
          in _store.notesOf(serverId).entries)
        if (!listed.contains(id) &&
            !(server?.unlisted.containsKey(id) ?? false) &&
            readToEnd(note.directory)) id,
    ];
    await _quietly(() => _store.remove(serverId, gone));
  }

  /// Deletes the files of [serverId]'s acknowledged operations: the user
  /// directory's over [link], the root directory's through the admin
  /// session, when there is one.
  Future<void> _cleanUp(String serverId, SshLink link) async {
    final server = _servers[serverId];
    final listing = server?.listing;
    if (server == null || listing == null) return;

    final acknowledged = {
      for (final MapEntry(key: id, value: note)
          in _store.notesOf(serverId).entries)
        if (note.acknowledged) id: note.directory,
    };
    for (final kind in OpDirectoryKind.values) {
      final ids = [
        for (final MapEntry(key: id, value: dir) in acknowledged.entries)
          if (dir == kind) id,
      ]..sort();
      final path = listing.directories[kind]?.path;
      if (ids.isEmpty || path == null) continue;

      final argv = OperationCommands.opCleanup(path, ids);
      final RemoteCommandResult? result;
      if (kind == OpDirectoryKind.root) {
        final session = _sessionFor(serverId);
        result = session == null
            ? null
            : await _quietly(
                () => session.executor.run(argv, password: session.password),
              );
      } else {
        result = await _quietly(() => link.run(_line(argv), stdin: const []));
      }
      if (result?.exitCode != 0) continue;

      await _quietly(() => _store.remove(serverId, ids));
      server.operations = {
        for (final MapEntry(key: id, value: o) in server.operations.entries)
          if (!ids.contains(id)) id: o,
      };
    }
  }

  /// Prunes the user directory once per link, when it was listed.
  Future<void> _pruneUser(
    _Server server,
    SshLink link,
    OpsListing listing,
  ) async {
    final user = listing.directories[OpDirectoryKind.user];
    if (identical(server.prunedOn, link) ||
        user?.state != OpDirectoryState.ok ||
        user?.path == null) {
      return;
    }
    server.prunedOn = link;
    await _quietly(
      () => link.run(
        _line(OperationCommands.opPrune(user!.path!)),
        stdin: const [],
      ),
    );
  }

  void _report(String serverId) {
    final server = _servers[serverId];
    final listing = server?.listing;
    if (server == null || listing == null) return;

    final notes = _store.notesOf(serverId);
    final operations = [
      for (final o in server.operations.values) _withNote(o, notes[o.id]),
    ]..sort((a, b) => a.id.compareTo(b.id));
    _emit(
      OperationsChanged(
        serverId,
        operations: operations,
        directories: listing.directories,
      ),
    );
  }

  static DetachedOperation _withNote(
    DetachedOperation o,
    OperationNote? note,
  ) => DetachedOperation(
    id: o.id,
    directory: o.directory,
    state: o.state,
    unit: o.unit,
    startedAt: o.startedAt,
    endedAt: o.endedAt,
    exitCode: o.exitCode,
    action: note?.launch?.action,
    targetName: note?.launch?.targetName,
    acknowledged: note?.acknowledged ?? false,
  );

  /// The audit record of a shown result: the launch's facts when this
  /// device launched it, otherwise the operation's id as its target.
  AuditRecord _auditRecord(
    String serverId,
    DetachedOperation operation,
    OperationLaunch? launch,
  ) {
    final ended = operation.endedAt ?? _now().toUtc();
    final succeeded =
        operation.state == DetachedOperationState.done &&
        operation.exitCode == 0;
    return AuditRecord(
      serverId: serverId,
      action: launch?.action ?? kDetachedOperationAction,
      targetName: launch?.targetName ?? operation.id,
      steps: launch?.steps ?? const [],
      tier: launch?.tier ?? ConfirmationTier.none,
      outcome: succeeded ? ActionOutcome.succeeded : ActionOutcome.failed,
      startedAt: operation.startedAt ?? launch?.startedAt ?? ended,
      endedAt: ended,
      deviceId: _deviceId,
      failure: succeeded
          ? null
          : operation.state == DetachedOperationState.lost
          ? ActionFailure.interrupted
          : ActionFailure.stepFailed,
      exitCode: operation.exitCode,
    );
  }

  static String _line(List<String> argv) =>
      HostCommands.commandLine(argv, quote: quoteShellWord);

  /// [run]'s value, or null when it failed: cleanup and prune are retried
  /// by the next listing or admin session, never reported.
  static Future<T?> _quietly<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on Exception {
      // The link's, elevation's and the note file's failures alike.
      return null;
    }
  }
}

/// The audit record's action for the result of an operation another
/// device launched, whose intent this device never saw.
const kDetachedOperationAction = 'DetachedOperation';
