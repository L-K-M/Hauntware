// The engine samples end to end over a link whose commands run in local
// shells (03 §6.2, §6.4): dash and bash run the real sampler programs as
// the login shell and as the samplers' `sh`. This covers start, READY,
// the probe and its cache file, ticks through the sample pipeline, a
// SIGSTOP stall past the fast deadline with its restart, and the
// background pause, on this machine; it does not replace the SSH fixture
// tests (K24). Tagged `shell`; a shell that is not installed gets no
// tests.
@Tags(['shell'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/capabilities/capability_cache.dart';
import 'package:klabautermann_core/src/engine/engine_isolate.dart';
import 'package:klabautermann_core/src/fleet/ssh_config_import_store.dart'
    show sshConfigImportsFileName;
import 'package:test/test.dart';

import '../support/local_process_link.dart';

final _shells = {
  for (final name in ['dash', 'bash'])
    if (localShell(name) case final path?) name: path,
};

const _web = 'ssh-config:web';

/// The engine run in this isolate, its dial handing out one local link.
/// It is never sent [Shutdown], whose `Isolate.exit` would end the test
/// isolate.
final class _Engine {
  _Engine._(this._commands, this._events);

  final SendPort _commands;
  final StreamIterator<Object?> _events;

  /// Every event read so far.
  final seen = <EngineEvent>[];

  static Future<_Engine> start(String support, LocalProcessLink link) async {
    final port = ReceivePort();
    addTearDown(port.close);
    final events = StreamIterator<Object?>(port);
    engineMain(
      EngineStart(
        uiPort: port.sendPort,
        supportDirectory: support,
        linksEnabled: true,
        supportDirectoryAccess: SupportDirectoryAccess.exclusive,
      ),
      dial: ({
        required config,
        required credentials,
        required tofu,
        required onHostKey,
        onKeyboardInteractive,
        resolveJumpHost,
      }) async => link,
    );
    expect(await events.moveNext(), isTrue);
    final engine = _Engine._(events.current as SendPort, events)
      ..send(const Hello());
    await engine.until<CatalogReplaced>();
    return engine;
  }

  void send(EngineRequest request) => _commands.send(request);

  /// Reads events until one of type [T] that [test] accepts.
  Future<T> until<T extends EngineEvent>([bool Function(T event)? test]) async {
    while (true) {
      final arrived = await _events.moveNext().timeout(
        const Duration(seconds: 20),
      );
      expect(arrived, isTrue);
      final event = _events.current as EngineEvent;
      seen.add(event);
      if (event is T && (test?.call(event) ?? true)) return event;
    }
  }
}

void main() {
  for (final MapEntry(key: name, value: path) in _shells.entries) {
    test('$name: the engine probes and samples over the link, restarts a '
        'stalled fast sampler without losing the link, and pauses in the '
        'background', () async {
      final support = Directory.systemTemp.createTempSync('klab-sampling-');
      addTearDown(() => support.deleteSync(recursive: true));
      final link = await LocalProcessLink.create(path);
      addTearDown(link.dispose);
      final engine = await _Engine.start(support.path, link);
      engine.send(
        const ImportSshConfig('Host web\n  HostName 192.0.2.10\n  User me\n'),
      );
      await engine.until<SshConfigImported>();
      engine.send(const Connect(_web));
      await engine.until<LinkState>((e) => e.status == const LinkReady());

      engine.send(
        const Subscribe(
          serverId: _web,
          subscriptionId: 'overview',
          streams: {SampleStream.core, SampleStream.fs, SampleStream.identity},
        ),
      );
      await engine.until<SamplingState>(
        (e) => e.phase == SamplingPhase.sampling,
      );
      await engine.until<HostProfileChanged>();
      // The probe's answer is cached for the next run (D59).
      final cached = File(
        '${support.path}/$capabilityCacheDirectoryName/'
        '${capabilityCacheFileName(_web)}',
      );
      final written = Stopwatch()..start();
      while (!cached.existsSync()) {
        expect(written.elapsed, lessThan(const Duration(seconds: 5)));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final identity = await engine.until<Sample>(
        (s) => s.stream == SampleStream.identity,
      );
      expect(identity.result, isA<IdentityResult>());
      // The second core reading has a previous one, so rates; the
      // network's, since /proc/net/dev is never withheld (D50), also
      // when this machine is a container.
      final rated = await engine.until<Sample>(
        (s) =>
            s.result is CoreResult && (s.result as CoreResult).network != null,
      );
      expect(
        engine.seen.whereType<Sample>().map((s) => s.stream),
        containsAll([SampleStream.fs, SampleStream.core]),
      );

      // A refresh reads the subscription's streams at once, identity, read
      // once per link otherwise, included (PLT-02).
      engine.send(
        const RefreshSubscription(serverId: _web, subscriptionId: 'overview'),
      );
      final refreshed = await engine.until<Sample>(
        (s) => s.stream == SampleStream.identity,
      );
      expect(refreshed.seq, greaterThan(identity.seq));

      // A stopped fast sampler misses its 5 s deadline and restarts; the
      // link stays, since the restarted sampler answers.
      final fast = link.processes.singleWhere(
        (p) => p.written.contains('c_core()'),
      );
      expect(Process.killPid(fast.pid, ProcessSignal.sigstop), isTrue);
      final gap = await engine.until<Gap>(
        (g) => g.streams.contains(SampleStream.core),
      );
      expect(gap.cause, GapCause.readingLost);
      final resumed = await engine.until<Sample>(
        (s) => s.stream == SampleStream.core,
      );
      expect(resumed.seq, greaterThan(rated.seq));
      expect(
        link.processes.where((p) => p.written.contains('c_core()')),
        hasLength(2),
      );
      expect(
        engine.seen.whereType<LinkState>().map((e) => e.status),
        isNot(contains(isA<LinkClosed>())),
      );

      // The background ends every sampler process; the foreground starts
      // new ones on the same link.
      engine.send(const SetAppActivity(AppActivity.background));
      await engine.until<SamplingState>(
        (e) => e.phase == SamplingPhase.pausedInBackground,
      );
      await Future.wait([for (final p in link.processes) p.exit])
          .timeout(const Duration(seconds: 10));
      final started = link.processes.length;
      engine.send(const SetAppActivity(AppActivity.foreground));
      await engine.until<Gap>((g) => g.cause == GapCause.background);
      await engine.until<Sample>((s) => s.stream == SampleStream.core);
      expect(link.processes, hasLength(started + 2));

      // Unsubscribed, nothing runs.
      engine.send(
        const Unsubscribe(serverId: _web, subscriptionId: 'overview'),
      );
      await engine.until<SamplingState>(
        (e) => e.phase == SamplingPhase.unsubscribed,
      );
      await Future.wait([for (final p in link.processes) p.exit])
          .timeout(const Duration(seconds: 10));
    });
  }

  if (_shells.values.firstOrNull case final path?) {
    test('after an import the store could not save, a probe answer is not '
        'cached, since the next start reads the older fleet (D59)', () async {
      final support = Directory.systemTemp.createTempSync('klab-sampling-');
      addTearDown(() => support.deleteSync(recursive: true));
      final link = await LocalProcessLink.create(path);
      addTearDown(link.dispose);
      final engine = await _Engine.start(support.path, link);
      // A directory with an entry cannot be replaced by the saved file.
      Directory('${support.path}/$sshConfigImportsFileName/entry')
          .createSync(recursive: true);

      engine.send(
        const ImportSshConfig('Host web\n  HostName 192.0.2.10\n  User me\n'),
      );
      expect((await engine.until<SshConfigImported>()).saved, isFalse);
      engine
        ..send(const Connect(_web))
        ..send(
          const Subscribe(
            serverId: _web,
            subscriptionId: 'overview',
            streams: {SampleStream.core},
          ),
        );
      await engine.until<HostProfileChanged>();
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(
        Directory('${support.path}/$capabilityCacheDirectoryName').existsSync(),
        isFalse,
      );
      engine.send(
        const Unsubscribe(serverId: _web, subscriptionId: 'overview'),
      );
      await engine.until<SamplingState>(
        (e) => e.phase == SamplingPhase.unsubscribed,
      );
      await Future.wait([for (final p in link.processes) p.exit])
          .timeout(const Duration(seconds: 10));
    });
  }

  test('at least one shell is installed', () {
    expect(_shells, isNotEmpty, reason: 'install dash or bash to run this');
  });
}
