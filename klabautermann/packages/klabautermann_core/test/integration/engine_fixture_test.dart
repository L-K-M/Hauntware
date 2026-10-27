// The engine against the sshd fixture (03 §11.3, D53; 04 §13 M2 exit):
// sampler start and ticks, timeout recovery, reconnect with the sample
// seq continuing, dead-peer detection, ProxyJump, and agent and
// IdentityFile sign-in, over real SSH with the engine in its own isolate.
// run.sh starts the fixture and runs these one at a time; without it they
// skip. The restart and pause tests change the shared host, so they run
// last, and each leaves it running.
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

/// Covers a slow `fs` reading: its 30 s desktop period plus the request
/// deadline of its two guarded `df` runs (D47).
const _slowReadingWait = Duration(seconds: 90);

/// Covers a dead-peer close: a missed 5 s fast deadline, the restart
/// delay and the 20 s grace, or the link's own 15 s idle check and 30 s
/// ping deadline, whichever comes first (03 §5.1, §6.2).
const _deadPeerWait = Duration(seconds: 90);

/// Covers a redial after the host returns: backoff and a connect whose
/// handshake waited on the paused host.
// A Docker host restart plus a redial has passed 90 s on a loaded CI
// runner (run 120054453500); the bound fails real deadlocks only.
const _redialWait = Duration(seconds: 180);

const _flag = '/run/klabautermann-fixture/slow-df';

void main() {
  final fixture = Fixture.fromEnvironment();
  if (fixture == null) {
    test('the sshd fixture suite', () {}, skip: fixtureSkipReason);
    return;
  }

  late Map<Endpoint, Set<String>> hostKeys;
  setUpAll(() async => hostKeys = await fixture.hostKeys());

  /// The sampled host's log lines that accept a key for the fixture user,
  /// from the [from]th line on.
  Future<List<String>> acceptedKeys(int from) async => [
    for (final line in (await fixture.logs(FixtureService.sshd)).skip(from))
      if (line.startsWith('Accepted publickey for klab ')) line,
  ];

  /// Connects [directServer] and waits for a `core` reading with rates,
  /// which only a second tick has.
  Future<Sample> sampleDirect(FixtureEngine engine) async {
    await engine.connect(directServer, hostKeys);
    await engine.subscribe(directServer, {SampleStream.core});
    return engine.sample(
      directServer,
      SampleStream.core,
      test: (sample) => (sample.result as CoreResult).network != null,
    );
  }

  test('an IdentityFile host connects, probes and ticks', () async {
    final engine = await FixtureEngine.start(fixture, 'identity file');
    final logged = (await fixture.logs(FixtureService.sshd)).length;

    expect(await engine.connect(directServer, hostKeys), [fixture.direct]);
    await engine.subscribe(directServer, {
      SampleStream.core,
      SampleStream.fs,
      SampleStream.identity,
    });

    final profile = await engine.until<HostProfileChanged>();
    expect(profile.serverId, directServer);
    // Rates need a second core tick, by which time the slow sampler's
    // first tick has read identity and fs.
    await engine.sample(
      directServer,
      SampleStream.core,
      test: (sample) => (sample.result as CoreResult).network != null,
    );
    final identity = await engine.firstSample(
      directServer,
      SampleStream.identity,
    );
    expect(
      identity.result,
      isA<IdentityResult>()
          .having((r) => r.osPrettyName, 'osPrettyName', contains('Alpine'))
          .having((r) => r.kernelName, 'kernelName', 'Linux'),
    );
    final fs = await engine.firstSample(directServer, SampleStream.fs);
    expect((fs.result as FsResult).fs.mounts, isNotEmpty);

    final seqs = [
      for (final event in engine.seen)
        if (event is Sample) event.seq,
    ];
    expect(seqs, orderedEquals([...seqs]..sort()));
    expect(seqs.toSet(), hasLength(seqs.length));

    // sshd accepted the file's key, and the engine audited the read.
    expect(await acceptedKeys(logged), [contains(fixture.identityFingerprint)]);
    final audit = await File(
      '${engine.supportDirectory}/identity_reads.jsonl',
    ).readAsLines();
    expect(audit, isNotEmpty);
    for (final line in audit) {
      expect(jsonDecode(line), containsPair('ok', true));
      expect(jsonDecode(line), containsPair('path', fixture.identityFile));
    }
  });

  test('a host without an IdentityFile signs in with the agent', () async {
    final engine = await FixtureEngine.start(fixture, 'agent');
    final fleet = engine.seen.whereType<CatalogReplaced>().last.entries;
    expect(
      fleet.singleWhere((e) => e.serverId == agentServer).authKind,
      FleetAuthKind.agent,
    );
    final logged = (await fixture.logs(FixtureService.sshd)).length;

    await engine.connect(agentServer, hostKeys);
    await engine.subscribe(agentServer, {SampleStream.core});
    await engine.sample(agentServer, SampleStream.core);

    // Only the agent holds this key: run.sh deleted its file.
    expect(await acceptedKeys(logged), [contains(fixture.agentFingerprint)]);
  });

  test('a ProxyJump host connects and samples through the jump host', () async {
    final engine = await FixtureEngine.start(fixture, 'proxy jump');
    final fleet = engine.seen.whereType<CatalogReplaced>().last.entries;
    expect(fleet.singleWhere((e) => e.serverId == behindServer).jumpRoute, [
      'hop',
    ]);

    // The jump host's key is checked first. The host behind it is known
    // by its service name, which only the jump host resolves.
    expect(await engine.connect(behindServer, hostKeys), [
      fixture.jumpHost,
      fixture.behind,
    ]);
    await engine.subscribe(behindServer, {
      SampleStream.core,
      SampleStream.identity,
    });
    await engine.sample(behindServer, SampleStream.core);
    final identity = await engine.firstSample(
      behindServer,
      SampleStream.identity,
    );
    expect(
      (identity.result as IdentityResult).osPrettyName,
      contains('Alpine'),
    );
  });

  test('a stopped fast sampler misses its deadline and restarts on the same '
      'link', () async {
    final engine = await FixtureEngine.start(fixture, 'fast sampler stop');
    final before = await sampleDirect(engine);

    // Samplers of an earlier test's link may still be ending.
    var samplers = await fixture.samplerPids();
    for (var i = 0; samplers.length != 2 && i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      samplers = await fixture.samplerPids();
    }
    expect(samplers, hasLength(2), reason: 'one slow and one fast sampler');
    final fast = samplers.last;
    final mark = engine.seen.length;
    engine.note('! SIGSTOP fast sampler $fast');
    await fixture.exec(FixtureService.sshd, ['kill', '-STOP', '$fast']);
    // A stopped shell cannot see its closed channel; once continued, it
    // reads end of input and exits.
    addTearDown(
      () => fixture.exec(FixtureService.sshd, ['kill', '-CONT', '$fast']),
    );

    final gap = await engine.until<Gap>(
      (gap) => gap.streams.contains(SampleStream.core),
    );
    expect(gap.cause, GapCause.readingLost);
    final after = await engine.sample(directServer, SampleStream.core);
    expect(after.seq, greaterThan(before.seq));
    expect(engine.statusesSince(directServer, mark), isEmpty);
    expect(await fixture.samplerPids(), contains(greaterThan(fast)));
  });

  test('a hung df is stopped by its timeout guard, and the next reading '
      'recovers', () async {
    final engine = await FixtureEngine.start(fixture, 'slow df');
    await engine.connect(directServer, hostKeys);
    await engine.subscribe(directServer, {SampleStream.fs});
    await engine.sample(
      directServer,
      SampleStream.fs,
      test: (sample) => sample.result is FsResult,
    );
    final mark = engine.seen.length;

    engine.note('! df hangs');
    await fixture.exec(FixtureService.sshd, ['touch', _flag]);
    addTearDown(() => fixture.exec(FixtureService.sshd, ['rm', '-f', _flag]));
    final hung = await engine.sample(
      directServer,
      SampleStream.fs,
      test: (sample) => sample.result is CollectorUnavailable,
      timeout: _slowReadingWait,
    );
    expect(
      (hung.result as CollectorUnavailable).reason,
      CollectorUnavailableReason.timeout,
    );

    engine.note('! df answers');
    await fixture.exec(FixtureService.sshd, ['rm', '-f', _flag]);
    await engine.sample(
      directServer,
      SampleStream.fs,
      test: (sample) => sample.result is FsResult,
      timeout: _slowReadingWait,
    );
    // The guard answered within the request's deadline: no lost reading,
    // no restart, no reconnect.
    expect(engine.seen.skip(mark).whereType<Gap>(), isEmpty);
    expect(engine.statusesSince(directServer, mark), isEmpty);
  });

  test('a restarted host reconnects, and the sample seq continues', () async {
    final engine = await FixtureEngine.start(fixture, 'restart');
    final before = await sampleDirect(engine);
    final mark = engine.seen.length;

    engine.note('! compose restart sshd');
    await fixture.compose(['restart', FixtureService.sshd.name]);

    // The redial is unattended, so it needs the pinned key, which the
    // restarted host still has.
    await engine.until<LinkState>(
      (e) => e.serverId == directServer && e.status is LinkClosed,
    );
    await engine.until<LinkState>(
      (e) => e.serverId == directServer && e.status == const LinkReady(),
      _redialWait,
    );
    final gap = await engine.until<Gap>(
      (gap) => gap.streams.contains(SampleStream.core),
    );
    expect(gap.cause, GapCause.disconnected);
    final after = await engine.sample(directServer, SampleStream.core);
    expect(after.seq, greaterThan(before.seq));
    expect(
      engine.statusesSince(directServer, mark),
      isNot(contains(isA<LinkNeedsUser>())),
    );
  });

  test('a paused host is closed as a dead peer and redialed once it '
      'resumes', () async {
    final engine = await FixtureEngine.start(fixture, 'pause');
    final before = await sampleDirect(engine);

    engine.note('! compose pause sshd');
    await fixture.compose(['pause', FixtureService.sshd.name]);
    var paused = true;
    addTearDown(() async {
      if (paused) await fixture.compose(['unpause', FixtureService.sshd.name]);
    });

    final closed = await engine.until<LinkState>(
      (e) => e.serverId == directServer && e.status is LinkClosed,
      _deadPeerWait,
    );
    expect(closed.status, const LinkClosed(LinkClosedReason.pingTimeout));

    engine.note('! compose unpause sshd');
    await fixture.compose(['unpause', FixtureService.sshd.name]);
    paused = false;
    await engine.until<LinkState>(
      (e) => e.serverId == directServer && e.status == const LinkReady(),
      _redialWait,
    );
    final after = await engine.sample(directServer, SampleStream.core);
    expect(after.seq, greaterThan(before.seq));
  });
}
