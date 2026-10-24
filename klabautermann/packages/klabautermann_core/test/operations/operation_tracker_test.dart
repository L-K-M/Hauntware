// The detached runner's re-attach, results and cleanup (03 §7.17, M4
// E17b): each `ops` read becomes the server's operation list, a running
// record checked against its wrapper's PID and start ticks; a shown
// result is audited and its files deleted, the root directory's through
// admin mode, now or later; the user directory is pruned once per link
// and the root one once per admin session.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/admin/admin_mode.dart';
import 'package:klabautermann_core/src/audit/audit_log.dart';
import 'package:klabautermann_core/src/operations/operation_tracker.dart';
import 'package:klabautermann_core/src/operations/operations_shown.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show HwsSection, OpDirectoryKind, SectionStatus, kRootOpsDir;
import 'package:seance_core/seance_core.dart'
    show
        ElevatedExecutor,
        ElevationProbe,
        RemoteCommandException,
        RemoteCommandResult;
import 'package:test/test.dart';

import '../support/fake_clock.dart';
import '../support/scripted_link.dart';

const _s1 = 'srv-1';
const _done = '00000000000000d0';
const _running = '00000000000000a1';
const _rootDone = '00000000000000f0';
const _userDir = '/home/klab/.local/state/klabautermann/ops';

/// Answers each command with [answer], or success, and records it.
final class _Link extends TestLinkBase {
  final commands = <String>[];
  RemoteCommandResult? Function(String command)? answer;

  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) async {
    commands.add(command);
    if (hold?.call(command) case final held?) await held;
    return answer?.call(command) ?? const RemoteCommandResult(exitCode: 0);
  }

  /// A future [command] waits for before it is answered, or null.
  Future<void>? Function(String command)? hold;

  Iterable<String> containing(String text) =>
      commands.where((c) => c.contains(text));
}

String _record(
  String id, {
  String state = 'done',
  int pid = 4242,
  int? ticks = 777,
  int? exit = 0,
}) => jsonEncode({
  'v': 1,
  'id': id,
  'state': state,
  'pid': pid,
  'startTicks': ticks,
  'unit': null,
  'exit': state == 'done' ? exit : null,
  'startedAt': 1792000000,
  'endedAt': state == 'done' ? 1792000060 : null,
});

String _rec(String kind, String id, String body) =>
    'rec $kind $id ok ${utf8.encode(body).length}\n$body\n';

/// An `ok` section listing [user] and [root] records, as `c_ops` joins
/// both directories' listings.
HwsSection _section({
  Map<String, String> user = const {},
  Map<String, String> root = const {},
}) {
  final text = StringBuffer();
  for (final MapEntry(key: id, value: body) in user.entries) {
    text.write(_rec('user', id, body));
  }
  text.write('dir user ok ${user.length} $_userDir\n');
  for (final MapEntry(key: id, value: body) in root.entries) {
    text.write(_rec('root', id, body));
  }
  text.write(
    root.isEmpty
        ? 'dir root absent 0 $kRootOpsDir\n'
        : 'dir root ok ${root.length} $kRootOpsDir\n',
  );
  return HwsSection(
    'ops',
    SectionStatus.ok,
    Uint8List.fromList(utf8.encode('$text')),
  );
}

void main() {
  late _Link link;
  late FakeClock clock;
  late List<EngineEvent> events;
  late List<String> reads;
  late OperationsShownStore store;
  late AuditLog audit;
  late AdminSession? session;
  late OperationTracker tracker;

  setUp(() {
    link = _Link();
    clock = FakeClock();
    events = [];
    reads = [];
    store = OperationsShownStore.memory();
    audit = AuditLog(
      Directory.systemTemp,
      storage: AuditStorage.memory,
      deviceId: 'device-1',
    );
    session = null;
    tracker = OperationTracker(
      linkFor: (id) => id == _s1 ? link : null,
      sessionFor: (_) => session,
      readOps: reads.add,
      store: store,
      audit: audit,
      emit: events.add,
      deviceId: 'device-1',
      startTimer: clock.startTimer,
      now: () => clock.now,
    );
  });

  tearDown(() => tracker.close());

  OperationsChanged last() => events.whereType<OperationsChanged>().last;

  DetachedOperation op(String id) =>
      last().operations.singleWhere((o) => o.id == id);

  test('a done record shows its result; the user directory is pruned '
      'once per link', () async {
    await tracker.listed(_s1, _section(user: {_done: _record(_done)}));
    final done = op(_done);
    expect(done.state, DetachedOperationState.done);
    expect(done.exitCode, 0);
    expect(done.directory, OpDirectoryKind.user);
    expect(done.action, isNull, reason: 'another device launched it');
    expect(last().directories[OpDirectoryKind.user]?.path, _userDir);
    expect(link.containing("'klabautermann-prune' '$_userDir'"), hasLength(1));

    await tracker.listed(_s1, _section(user: {_done: _record(_done)}));
    expect(link.containing("'klabautermann-prune' '$_userDir'"), hasLength(1));
    expect(reads, isEmpty, reason: 'nothing runs, so no re-read is due');
  });

  test('a running record whose wrapper shows its start ticks runs, and '
      'ops is read again 15 s later', () async {
    link.answer = (c) => c.contains('klabautermann-ticks')
        ? const RemoteCommandResult(exitCode: 0, stdout: '777\n')
        : null;
    await tracker.listed(
      _s1,
      _section(user: {_running: _record(_running, state: 'running')}),
    );
    expect(op(_running).state, DetachedOperationState.running);
    expect(link.containing("'klabautermann-ticks' '4242'"), hasLength(1));

    await clock.elapse(const Duration(seconds: 14));
    expect(reads, isEmpty);
    await clock.elapse(const Duration(seconds: 1));
    expect(reads, [_s1]);

    tracker.linkLost(_s1);
    await tracker.listed(
      _s1,
      _section(user: {_running: _record(_running, state: 'running')}),
    );
    tracker.linkLost(_s1);
    await clock.elapse(const Duration(minutes: 1));
    expect(reads, [_s1], reason: 'a lost link cancels the re-read');
  });

  test('a wrapper that is gone, or whose PID now names another process, '
      'is lost; an unchecked one is unknown', () async {
    String? ticks;
    var gone = false;
    var broken = false;
    link.answer = (c) {
      if (!c.contains('klabautermann-ticks')) return null;
      if (broken) throw const RemoteCommandException('channel closed');
      return gone
          ? const RemoteCommandResult(exitCode: 3)
          : RemoteCommandResult(exitCode: 0, stdout: '$ticks\n');
    };
    final section = _section(
      user: {_running: _record(_running, state: 'running')},
    );

    ticks = '778';
    await tracker.listed(_s1, section);
    expect(op(_running).state, DetachedOperationState.lost);

    gone = true;
    await tracker.listed(_s1, section);
    expect(op(_running).state, DetachedOperationState.lost);

    broken = true;
    await tracker.listed(_s1, section);
    expect(op(_running).state, DetachedOperationState.unknown);
    expect(await tracker.acknowledge(_s1, _running), 'operation not finished');
  });

  test('a record without start ticks runs while its PID exists', () async {
    link.answer = (c) => c.contains('klabautermann-ticks')
        ? const RemoteCommandResult(exitCode: 0, stdout: '5\n')
        : null;
    await tracker.listed(
      _s1,
      _section(
        user: {_running: _record(_running, state: 'running', ticks: null)},
      ),
    );
    expect(op(_running).state, DetachedOperationState.running);
  });

  test('acknowledging a user result audits it and deletes its files at '
      'once', () async {
    await tracker.listed(_s1, _section(user: {_done: _record(_done, exit: 2)}));
    expect(await tracker.acknowledge(_s1, _done), isNull);
    await pumpEventQueue();

    final (:records, more: _) = await audit.query(_s1);
    final record = records.single;
    expect(record.action, kDetachedOperationAction);
    expect(record.targetName, _done);
    expect(record.outcome, ActionOutcome.failed);
    expect(record.failure, ActionFailure.stepFailed);
    expect(record.exitCode, 2);
    expect(record.deviceId, 'device-1');

    expect(
      link.containing("'rm' '-f' '--' '$_userDir/$_done.json'"),
      hasLength(1),
    );
    expect(last().operations, isEmpty);
    expect(store.notesOf(_s1), isEmpty);
    expect(await tracker.acknowledge(_s1, _done), 'unknown operation');
  });

  test('an acknowledgement during a listing lands after it, and the '
      'listing does not bring the cleaned-up result back', () async {
    final ticks = Completer<void>();
    link.answer = (c) => c.contains('klabautermann-ticks')
        ? const RemoteCommandResult(exitCode: 0, stdout: '777\n')
        : null;
    final section = _section(
      user: {
        _done: _record(_done),
        _running: _record(_running, state: 'running'),
      },
    );
    await tracker.listed(_s1, section);

    link.hold = (c) => c.contains('klabautermann-ticks') ? ticks.future : null;
    final listing = tracker.listed(_s1, section);
    await pumpEventQueue();
    final acknowledged = tracker.acknowledge(_s1, _done);
    await pumpEventQueue();
    ticks.complete();
    await listing;
    expect(await acknowledged, isNull);
    await pumpEventQueue();

    expect(last().operations.map((o) => o.id), [_running]);
    expect(store.notesOf(_s1), isEmpty);
    expect(await tracker.acknowledge(_s1, _done), 'unknown operation');
    expect((await audit.query(_s1)).records, hasLength(1));
  });

  test('an acknowledgement answers once audited; the cleanup follows '
      'without holding it up', () async {
    final rm = Completer<void>();
    await tracker.listed(_s1, _section(user: {_done: _record(_done)}));
    link.hold = (c) => c.contains("'rm'") ? rm.future : null;

    expect(await tracker.acknowledge(_s1, _done), isNull);
    expect((await audit.query(_s1)).records, hasLength(1));
    expect(op(_done).acknowledged, isTrue);
    expect(store.notesOf(_s1)[_done]?.acknowledged, isTrue);

    rm.complete();
    await pumpEventQueue();
    expect(last().operations, isEmpty);
    expect(store.notesOf(_s1), isEmpty);
  });

  test('a server that leaves the fleet while its result is acknowledged '
      'skips the cleanup', () async {
    await tracker.listed(_s1, _section(user: {_done: _record(_done)}));
    final first = tracker;
    tracker = OperationTracker(
      linkFor: (id) => id == _s1 ? link : null,
      sessionFor: (_) => session,
      readOps: reads.add,
      store: store,
      audit: audit,
      emit: (event) {
        events.add(event);
        // The fleet changes as the acknowledgement reports.
        if (event is OperationsChanged &&
            event.operations.any((o) => o.acknowledged)) {
          tracker.retain({});
        }
      },
      deviceId: 'device-1',
      startTimer: clock.startTimer,
      now: () => clock.now,
    );
    first.close();
    await tracker.listed(_s1, _section(user: {_done: _record(_done)}));

    expect(await tracker.acknowledge(_s1, _done), isNull);
    await pumpEventQueue();
    expect(link.containing("'rm'"), isEmpty);
  });

  test("a launch's facts name its result's audit record", () async {
    await tracker.launched(
      _s1,
      _done,
      directory: OpDirectoryKind.user,
      launch: OperationLaunch(
        action: 'RedeployStack',
        targetName: 'web',
        steps: ['docker compose pull'],
        tier: ConfirmationTier.acknowledge,
        startedAt: DateTime.utc(2026, 10, 18, 9),
      ),
    );
    expect(reads, [_s1]);

    await tracker.listed(_s1, _section(user: {_done: _record(_done)}));
    expect(op(_done).action, 'RedeployStack');
    expect(op(_done).targetName, 'web');
    await tracker.acknowledge(_s1, _done);

    final record = (await audit.query(_s1)).records.single;
    expect(record.action, 'RedeployStack');
    expect(record.targetName, 'web');
    expect(record.steps, ['docker compose pull']);
    expect(record.tier, ConfirmationTier.acknowledge);
    expect(record.outcome, ActionOutcome.succeeded);
    expect(record.failure, isNull);
  });

  test('a launch the next listing misses keeps ops read every 15 s until '
      'it shows, for at most a minute', () async {
    final launch = OperationLaunch(
      action: 'RedeployStack',
      targetName: 'web',
      steps: ['docker compose pull'],
      tier: ConfirmationTier.acknowledge,
      startedAt: DateTime.utc(2026, 10, 18, 9),
    );
    await tracker.launched(
      _s1,
      _done,
      directory: OpDirectoryKind.user,
      launch: launch,
    );
    expect(reads, [_s1]);

    // The wrapper has not written its record yet.
    await tracker.listed(_s1, _section());
    await clock.elapse(const Duration(seconds: 15));
    expect(reads, [_s1, _s1]);

    await tracker.listed(_s1, _section(user: {_done: _record(_done)}));
    expect(op(_done).state, DetachedOperationState.done);
    await clock.elapse(const Duration(minutes: 1));
    expect(reads, [_s1, _s1], reason: 'it showed, and nothing runs');

    // A wrapper that never records stops the re-reads after a minute.
    await tracker.launched(
      _s1,
      _running,
      directory: OpDirectoryKind.user,
      launch: launch,
    );
    reads.clear();
    for (var i = 0; i < 4; i++) {
      await tracker.listed(_s1, _section());
      await clock.elapse(const Duration(seconds: 15));
    }
    expect(reads, hasLength(4));
    await tracker.listed(_s1, _section());
    await clock.elapse(const Duration(minutes: 1));
    expect(reads, hasLength(4));
  });

  test("a launch a listing in flight misses keeps the note its result's "
      'audit needs', () async {
    await tracker.launched(
      _s1,
      _done,
      directory: OpDirectoryKind.user,
      launch: OperationLaunch(
        action: 'RedeployStack',
        targetName: 'web',
        steps: ['docker compose pull'],
        tier: ConfirmationTier.acknowledge,
        startedAt: DateTime.utc(2026, 10, 18, 9),
      ),
    );

    // An ops read that started before the launch landed: the directory
    // reads to its end without the record, which the launch grace covers
    // for lists but must also cover the note.
    await tracker.listed(_s1, _section());

    await tracker.listed(_s1, _section(user: {_done: _record(_done)}));
    await tracker.acknowledge(_s1, _done);
    final record = (await audit.query(_s1)).records.single;
    expect(record.action, 'RedeployStack');
    expect(record.targetName, 'web');
    expect(record.steps, ['docker compose pull']);
  });

  test('a launch the grace passes without showing forgets its note',
      () async {
    await tracker.launched(
      _s1,
      _done,
      directory: OpDirectoryKind.user,
      launch: OperationLaunch(
        action: 'RedeployStack',
        targetName: 'web',
        steps: const [],
        tier: ConfirmationTier.acknowledge,
        startedAt: DateTime.utc(2026, 10, 18, 9),
      ),
    );
    await clock.elapse(const Duration(minutes: 1));
    await tracker.listed(_s1, _section());
    expect(store.notesOf(_s1), isEmpty);
  });

  test('a lost result audits as interrupted', () async {
    link.answer = (c) => c.contains('klabautermann-ticks')
        ? const RemoteCommandResult(exitCode: 3)
        : null;
    await tracker.listed(
      _s1,
      _section(user: {_running: _record(_running, state: 'running')}),
    );
    await tracker.acknowledge(_s1, _running);
    final record = (await audit.query(_s1)).records.single;
    expect(record.failure, ActionFailure.interrupted);
    expect(record.exitCode, isNull);
  });

  test('a root result waits for admin mode to be deleted; admin mode '
      'deletes it and prunes the root directory once per session', () async {
    final section = _section(root: {_rootDone: _record(_rootDone)});
    await tracker.listed(_s1, section);
    await tracker.acknowledge(_s1, _rootDone);
    await pumpEventQueue();
    expect(op(_rootDone).acknowledged, isTrue);
    expect(link.containing("'rm'"), isEmpty);
    expect(store.notesOf(_s1)[_rootDone]?.acknowledged, isTrue);

    // The next listing still shows it waiting, and audits nothing again.
    await tracker.listed(_s1, section);
    expect(op(_rootDone).acknowledged, isTrue);
    expect((await audit.query(_s1)).records, hasLength(1));

    final admin = AdminSession.test(
      ElevatedExecutor(link, const ElevationProbe(isRoot: true)),
      null,
    );
    session = admin;
    await tracker.adminOn(_s1);
    expect(
      link.containing("'rm' '-f' '--' '$kRootOpsDir/$_rootDone.json'"),
      hasLength(1),
    );
    expect(
      link.containing("'klabautermann-prune' '$kRootOpsDir'"),
      hasLength(1),
    );
    expect(last().operations, isEmpty);
    expect(store.notesOf(_s1), isEmpty);

    await tracker.adminOn(_s1);
    expect(
      link.containing("'klabautermann-prune' '$kRootOpsDir'"),
      hasLength(1),
    );
  });

  test('notes of operations a complete listing no longer shows are '
      'dropped; a capped one keeps them', () async {
    await store.put(
      _s1,
      _done,
      const OperationNote(directory: OpDirectoryKind.user),
    );
    await store.put(
      _s1,
      _rootDone,
      const OperationNote(directory: OpDirectoryKind.root),
    );
    await tracker.listed(_s1, _section());
    expect(store.notesOf(_s1), isEmpty);
  });

  test("an operation's log is its file in the listed directory", () async {
    await tracker.listed(
      _s1,
      _section(
        user: {_done: _record(_done)},
        root: {_rootDone: _record(_rootDone)},
      ),
    );
    expect(tracker.logPath(_s1, _done), '$_userDir/$_done.log');
    expect(tracker.logPath(_s1, _rootDone), '$kRootOpsDir/$_rootDone.log');
    expect(tracker.logPath(_s1, _running), isNull);
    expect(tracker.logPath('srv-2', _done), isNull);
  });

  test('a collector that failed reports why, with no list', () async {
    await tracker.listed(
      _s1,
      HwsSection(
        'ops',
        SectionStatus.timeout,
        Uint8List.fromList(utf8.encode('stuck')),
      ),
    );
    expect(last().operations, isEmpty);
    expect(last().unavailable?.reason, CollectorUnavailableReason.timeout);
  });

  test('servers that leave the fleet lose their notes', () async {
    await store.put(
      _s1,
      _done,
      const OperationNote(directory: OpDirectoryKind.user),
    );
    tracker.retain({});
    await Future<void>.delayed(Duration.zero);
    expect(store.notesOf(_s1), isEmpty);
  });
}
