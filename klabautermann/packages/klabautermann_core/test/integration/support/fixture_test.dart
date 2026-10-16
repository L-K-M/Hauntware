// The fixture helpers without the fixture: when the engine suites run.
import 'package:test/test.dart';

import 'fixture.dart';

/// Every variable run.sh exports for the suites, for a fixture that is
/// not running: nothing here dials it.
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
}
