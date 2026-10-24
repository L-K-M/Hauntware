// The edit pipeline end to end on the Docker fixture (M5 plan M20a;
// SAF-12 to SAF-14, STK-07, JOB-07; 03 §8.5, §8.10, §8.11): the real
// engine in its own isolate, as the fixture user. A verified stack's
// compose file read over SFTP, checked by `compose config -q` and
// replaced in place, with the syslog line after it; a candidate compose
// refuses; a file changed between the read and the run, which stays as
// changed; the stack's `.env`; the user's crontab paused and resumed with
// its comments and environment kept; and the backups those edits made,
// verified on the next connect, one of them changed on the host, kept to
// the newest and removed. run.sh starts and seeds the fixture
// (seed_docker.sh); without it these skip.
//
// The tests run in order and share the fixture user's backups: each
// edit adds one, which the last test reads back. Every compose edit
// changes comments only, so `config --hash` and the stack's verdict
// stay as they were.
@Tags(['integration', 'docker'])
@Timeout(Duration(minutes: 6))
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        CrontabDocument,
        CrontabLineKind,
        FootprintKind,
        kCrontabPauseMarker,
        kEditTempInfix;
import 'package:test/test.dart';

import 'support/actions.dart';
import 'support/fixture.dart';

/// Where seed_docker.sh writes the `edits` stack.
const _stack = '/home/klab/stacks/edits';
const _compose = '$_stack/compose.yaml';
const _env = '$_stack/.env';

/// The comment seed_docker.sh writes into the compose file, which the
/// edits replace.
const _seededComment = '# klabautermann edit suite: seeded';

/// The device name the syslog line names.
const _device = 'edit-suite';

/// The crontab the suite installs for the fixture user: comments,
/// environment lines and two jobs.
const _crontab =
    '# klabautermann edit suite\n'
    'MAILTO=""\n'
    'SHELL=/bin/sh\n'
    '0 3 * * * /bin/true backup\n'
    '\n'
    '# poll every quarter hour\n'
    '*/15 * * * * /bin/true poll\n';

/// Covers a stack verdict on a busy runner.
const _listWait = Duration(seconds: 30);

/// Covers the footprint's reads after a connect or an edit.
const _footprintWait = Duration(seconds: 30);

void main() {
  final fixture = Fixture.fromEnvironment();
  if (fixture == null) {
    test('the edit pipeline suite', () {}, skip: fixtureSkipReason);
    return;
  }

  late Map<Endpoint, Set<String>> hostKeys;
  setUpAll(() async => hostKeys = await fixture.dockerHostKeys());

  var reads = 0;

  /// Runs [script] as root on the Docker host, out of the engine's sight.
  Future<String> host(String script) =>
      fixture.exec(FixtureService.dockerHost, ['sh', '-c', script]);

  Future<String> cat(String path) => host('cat -- "$path"');

  /// The klabautermann syslog lines from line [from] on, polled until
  /// one contains [line] because syslogd writes after logger returns.
  Future<String> syslogSince(int from, String line) async {
    var lines = '';
    for (var attempt = 0; attempt < 25; attempt++) {
      lines = await host(
        'tail -n +$from /var/log/messages | grep -F -- "klabautermann: " '
        '|| true',
      );
      if (lines.contains(line)) return lines;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return lines;
  }

  /// The temp files an edit left beside [path]'s file.
  Future<String> leftovers(String path) => host(
    'cd -- "\$(dirname -- "$path")" && '
    'ls -A | grep -F -- "$kEditTempInfix" || true',
  );

  /// An engine connected to the Docker host as the fixture user, with
  /// management on, the syslog line as [hostAuditLine] says, and the
  /// capability probe answered.
  Future<FixtureEngine> start(String name, {bool hostAuditLine = false}) async {
    final engine = await FixtureEngine.startDocker(fixture, name);
    manage(engine, [dockerServer], hostAuditLine: hostAuditLine);
    engine.send(const SetDeviceName(_device));
    await engine.connect(dockerServer, hostKeys);
    await engine.subscribe(dockerServer, {SampleStream.core});
    await engine.until<HostProfileChanged>(
      (e) => e.serverId == dockerServer && e.cachedAt == null,
    );
    return engine;
  }

  /// Waits until the stack list verifies the `edits` stack, so its files
  /// may be read and written.
  Future<void> verified(FixtureEngine engine) async {
    engine.send(
      const DockerWatch(
        serverId: dockerServer,
        watchId: 'edits',
        lists: {DockerWatchList.stacks},
      ),
    );
    await engine.until<DockerListChanged>(
      (e) =>
          e.serverId == dockerServer &&
          e.payload is DockerStacksPayload &&
          (e.payload as DockerStacksPayload).verdicts['edits'] is StackVerified,
      _listWait,
    );
  }

  /// Reads [target] for an edit; anything but content fails the test.
  Future<EditContent> read(FixtureEngine engine, EditTarget target) async {
    final requestId = 'edit-read-${reads++}';
    engine.send(
      ReadEditable(
        serverId: dockerServer,
        requestId: requestId,
        target: target,
      ),
    );
    final answer = await engine.until<EditRead>(
      (e) => e.requestId == requestId,
      actionWait,
    );
    expect(
      answer.result,
      isA<EditContent>(),
      reason: 'reading $target failed: ${answer.result}',
    );
    return answer.result as EditContent;
  }

  EditFile edit(EditTarget target, EditContent read, String text) => EditFile(
    dockerServer,
    target: target,
    text: text,
    baseSha256: read.sha256,
  );

  /// The first footprint whose backups [test] accepts, from those the
  /// engine already sent or the next ones.
  Future<FootprintState> footprint(
    FixtureEngine engine,
    bool Function(FootprintState state) test,
  ) async {
    for (final event in engine.seen.reversed) {
      if (event is FootprintState &&
          event.serverId == dockerServer &&
          test(event)) {
        return event;
      }
    }
    return engine.until<FootprintState>(
      (e) => e.serverId == dockerServer && test(e),
      _footprintWait,
    );
  }

  test('a stack\'s compose file is read over SFTP, checked by compose '
      'config -q, backed up and replaced in place, and the syslog names the '
      'edit (STK-07, SAF-12, SAF-13)', () async {
    final engine = await start('edit-compose', hostAuditLine: true);
    await verified(engine);
    const target = StackFileTarget(project: 'edits', path: _compose);
    final attributes = await host('stat -c "%u %g %a" -- "$_compose"');
    // Only this run's lines count; a reused fixture keeps earlier ones.
    final logged = await host('cat /var/log/messages 2>/dev/null | wc -l');
    final logFrom = int.parse(logged.trim()) + 1;

    final content = await read(engine, target);
    expect(content.text, await cat(_compose));
    expect(
      content.sha256,
      sha256.convert(utf8.encode(content.text)).toString(),
    );
    expect(content.privileged, isFalse);
    expect(content.text, contains(_seededComment));

    final edited = content.text.replaceFirst(
      _seededComment,
      '# klabautermann edit suite: edited',
    );
    final planned = await plan(engine, edit(target, content, edited));
    final preview = planned.preview;
    expect(preview.targetName, _compose);
    expect(
      preview.hostWrites,
      containsAll([
        HostWriteRow.editTarget,
        HostWriteRow.editTempFile,
        HostWriteRow.userBackups,
      ]),
    );
    final argvs = [
      for (final step in preview.steps)
        if (step is ShellStep) step.argv,
    ];
    expect(
      argvs,
      contains(
        allOf(
          containsAll(['config', '-q']),
          anyElement(contains(kEditTempInfix)),
        ),
      ),
      reason: 'the candidate is checked in the file\'s place',
    );
    expect(argvs.last.take(3), ['logger', '-t', 'klabautermann']);

    expectSucceeded(await run(engine, planned));
    expect(await cat(_compose), edited);
    expect(await host('stat -c "%u %g %a" -- "$_compose"'), attributes);
    expect(await leftovers(_compose), isEmpty);
    const auditLine = 'klabautermann: editFile $_compose by $_device';
    expect(await syslogSince(logFrom, auditLine), contains(auditLine));

    // A candidate compose cannot read fails its check and replaces
    // nothing.
    final current = await read(engine, target);
    final broken = await plan(
      engine,
      edit(target, current, '${current.text}services: [\n'),
    );
    final check = broken.preview.steps.indexWhere(
      (s) => s is ShellStep && s.argv.contains('config'),
    );
    final refused = await run(engine, broken);
    expect(
      refused,
      isA<ActionFinished>()
          .having((f) => f.outcome, 'outcome', ActionOutcome.failed)
          .having((f) => f.failedStep, 'failedStep', check),
      reason: _describe(refused),
    );
    expect(await cat(_compose), edited);
    expect(await leftovers(_compose), isEmpty);
  });

  test('a file changed between the read and the run stays as changed, '
      'and a plan from the old read is refused (SAF-12)', () async {
    final engine = await start('edit-conflict');
    await verified(engine);
    const target = StackFileTarget(project: 'edits', path: _compose);

    final content = await read(engine, target);
    final planned = await plan(
      engine,
      edit(target, content, '${content.text}# from the editor\n'),
    );
    await host('printf "# from elsewhere\\n" >> "$_compose"');

    final conflicted = await run(engine, planned);
    expect(
      conflicted,
      isA<ActionFinished>()
          .having((f) => f.outcome, 'outcome', ActionOutcome.failed)
          .having(
            (f) => f.revalidation,
            'revalidation',
            RevalidationFailure.contentChanged,
          ),
      reason: _describe(conflicted),
    );
    expect(await cat(_compose), '${content.text}# from elsewhere\n');
    expect(await leftovers(_compose), isEmpty);

    expect(
      await planAnswer(
        engine,
        edit(target, content, '${content.text}# from the editor\n'),
      ),
      isA<ActionRefused>().having(
        (r) => r.reason,
        'reason',
        ActionRefusalReason.targetChanged,
      ),
    );
  });

  test("a stack's .env is checked as the project's environment file and "
      'replaced (STK-07)', () async {
    final engine = await start('edit-env');
    await verified(engine);
    const target = StackFileTarget(project: 'edits', path: _env);

    final content = await read(engine, target);
    expect(content.text, contains('EDIT_NOTE=seeded'));
    final edited = content.text.replaceFirst(
      'EDIT_NOTE=seeded',
      'EDIT_NOTE=edited',
    );
    final planned = await plan(engine, edit(target, content, edited));
    expect(
      planned.preview.steps,
      contains(
        isA<ShellStep>().having(
          (s) => s.argv,
          'argv',
          allOf(
            containsAll(['config', '-q']),
            anyElement(contains(kEditTempInfix)),
          ),
        ),
      ),
    );

    expectSucceeded(await run(engine, planned));
    expect(await cat(_env), edited);
    expect(await leftovers(_env), isEmpty);
  });

  test("the user's crontab is paused and resumed through crontab -, its "
      'comments and environment kept (JOB-07, SAF-12)', () async {
    await host('printf %s \'$_crontab\' | crontab -u klab -');
    addTearDown(() => host('crontab -u klab -r || true'));
    final engine = await start('edit-crontab');
    const target = CrontabTarget();

    final content = await read(engine, target);
    expect(content.text, _crontab);
    expect(content.privileged, isFalse);

    final document = CrontabDocument.parse(content.text);
    final backup = document.lines.indexWhere(
      (l) => l.kind == CrontabLineKind.job && l.text.endsWith('backup'),
    );
    final paused = document
        .pause(backup, at: DateTime.utc(2026, 10, 21, 8, 30))
        .text;
    final pausing = await plan(engine, edit(target, content, paused));
    expect(pausing.preview.targetName, 'crontab:klab');
    expectSucceeded(await run(engine, pausing));

    final installed = await host('crontab -u klab -l');
    expect(installed, paused);
    expect(
      installed,
      contains('${kCrontabPauseMarker}2026-10-21T08:30:00Z 0 3 * * *'),
    );
    for (final kept in [
      '# klabautermann edit suite',
      'MAILTO=""',
      'SHELL=/bin/sh',
      '# poll every quarter hour',
      '*/15 * * * * /bin/true poll',
    ]) {
      expect(installed, contains(kept));
    }

    final again = await read(engine, target);
    expect(again.text, paused);
    final resumed = CrontabDocument.parse(again.text).resume(backup).text;
    expectSucceeded(
      await run(engine, await plan(engine, edit(target, again, resumed))),
    );
    expect(await host('crontab -u klab -l'), _crontab);
  });

  test('the next connect verifies the backups, reports one changed on the '
      'host, keeps the newest of each and removes a file\'s backups '
      '(SAF-14)', () async {
    final engine = await start('edit-footprint');
    final state = await footprint(engine, (s) => s.backups.isNotEmpty);

    expect(state.rootUnchecked, isTrue);
    expect(
      state.files.where((f) => f.scope == FootprintScope.user),
      containsAll([
        isA<FootprintFile>()
            .having((f) => f.row.kind, 'kind', FootprintKind.backupDirectory)
            .having((f) => f.present, 'present', isTrue),
        isA<FootprintFile>()
            .having((f) => f.row.kind, 'kind', FootprintKind.backupIndex)
            .having((f) => f.present, 'present', isTrue),
      ]),
    );
    final sources = state.backups.map((b) => b.entry.source).toSet();
    expect(sources, containsAll([_compose, _env, 'crontab:klab']));
    expect(
      state.backups.map((b) => b.status),
      everyElement(FootprintBackupStatus.intact),
    );

    // One compose backup changed on the host reads as modified.
    final directory = state.files
        .singleWhere(
          (f) =>
              f.scope == FootprintScope.user &&
              f.row.kind == FootprintKind.backupDirectory,
        )
        .row
        .path;
    final changed = state.backups
        .firstWhere((b) => b.entry.source == _compose)
        .entry;
    await host('printf "# tampered\\n" >> "$directory/${changed.name}"');
    engine.send(const FootprintQuery(dockerServer));
    final verified = await footprint(
      engine,
      (s) => s.backups.any(
        (b) => b.entry == changed && b.status == FootprintBackupStatus.modified,
      ),
    );
    expect(
      verified.backups.where((b) => b.entry != changed).map((b) => b.status),
      everyElement(FootprintBackupStatus.intact),
    );

    // Keep last 1: one backup per file stays.
    expectSucceeded(
      await run(
        engine,
        await plan(
          engine,
          const KeepLastBackups(
            dockerServer,
            scope: FootprintScope.user,
            count: 1,
          ),
        ),
      ),
    );
    final kept = await footprint(engine, (s) => _onePerSource(s.backups));
    expect(
      kept.backups.map((b) => b.entry.source).toSet(),
      containsAll([_compose, _env, 'crontab:klab']),
    );
    expect(await _names(host, directory), {
      for (final b in kept.backups) b.entry.name,
    });

    // Removing a file's backups needs its name typed.
    final removal = await plan(
      engine,
      const RemoveBackups(
        dockerServer,
        scope: FootprintScope.user,
        source: _compose,
      ),
    );
    expect(removal.preview.requiredTier, ConfirmationTier.typedPhrase);
    expect(removal.preview.targetName, _compose);
    expectSucceeded(await run(engine, removal));
    final removed = await footprint(
      engine,
      (s) =>
          s.backups.isNotEmpty &&
          s.backups.every((b) => b.entry.source != _compose),
    );
    expect(await _names(host, directory), {
      for (final b in removed.backups) b.entry.name,
    });
  });
}

/// How [event] ended, for a failed expectation's message.
String _describe(EngineEvent event) => switch (event) {
  ActionFinished(:final failure, :final failedStep, :final exitCode) =>
    'finished: $failure at step $failedStep, exit $exitCode',
  ActionRefused(:final reason) => 'refused: $reason',
  _ => '$event',
};

/// Whether [backups] hold at most one backup of each file.
bool _onePerSource(List<FootprintBackup> backups) {
  final sources = backups.map((b) => b.entry.source).toList();
  return sources.isNotEmpty && sources.length == sources.toSet().length;
}

/// The backup files in [directory]: every name but the index.
Future<Set<String>> _names(
  Future<String> Function(String script) host,
  String directory,
) async => {
  for (final name in const LineSplitter().convert(
    await host('ls -A -- "$directory"'),
  ))
    if (name != 'index') name,
};
