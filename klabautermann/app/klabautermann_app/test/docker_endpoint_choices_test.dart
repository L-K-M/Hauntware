// DockerEndpointChoices (M3 D20): a choice whose save failed is saved
// again when it is chosen again, and only then.
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/docker_endpoint_choices.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

/// One synced fleet entry; its endpoint key is `@host:port`, as
/// [FleetServer.fromEntry] builds it.
FleetEntry _entry(String id, String host, {int port = 22}) => FleetEntry(
  serverId: id,
  label: id,
  host: host,
  port: port,
  origin: FleetEntryOrigin.synced,
);

void main() {
  test('choosing a choice whose save failed saves it again', () async {
    final saves = <DockerEndpointOverride?>[];
    var fail = true;
    final choices = DockerEndpointChoices(
      save: (_, override) async {
        saves.add(override);
        if (fail) throw StateError('read-only');
      },
    );
    addTearDown(choices.dispose);
    const socket = DockerEndpointDetected('/run/docker.sock');

    await expectLater(choices.choose('srv', socket), throwsStateError);
    expect(choices.choiceFor('srv'), socket);

    fail = false;
    await choices.choose('srv', socket);
    expect(saves, hasLength(2));

    await choices.choose('srv', socket);
    expect(saves, hasLength(2), reason: 'a saved choice changes nothing');
  });

  test('an incomplete startup fleet keeps a missing server\'s choice '
      'and its stored copy', () async {
    final purged = <Map<String, String>>[];
    final choices = DockerEndpointChoices(
      stored: const {
        'srv-1': DockerEndpointOverride(
          null,
          endpoint: '@h1:22',
          program: '/usr/bin/docker',
        ),
        'srv-2': DockerEndpointOverride(
          DockerEndpointCustom('/run/docker.sock'),
          endpoint: '@h2:22',
          program: '/srv/bin/docker',
        ),
      },
      purge: (endpoints) async {
        purged.add(endpoints);
        return const <String>{};
      },
      fleetComplete: false,
    );
    addTearDown(choices.dispose);
    final engine = FakeEngineClient();
    addTearDown(engine.close);
    final fleet = FleetController(engine);
    addTearDown(fleet.dispose);
    choices.followFleet(fleet);

    // Another instance holds the support directory or an import store is
    // unreadable, so srv-2's absence is not proof that it is gone.
    engine.emit(CatalogReplaced([_entry('srv-1', 'h1')]));
    await pumpEventQueue();

    expect(
      choices.choiceFor('srv-2'),
      const DockerEndpointCustom('/run/docker.sock'),
    );
    expect(choices.programFor('srv-2'), '/srv/bin/docker');
    // The store keeps an entry whose key is present with its own endpoint.
    expect(purged.single['srv-2'], '@h2:22');
  });

  test('an incomplete startup fleet still drops a choice whose endpoint '
      'changed', () async {
    final purged = <Map<String, String>>[];
    final choices = DockerEndpointChoices(
      stored: const {
        'srv-1': DockerEndpointOverride(
          null,
          endpoint: '@h1:22',
          program: '/usr/bin/docker',
        ),
      },
      purge: (endpoints) async {
        purged.add(endpoints);
        return const <String>{};
      },
      fleetComplete: false,
    );
    addTearDown(choices.dispose);
    final engine = FakeEngineClient();
    addTearDown(engine.close);
    final fleet = FleetController(engine);
    addTearDown(fleet.dispose);
    choices.followFleet(fleet);

    engine.emit(CatalogReplaced([_entry('srv-1', 'h1', port: 2222)]));
    await pumpEventQueue();

    expect(choices.choiceFor('srv-1'), const DockerEndpointAuto());
    expect(choices.programFor('srv-1'), isNull);
    expect(purged.single['srv-1'], isNot('@h1:22'));
  });

  test('a server a fleet listed and a later fleet dropped is purged even '
      'when the startup was incomplete', () async {
    final purged = <Map<String, String>>[];
    final choices = DockerEndpointChoices(
      stored: const {
        'srv-1': DockerEndpointOverride(
          null,
          endpoint: '@h1:22',
          program: '/usr/bin/docker',
        ),
        'srv-2': DockerEndpointOverride(
          null,
          endpoint: '@h2:22',
          program: '/usr/bin/docker',
        ),
      },
      purge: (endpoints) async {
        purged.add(endpoints);
        return const <String>{};
      },
      fleetComplete: false,
    );
    addTearDown(choices.dispose);
    final engine = FakeEngineClient();
    addTearDown(engine.close);
    final fleet = FleetController(engine);
    addTearDown(fleet.dispose);
    choices.followFleet(fleet);

    engine.emit(
      CatalogReplaced([_entry('srv-1', 'h1'), _entry('srv-2', 'h2')]),
    );
    await pumpEventQueue();
    engine.emit(CatalogReplaced([_entry('srv-1', 'h1')]));
    await pumpEventQueue();

    expect(choices.choiceFor('srv-2'), const DockerEndpointAuto());
    expect(choices.programFor('srv-2'), isNull);
    expect(purged.last.containsKey('srv-2'), isFalse);
  });

  test('a complete fleet drops a choice whose server left', () async {
    final purged = <Map<String, String>>[];
    final choices = DockerEndpointChoices(
      stored: const {
        'srv-1': DockerEndpointOverride(
          null,
          endpoint: '@h1:22',
          program: '/usr/bin/docker',
        ),
      },
      purge: (endpoints) async {
        purged.add(endpoints);
        return const <String>{};
      },
    );
    addTearDown(choices.dispose);
    final engine = FakeEngineClient();
    addTearDown(engine.close);
    final fleet = FleetController(engine);
    addTearDown(fleet.dispose);
    choices.followFleet(fleet);

    engine.emit(CatalogReplaced([_entry('srv-2', 'h2')]));
    await pumpEventQueue();

    expect(choices.choiceFor('srv-1'), const DockerEndpointAuto());
    expect(choices.programFor('srv-1'), isNull);
    expect(purged.single.containsKey('srv-1'), isFalse);
  });

  test('a program and a socket choice keep each other, and clearing both '
      'removes the entry (CN-16)', () async {
    final saves = <DockerEndpointOverride?>[];
    final choices = DockerEndpointChoices(
      save: (_, override) async => saves.add(override),
    );
    addTearDown(choices.dispose);
    const socket = DockerEndpointCustom('/srv/engine.sock');
    const snap = '/snap/bin/docker';

    await choices.chooseProgram('srv', snap);
    await choices.choose('srv', socket);
    expect(saves.last?.choice, socket);
    expect(saves.last?.program, snap);

    await choices.choose('srv', const DockerEndpointAuto());
    expect(saves.last?.choice, isNull);
    expect(saves.last?.program, snap);

    await choices.chooseProgram('srv', null);
    expect(saves.last, isNull);
    expect(choices.programFor('srv'), isNull);
  });
}
