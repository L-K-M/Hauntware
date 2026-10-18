// The device audit log (03 §8.10, M4 plan M12): append-only per server,
// redacted steps, newest-first queries, the 90-day prune, a damaged file
// quarantined, and memory only without the support directory to itself.
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/audit/audit_log.dart';
import 'package:klabautermann_core/src/fleet/server_file_stem.dart';
import 'package:klabautermann_core/src/operations/confirmation.dart';
import 'package:klabautermann_core/src/operations/operation_plan.dart';
import 'package:test/test.dart';

const _server = 'ssh-config:web';

void main() {
  late Directory root;
  late DateTime now;

  setUp(() {
    root = Directory.systemTemp.createTempSync('klab-audit-');
    addTearDown(() => root.deleteSync(recursive: true));
    now = DateTime.utc(2026, 10, 18, 12);
  });

  AuditLog log({AuditStorage storage = AuditStorage.files}) => AuditLog(
    Directory('${root.path}/$auditDirectoryName'),
    storage: storage,
    deviceId: 'device-1',
    now: () => now,
  );

  AuditRecord record(DateTime endedAt, {String serverId = _server}) =>
      AuditRecord(
        serverId: serverId,
        action: 'UnitAction',
        targetName: 'nginx.service',
        steps: const ['systemctl restart nginx.service'],
        tier: ConfirmationTier.acknowledge,
        outcome: ActionOutcome.succeeded,
        startedAt: endedAt.subtract(const Duration(seconds: 2)),
        endedAt: endedAt,
      );

  File fileOf(String serverId) => File(
    '${root.path}/$auditDirectoryName/${serverFileStem(serverId)}.jsonl',
  );

  test('appends per server and answers newest first', () async {
    final audit = log();
    for (var i = 0; i < 5; i++) {
      await audit.append(record(now.add(Duration(minutes: i))));
    }
    await audit.append(
      record(now, serverId: '0b3e7a4c-2f1d-4c5e-9a8b-7c6d5e4f3a2b'),
    );

    final page = await audit.query(_server, limit: 2);
    expect(
      [for (final r in page.records) r.endedAt],
      [
        now.add(const Duration(minutes: 4)),
        now.add(const Duration(minutes: 3)),
      ],
    );
    expect(page.more, isTrue);
    final older = await audit.query(
      _server,
      before: now.add(const Duration(minutes: 3)),
    );
    expect(older.records, hasLength(3));
    expect(older.more, isFalse);
    expect(
      (await audit.query('0b3e7a4c-2f1d-4c5e-9a8b-7c6d5e4f3a2b')).records,
      hasLength(1),
    );
    expect(fileOf(_server).readAsLinesSync(), hasLength(5));
  });

  test('records a run with its steps redacted and its typed result', () async {
    final audit = log();
    final plan = OperationPlan(
      intent: const UnitAction(
        _server,
        unit: 'app.service',
        verb: SystemctlVerb.restart,
      ),
      kind: OperationKind.restart,
      targetName: 'app.service',
      steps: [
        ShellStep(['env', 'API_TOKEN=ghp_secretsecretsecret', 'true']),
      ],
      requiredLevel: RequiredLevel.login,
      runner: const RunnerFacts(identity: 'deploy'),
    );
    await audit.recordRun((
      planId: 'plan-1',
      plan: plan,
      finished: const ActionFinished(
        planId: 'plan-1',
        outcome: ActionOutcome.failed,
        failure: ActionFailure.stepFailed,
        failedStep: 0,
        exitCode: 3,
      ),
      startedAt: now,
      endedAt: now.add(const Duration(seconds: 1)),
    ));

    final stored = fileOf(_server).readAsStringSync();
    expect(stored, isNot(contains('ghp_secretsecretsecret')));
    final read = (await audit.query(_server)).records.single;
    expect(read.action, 'UnitAction');
    expect(read.steps.single, contains('«redacted»'));
    expect(read.outcome, ActionOutcome.failed);
    expect(read.failure, ActionFailure.stepFailed);
    expect(read.exitCode, 3);
    expect(read.deviceId, 'device-1');
  });

  test('prunes records older than 90 days at start', () async {
    final audit = log();
    await audit.append(record(now.subtract(const Duration(days: 91))));
    await audit.append(record(now.subtract(const Duration(days: 89))));
    await audit.prune();

    final kept = (await audit.query(_server)).records;
    expect(kept, hasLength(1));
    expect(kept.single.endedAt, now.subtract(const Duration(days: 89)));
  });

  test('quarantines a damaged file and keeps its readable lines', () async {
    final audit = log();
    await audit.append(record(now));
    fileOf(_server).writeAsStringSync('{"v":1,"half', mode: FileMode.append);
    fileOf(_server).writeAsStringSync('\n', mode: FileMode.append);
    await audit.append(record(now.add(const Duration(minutes: 1))));

    expect((await audit.query(_server)).records, hasLength(2));
    final copies = Directory(
      '${root.path}/$auditDirectoryName',
    ).listSync().where((e) => e.path.contains('.corrupt-'));
    expect(copies, hasLength(1));
    expect(fileOf(_server).readAsLinesSync(), hasLength(2));
  });

  test('concurrent appends keep whole lines', () async {
    final audit = log();
    await Future.wait([
      for (var i = 0; i < 50; i++)
        audit.append(record(now.add(Duration(seconds: i)))),
    ]);
    expect((await audit.query(_server, limit: 100)).records, hasLength(50));
  });

  test('without the support directory to itself it writes no file', () async {
    final audit = log(storage: AuditStorage.memory);
    await audit.append(record(now));
    await audit.prune();

    expect((await audit.query(_server)).records, hasLength(1));
    expect(Directory('${root.path}/$auditDirectoryName').existsSync(), isFalse);
  });

  test(
    'names files as 03 §4.10 does, and keeps an unnamed id in memory',
    () async {
      final audit = log();
      await audit.append(record(now));
      await audit.append(record(now, serverId: 'not/a:file'));

      final names = [
        for (final e in Directory(
          '${root.path}/$auditDirectoryName',
        ).listSync())
          e.uri.pathSegments.last,
      ];
      expect(names, [matches(RegExp(r'^ssh-config-[0-9a-f]{64}\.jsonl$'))]);
      expect((await audit.query('not/a:file')).records, hasLength(1));
    },
  );
}
