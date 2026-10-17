// The fixture helpers without the fixture: when the engine suites run,
// where an engine keeps its files, and how a wait that timed out leaves
// the engine's events.
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:test/test.dart';

import 'fixture.dart';

/// The variables run.sh exports for the suites, but its runtime directory,
/// for a fixture that is not running: nothing here dials it.
const _offline = {
  'KLABAUTERMANN_FIXTURE_COMPOSE_FILE': '/nonexistent/docker-compose.yml',
  'KLABAUTERMANN_FIXTURE_COMPOSE_PROJECT': 'klabautermann-offline',
  'KLABAUTERMANN_FIXTURE_HOST': '127.0.0.1',
  'KLABAUTERMANN_FIXTURE_PORT': '1',
  'KLABAUTERMANN_FIXTURE_JUMP_PORT': '2',
  'KLABAUTERMANN_FIXTURE_USER': 'klab',
  'KLABAUTERMANN_FIXTURE_IDENTITY_FILE': '/nonexistent/identity',
  'KLABAUTERMANN_FIXTURE_IDENTITY_FINGERPRINT': 'SHA256:identity',
  'KLABAUTERMANN_FIXTURE_AGENT_FINGERPRINT': 'SHA256:agent',
};

void main() {
  late Directory runtime;

  setUp(() async {
    runtime = await Directory.systemTemp.createTemp('klab-runtime-');
    addTearDown(() => runtime.delete(recursive: true));
  });

  Fixture offline() => Fixture.fromEnvironment({
    ..._offline,
    'KLABAUTERMANN_FIXTURE_RUNTIME': runtime.path,
  })!;

  test('without run.sh there is no fixture, and the suites skip', () {
    expect(Fixture.fromEnvironment({'PATH': '/usr/bin'}), isNull);
  });

  test('a run.sh that exported only some variables fails the suites', () {
    // The suites would skip, and the job pass with no engine test run,
    // if a renamed variable read as no fixture.
    final partial = {..._offline}..remove('KLABAUTERMANN_FIXTURE_COMPOSE_FILE');
    final fixture = Fixture.fromEnvironment(partial);
    expect(fixture, isNotNull);
    expect(() => fixture!.compose(['ps']), throwsStateError);
  });

  test('an engine keeps its files in run.sh\'s runtime directory', () async {
    // run.sh removes it on every exit, also when a second signal ends the
    // suites before their teardowns run.
    final engine = await FixtureEngine.start(offline(), 'runtime files');

    expect(engine.supportDirectory, startsWith('${runtime.path}/'));
  });

  test('a timed-out wait leaves its read to the next one', () async {
    final engine = await FixtureEngine.start(offline(), 'timed out wait');
    await expectLater(
      engine.until<Gap>(null, const Duration(milliseconds: 200)),
      throwsA(isA<TestFailure>()),
    );

    // A StreamIterator takes one read at a time. A second moveNext would
    // throw, and the teardown's wait for each link to close would end at
    // once, leaving the link open on the shared fixture.
    engine.send(const ImportSshConfig('Host spare\n  HostName 127.0.0.1\n'));
    expect(await engine.until<SshConfigImported>(), isA<SshConfigImported>());
  });
}
