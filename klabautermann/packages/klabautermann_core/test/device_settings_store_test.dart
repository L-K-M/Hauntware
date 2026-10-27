import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:test/test.dart';

const _versionKey = 'klabautermann.settings.version';
const _deviceIdKey = 'klabautermann.sync.deviceId';
const _appearanceKey = 'klabautermann.appearance';
const _firstRunCardKey = 'klabautermann.coverage.firstRunCardDismissed';
const _rootNoticeKey = 'klabautermann.docker.rootEquivalenceNoticeDismissed';
const _announceBandsKey = 'klabautermann.accessibility.announceThresholdBands';
const _alertNotificationsKey = 'klabautermann.alerts.notifications';
const _appLockKey = 'klabautermann.appLock';
const _syncSecretsKey = 'klabautermann.sync.secrets';
const _deviceNameKey = 'klabautermann.audit.deviceName';
const _cadenceKey = 'klabautermann.sampling.cadence';
const _cadenceCapsKey = 'klabautermann.sampling.caps';
const _overridesKey = 'klabautermann.docker.endpointOverrides';
const _pinnedServersKey = 'klabautermann.fleet.pinnedServerIds';
const _monitorSetKey = 'klabautermann.monitorSet';
const _containerColumnsKey = 'klabautermann.docker.containerColumns';
const _safetyKey = 'klabautermann.safety';
const _attentionKey = 'klabautermann.attention.acknowledged';

final _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// A fixed clock, so the copy of a damaged file has a known name.
final _time = DateTime.utc(2026, 10, 13, 23, 5, 29, 123, 456);
const _stamp = '20261013T230529123456Z';

const _darkAppearance = <String, Object?>{
  'palette': {'name': 'Klabautermann'},
  'mode': 'dark',
};

void main() {
  late Directory directory;
  late File file;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('klab-settings-');
    file = File('${directory.path}/$deviceSettingsFileName');
  });

  tearDown(() => directory.deleteSync(recursive: true));

  Map<String, Object?> document() =>
      jsonDecode(file.readAsStringSync()) as Map<String, Object?>;

  List<String> entries() =>
      directory
          .listSync()
          .map((entity) => entity.uri.pathSegments.lastWhere((s) => s != ''))
          .toList()
        ..sort();

  void writeDocument(Map<String, Object?> json) =>
      file.writeAsStringSync(jsonEncode(json));

  group('DeviceSettingsStore', () {
    test('a first launch mints a UUID v4 device id and saves it', () async {
      final store = await DeviceSettingsStore.open(file);

      expect(store.issue, isNull);
      expect(store.deviceId, matches(_uuidV4));
      expect(store.appearance, isNull);
      expect(document(), {
        _versionKey: deviceSettingsSchemaVersion,
        _deviceIdKey: store.deviceId,
      });
      expect(entries(), [deviceSettingsFileName], reason: 'no temp file left');
    });

    test('the device id survives reloads and is never rewritten', () async {
      final first = await DeviceSettingsStore.open(file);
      final bytes = file.readAsBytesSync();

      var writes = 0;
      Future<void> countingWriter(File target, List<int> contents) {
        writes++;
        return writeFileAtomically(target, contents);
      }

      for (var launch = 0; launch < 3; launch++) {
        final reopened = await DeviceSettingsStore.open(
          file,
          writer: countingWriter,
        );
        expect(reopened.deviceId, first.deviceId);
        expect(reopened.issue, isNull);
      }
      expect(writes, 0, reason: 'opening a valid file writes nothing');
      expect(file.readAsBytesSync(), bytes);
    });

    test(
      'round-trips the appearance and keeps keys it does not know',
      () async {
        writeDocument({
          _versionKey: 1,
          _deviceIdKey: 'device-a',
          'klabautermann.monitor.set': ['srv-1'],
          'klabautermann.later': {'nested': true},
        });

        final store = await DeviceSettingsStore.open(file);
        await store.setAppearance(_darkAppearance);
        final reopened = await DeviceSettingsStore.open(file);

        expect(reopened.issue, isNull);
        expect(reopened.deviceId, 'device-a');
        expect(reopened.appearance, _darkAppearance);
        expect(document(), {
          _versionKey: 1,
          _deviceIdKey: 'device-a',
          'klabautermann.monitor.set': ['srv-1'],
          'klabautermann.later': {'nested': true},
          _appearanceKey: _darkAppearance,
        });
      },
    );

    test('an appearance that is not an object reads as none', () async {
      writeDocument({
        _versionKey: 1,
        _deviceIdKey: 'device-a',
        _appearanceKey: 'dark',
      });

      final store = await DeviceSettingsStore.open(file);

      expect(store.issue, isNull);
      expect(store.appearance, isNull);
      expect(store.deviceId, 'device-a');
    });

    test('keeps the first-run card dismissed across reloads, beside keys it '
        'does not know', () async {
      writeDocument({
        _versionKey: 1,
        _deviceIdKey: 'device-a',
        'klabautermann.later': {'nested': true},
      });

      final store = await DeviceSettingsStore.open(file);
      expect(store.firstRunCardDismissed, isFalse);
      await store.dismissFirstRunCard();
      final reopened = await DeviceSettingsStore.open(file);

      expect(reopened.firstRunCardDismissed, isTrue);
      expect(document(), {
        _versionKey: 1,
        _deviceIdKey: 'device-a',
        'klabautermann.later': {'nested': true},
        _firstRunCardKey: true,
      });
    });

    for (final (name, value) in [('a string', 'true'), ('a number', 1)]) {
      test('a first-run card dismissal holding $name reads as not '
          'dismissed', () async {
        writeDocument({
          _versionKey: 1,
          _deviceIdKey: 'device-a',
          _firstRunCardKey: value,
        });

        final store = await DeviceSettingsStore.open(file);

        expect(store.issue, isNull);
        expect(store.firstRunCardDismissed, isFalse);
      });
    }

    test('keeps the root-equivalence notice dismissed across reloads, '
        'beside keys it does not know', () async {
      writeDocument({
        _versionKey: 1,
        _deviceIdKey: 'device-a',
        'klabautermann.later': {'nested': true},
      });

      final store = await DeviceSettingsStore.open(file);
      expect(store.rootEquivalenceNoticeDismissed, isFalse);
      await store.dismissRootEquivalenceNotice();
      final reopened = await DeviceSettingsStore.open(file);

      expect(reopened.rootEquivalenceNoticeDismissed, isTrue);
      expect(reopened.firstRunCardDismissed, isFalse);
      expect(document(), {
        _versionKey: 1,
        _deviceIdKey: 'device-a',
        'klabautermann.later': {'nested': true},
        _rootNoticeKey: true,
      });
    });

    test('a root-equivalence notice dismissal holding a string reads as '
        'not dismissed', () async {
      writeDocument({
        _versionKey: 1,
        _deviceIdKey: 'device-a',
        _rootNoticeKey: 'true',
      });

      final store = await DeviceSettingsStore.open(file);

      expect(store.issue, isNull);
      expect(store.rootEquivalenceNoticeDismissed, isFalse);
    });

    test('keeps stack folders per server across reloads; malformed '
        'entries and relative paths are skipped, and none removes one '
        '(STK-08)', () async {
      writeDocument({
        _versionKey: 1,
        _deviceIdKey: 'device-a',
        'klabautermann.docker.stackFolders': {
          'srv-9': 'not-a-list',
          'srv-8': ['relative/stacks', 7],
        },
      });

      final store = await DeviceSettingsStore.open(file);
      expect(store.stackFolders, isEmpty);
      await store.setStackFolders('srv-1', ['/opt/stacks', '/srv/apps']);
      final reopened = await DeviceSettingsStore.open(file);
      expect(reopened.stackFolders, {
        'srv-1': ['/opt/stacks', '/srv/apps'],
      });

      await reopened.setStackFolders('srv-1', const []);
      final cleared = await DeviceSettingsStore.open(file);
      expect(cleared.stackFolders, isEmpty);
      expect(
        (document()['klabautermann.docker.stackFolders'] as Map).keys,
        containsAll(['srv-9', 'srv-8']),
        reason: "other servers' entries stay as read",
      );
    });

    test('keeps TLS endpoints per server across reloads; malformed '
        'entries are skipped, and none removes one (CRT-01)', () async {
      writeDocument({
        _versionKey: 1,
        _deviceIdKey: 'device-a',
        'klabautermann.certificates.endpoints': {
          'srv-9': 'not-a-list',
          'srv-8': ['https://example.com', 7],
        },
      });

      final store = await DeviceSettingsStore.open(file);
      expect(store.tlsEndpoints, isEmpty);
      await store.setTlsEndpoints('srv-1', const [
        TlsEndpoint('example.com', 443),
        TlsEndpoint('2001:db8::1', 8443),
      ]);
      expect(
        (document()['klabautermann.certificates.endpoints'] as Map)['srv-1'],
        ['example.com:443', '[2001:db8::1]:8443'],
      );
      final reopened = await DeviceSettingsStore.open(file);
      expect(reopened.tlsEndpoints, {
        'srv-1': const [
          TlsEndpoint('example.com', 443),
          TlsEndpoint('2001:db8::1', 8443),
        ],
      });

      await reopened.setTlsEndpoints('srv-1', const []);
      final cleared = await DeviceSettingsStore.open(file);
      expect(cleared.tlsEndpoints, isEmpty);
      expect(
        (document()['klabautermann.certificates.endpoints'] as Map).keys,
        containsAll(['srv-9', 'srv-8']),
        reason: "other servers' entries stay as read",
      );
    });

    group('endpoint overrides (CN-09, D54)', () {
      const podman = DockerEndpointOverride(
        DockerEndpointDetected('/run/podman/podman.sock'),
        endpoint: 'alice@web-1.example:22',
      );
      const custom = DockerEndpointOverride(
        DockerEndpointCustom('/srv/engine.sock'),
        endpoint: 'db-1:2222',
      );

      test('round-trip across reloads, beside keys they do not know, and '
          'auto removes one', () async {
        writeDocument({
          _versionKey: 1,
          _deviceIdKey: 'device-a',
          'klabautermann.later': {'nested': true},
        });

        final store = await DeviceSettingsStore.open(file);
        expect(store.dockerEndpointOverrides, isEmpty);
        await store.setDockerEndpointOverride('srv-1', podman);
        await store.setDockerEndpointOverride('srv-2', custom);
        final reopened = await DeviceSettingsStore.open(file);

        expect(reopened.dockerEndpointOverrides, {
          'srv-1': podman,
          'srv-2': custom,
        });
        expect(document(), {
          _versionKey: 1,
          _deviceIdKey: 'device-a',
          'klabautermann.later': {'nested': true},
          _overridesKey: {
            'srv-1': {
              'choice': 'detected',
              'socketPath': '/run/podman/podman.sock',
              'endpoint': 'alice@web-1.example:22',
            },
            'srv-2': {
              'choice': 'custom',
              'socketPath': '/srv/engine.sock',
              'endpoint': 'db-1:2222',
            },
          },
        });

        await reopened.setDockerEndpointOverride('srv-1', null);
        expect((await DeviceSettingsStore.open(file)).dockerEndpointOverrides, {
          'srv-2': custom,
        });
      });

      test('malformed entries are skipped, and kept as they were when '
          'another server\'s changes', () async {
        final malformed = <String, Object?>{
          'not-a-map': 'custom',
          'unknown-kind': {
            'choice': 'remote',
            'socketPath': '/srv/a.sock',
            'endpoint': 'a:22',
          },
          'relative': {
            'choice': 'custom',
            'socketPath': 'srv/a.sock',
            'endpoint': 'a:22',
          },
          'line-break': {
            'choice': 'custom',
            'socketPath': '/srv/a\nb.sock',
            'endpoint': 'a:22',
          },
          'no-endpoint': {
            'choice': 'detected',
            'socketPath': '/run/docker.sock',
          },
          'number-path': {'choice': 'custom', 'socketPath': 7, 'endpoint': 'a'},
        };
        writeDocument({
          _versionKey: 1,
          _deviceIdKey: 'device-a',
          _overridesKey: malformed,
        });

        final store = await DeviceSettingsStore.open(file);
        expect(store.issue, isNull);
        expect(store.dockerEndpointOverrides, isEmpty);

        await store.setDockerEndpointOverride('srv-1', podman);
        expect(document()[_overridesKey], {
          ...malformed,
          'srv-1': {
            'choice': 'detected',
            'socketPath': '/run/podman/podman.sock',
            'endpoint': 'alice@web-1.example:22',
          },
        });
      });

      test(
        'a value that is not an object reads as none and is replaced',
        () async {
          writeDocument({
            _versionKey: 1,
            _deviceIdKey: 'device-a',
            _overridesKey: ['srv-1'],
          });

          final store = await DeviceSettingsStore.open(file);
          expect(store.dockerEndpointOverrides, isEmpty);
          await store.setDockerEndpointOverride('srv-2', custom);
          expect(
            (await DeviceSettingsStore.open(file)).dockerEndpointOverrides,
            {'srv-2': custom},
          );
        },
      );

      test('a purge drops servers the fleet lost or whose endpoint changed '
          '(SYN-08), and writes only when it dropped any', () async {
        final writes = <String>[];
        Future<void> writer(File target, List<int> bytes) {
          writes.add(target.path);
          return writeFileAtomically(target, bytes);
        }

        writeDocument({
          _versionKey: 1,
          _deviceIdKey: 'device-a',
          _overridesKey: {
            'srv-gone': {
              'choice': 'custom',
              'socketPath': '/srv/x.sock',
              'endpoint': 'x:22',
            },
            'no-endpoint': {'choice': 'custom', 'socketPath': '/srv/y.sock'},
          },
        });
        final store = await DeviceSettingsStore.open(file, writer: writer);
        await store.setDockerEndpointOverride('srv-1', podman);
        await store.setDockerEndpointOverride('srv-2', custom);
        writes.clear();

        final dropped = await store.purgeDockerEndpointOverrides({
          'srv-1': 'alice@web-1.example:22',
          'srv-2': 'db-1:22',
          'no-endpoint': 'y:22',
        });
        expect(dropped, {'srv-gone', 'srv-2', 'no-endpoint'});
        expect(writes, hasLength(1));
        expect((await DeviceSettingsStore.open(file)).dockerEndpointOverrides, {
          'srv-1': podman,
        });

        writes.clear();
        expect(
          await store.purgeDockerEndpointOverrides({
            'srv-1': 'alice@web-1.example:22',
          }),
          isEmpty,
        );
        expect(writes, isEmpty);
      });

      test('a choice a read-only session cannot save stays in memory and '
          'throws', () async {
        writeDocument({_versionKey: 2, _deviceIdKey: 'device-a'});
        final store = await DeviceSettingsStore.open(file);
        final before = file.readAsStringSync();

        await expectLater(
          store.setDockerEndpointOverride('srv-1', podman),
          throwsA(isA<DeviceSettingsReadOnlyException>()),
        );
        expect(store.dockerEndpointOverrides, {'srv-1': podman});
        await expectLater(
          store.purgeDockerEndpointOverrides(const {}),
          throwsA(isA<DeviceSettingsReadOnlyException>()),
        );
        expect(store.dockerEndpointOverrides, isEmpty);
        expect(file.readAsStringSync(), before);
      });
    });

    test('syncs no passwords until turned on, across reloads', () async {
      writeDocument({_versionKey: 1, _deviceIdKey: 'device-a'});

      final store = await DeviceSettingsStore.open(file);
      expect(store.syncSecrets, isFalse);
      await store.setSyncSecrets(true);
      final reopened = await DeviceSettingsStore.open(file);

      expect(reopened.syncSecrets, isTrue);
      expect(document(), {
        _versionKey: 1,
        _deviceIdKey: 'device-a',
        _syncSecretsKey: true,
      });

      writeDocument({
        _versionKey: 1,
        _deviceIdKey: 'device-a',
        _syncSecretsKey: 'yes',
      });
      expect(
        (await DeviceSettingsStore.open(file)).syncSecrets,
        isFalse,
        reason: 'a damaged value syncs nothing',
      );
    });

    test('keeps a device name across reloads, and none reads as the '
        'default (M5 plan Q6)', () async {
      writeDocument({_versionKey: 1, _deviceIdKey: 'device-a'});

      final store = await DeviceSettingsStore.open(file);
      expect(store.deviceName, isNull);
      await store.setDeviceName('Laptop');
      expect((await DeviceSettingsStore.open(file)).deviceName, 'Laptop');

      await store.setDeviceName(null);
      expect(document(), {_versionKey: 1, _deviceIdKey: 'device-a'});

      for (final damaged in [3, '  ']) {
        writeDocument({
          _versionKey: 1,
          _deviceIdKey: 'device-a',
          _deviceNameKey: damaged,
        });
        expect((await DeviceSettingsStore.open(file)).deviceName, isNull);
      }
    });

    test('keeps the polling budget\'s preset name across reloads, and reads '
        'a missing or damaged one as none (SAF-19)', () async {
      writeDocument({_versionKey: 1, _deviceIdKey: 'device-a'});

      final store = await DeviceSettingsStore.open(file);
      expect(store.cadence, isNull);
      await store.setCadence('cellularSaver');
      expect(document()[_cadenceKey], 'cellularSaver');
      expect((await DeviceSettingsStore.open(file)).cadence, 'cellularSaver');

      writeDocument({_versionKey: 1, _deviceIdKey: 'device-a', _cadenceKey: 3});
      expect((await DeviceSettingsStore.open(file)).cadence, isNull);
    });

    test('keeps each server\'s polling cap across reloads, lifts one on '
        'null and skips entries that are not names (SAF-19)', () async {
      writeDocument({
        _versionKey: 1,
        _deviceIdKey: 'device-a',
        _cadenceCapsKey: {'srv-9': 4, 'srv-2': 'phone'},
      });

      final store = await DeviceSettingsStore.open(file);
      expect(store.cadenceCaps, {'srv-2': 'phone'});
      await store.setCadenceCap('srv-1', 'cellularSaver');
      await store.setCadenceCap('srv-2', null);
      expect((await DeviceSettingsStore.open(file)).cadenceCaps, {
        'srv-1': 'cellularSaver',
      });

      writeDocument({
        _versionKey: 1,
        _deviceIdKey: 'device-a',
        _cadenceCapsKey: 'phone',
      });
      expect((await DeviceSettingsStore.open(file)).cadenceCaps, isEmpty);
    });

    test('posts no alert notification until turned on, keeps it off once '
        'turned off, and reads a damaged value as off', () async {
      writeDocument({_versionKey: 1, _deviceIdKey: 'device-a'});

      final store = await DeviceSettingsStore.open(file);
      expect(store.alertNotifications, isFalse);
      await store.setAlertNotifications(true);
      expect((await DeviceSettingsStore.open(file)).alertNotifications, isTrue);
      expect(document()[_alertNotificationsKey], isTrue);
      await store.setAlertNotifications(false);
      expect(
        (await DeviceSettingsStore.open(file)).alertNotifications,
        isFalse,
      );

      for (final damaged in <Object>['true', 1, <String>[]]) {
        writeDocument({
          _versionKey: 1,
          _deviceIdKey: 'device-a',
          _alertNotificationsKey: damaged,
        });
        expect(
          (await DeviceSettingsStore.open(file)).alertNotifications,
          isFalse,
        );
      }
    });

    test(
      'announces threshold bands until turned off, across reloads',
      () async {
        writeDocument({_versionKey: 1, _deviceIdKey: 'device-a'});

        final store = await DeviceSettingsStore.open(file);
        expect(store.announceThresholdBands, isTrue);
        await store.setAnnounceThresholdBands(false);
        final reopened = await DeviceSettingsStore.open(file);

        expect(reopened.announceThresholdBands, isFalse);
        expect(document(), {
          _versionKey: 1,
          _deviceIdKey: 'device-a',
          _announceBandsKey: false,
        });

        await reopened.setAnnounceThresholdBands(true);
        expect(
          (await DeviceSettingsStore.open(file)).announceThresholdBands,
          isTrue,
        );
      },
    );

    test('keeps the app lock off until turned on, across reloads, and a '
        'damaged value never drops it (SAF-20)', () async {
      writeDocument({_versionKey: 1, _deviceIdKey: 'device-a'});

      final store = await DeviceSettingsStore.open(file);
      expect(store.appLock, isFalse);
      await store.setAppLock(true);
      final reopened = await DeviceSettingsStore.open(file);

      expect(reopened.appLock, isTrue);
      expect(document(), {
        _versionKey: 1,
        _deviceIdKey: 'device-a',
        _appLockKey: true,
      });

      await reopened.setAppLock(false);
      expect((await DeviceSettingsStore.open(file)).appLock, isFalse);

      for (final damaged in <Object>['off', 0, <String>[]]) {
        writeDocument({
          _versionKey: 1,
          _deviceIdKey: 'device-a',
          _appLockKey: damaged,
        });
        expect((await DeviceSettingsStore.open(file)).appLock, isTrue);
      }
    });

    test('keeps pinned servers across reloads, sorted on disk', () async {
      writeDocument({_versionKey: 1, _deviceIdKey: 'device-a'});

      final store = await DeviceSettingsStore.open(file);
      expect(store.pinnedServerIds, isEmpty);
      await store.setPinnedServerIds({'srv-b', 'srv-a'});
      final reopened = await DeviceSettingsStore.open(file);

      expect(reopened.pinnedServerIds, {'srv-a', 'srv-b'});
      expect(document(), {
        _versionKey: 1,
        _deviceIdKey: 'device-a',
        _pinnedServersKey: ['srv-a', 'srv-b'],
      });

      await reopened.setPinnedServerIds({});
      expect((await DeviceSettingsStore.open(file)).pinnedServerIds, isEmpty);
    });

    for (final (name, value) in [
      ('a string', 'srv-a'),
      ('a map', {'srv-a': true}),
      ('items that are not strings', ['srv-a', 7, null]),
    ]) {
      test('pinned servers holding $name read what they can', () async {
        writeDocument({
          _versionKey: 1,
          _deviceIdKey: 'device-a',
          _pinnedServersKey: value,
        });

        final store = await DeviceSettingsStore.open(file);

        expect(store.issue, isNull);
        expect(store.pinnedServerIds, value is List ? {'srv-a'} : isEmpty);
      });
    }

    test(
      'pins a read-only session cannot save stay in memory and throw',
      () async {
        writeDocument({_versionKey: 2, _deviceIdKey: 'device-a'});
        final store = await DeviceSettingsStore.open(file);
        final before = file.readAsStringSync();

        await expectLater(
          store.setPinnedServerIds({'srv-a'}),
          throwsA(isA<DeviceSettingsReadOnlyException>()),
        );

        expect(store.pinnedServerIds, {'srv-a'});
        expect(file.readAsStringSync(), before);
      },
    );

    test('keeps the monitor set across reloads, sorted on disk, beside '
        'keys it does not know (FL-21)', () async {
      writeDocument({
        _versionKey: 1,
        _deviceIdKey: 'device-a',
        'klabautermann.future': 'kept',
      });

      final store = await DeviceSettingsStore.open(file);
      expect(store.monitorSet, isNull, reason: 'never chosen: the default');
      await store.setMonitorSet({'srv-b', 'srv-a'});
      final reopened = await DeviceSettingsStore.open(file);

      expect(reopened.monitorSet, {'srv-a', 'srv-b'});
      expect(document(), {
        _versionKey: 1,
        _deviceIdKey: 'device-a',
        'klabautermann.future': 'kept',
        _monitorSetKey: ['srv-a', 'srv-b'],
      });

      // An empty set is a choice of its own, not the default.
      await reopened.setMonitorSet({});
      expect((await DeviceSettingsStore.open(file)).monitorSet, isEmpty);
    });

    test('keeps the chosen container columns in order across reloads; a '
        'value that is not a list reads as none (CTR-08)', () async {
      writeDocument({_versionKey: 1, _deviceIdKey: 'device-a'});

      final store = await DeviceSettingsStore.open(file);
      expect(store.containerColumns, isNull);
      await store.setContainerColumns(['memory', 'state', 'pids']);
      expect((await DeviceSettingsStore.open(file)).containerColumns, [
        'memory',
        'state',
        'pids',
      ]);
      expect(document()[_containerColumnsKey], ['memory', 'state', 'pids']);

      writeDocument({
        _versionKey: 1,
        _deviceIdKey: 'device-a',
        _containerColumnsKey: 'memory',
      });
      final damaged = await DeviceSettingsStore.open(file);
      expect(damaged.issue, isNull);
      expect(damaged.containerColumns, isNull);

      writeDocument({
        _versionKey: 1,
        _deviceIdKey: 'device-a',
        _containerColumnsKey: ['memory', 7, null, 'cpu'],
      });
      expect((await DeviceSettingsStore.open(file)).containerColumns, [
        'memory',
        'cpu',
      ]);
    });

    for (final (name, value, expected) in [
      ('a string', 'srv-a', null),
      ('a map', {'srv-a': true}, null),
      ('items that are not strings', ['srv-a', 7, null], {'srv-a'}),
    ]) {
      test('a monitor set holding $name reads what it can', () async {
        writeDocument({
          _versionKey: 1,
          _deviceIdKey: 'device-a',
          _monitorSetKey: value,
        });

        final store = await DeviceSettingsStore.open(file);

        expect(store.issue, isNull);
        expect(store.monitorSet, expected);
      });
    }

    test('a monitor set a read-only session cannot save stays in memory '
        'and throws', () async {
      writeDocument({_versionKey: 2, _deviceIdKey: 'device-a'});
      final store = await DeviceSettingsStore.open(file);
      final before = file.readAsStringSync();

      await expectLater(
        store.setMonitorSet({'srv-a'}),
        throwsA(isA<DeviceSettingsReadOnlyException>()),
      );

      expect(store.monitorSet, {'srv-a'});
      expect(file.readAsStringSync(), before);
    });

    test('a damaged announcement setting reads as on', () async {
      writeDocument({
        _versionKey: 1,
        _deviceIdKey: 'device-a',
        _announceBandsKey: 'false',
      });

      final store = await DeviceSettingsStore.open(file);

      expect(store.issue, isNull);
      expect(store.announceThresholdBands, isTrue);
    });

    test('an announcement setting a read-only session cannot save stays in '
        'memory and throws', () async {
      writeDocument({_versionKey: 2, _deviceIdKey: 'device-a'});
      final store = await DeviceSettingsStore.open(file);
      final before = file.readAsStringSync();

      await expectLater(
        store.setAnnounceThresholdBands(false),
        throwsA(isA<DeviceSettingsReadOnlyException>()),
      );

      expect(store.announceThresholdBands, isFalse);
      expect(file.readAsStringSync(), before);
    });

    test('a dismissal a read-only session cannot save stays in memory and '
        'throws', () async {
      writeDocument({_versionKey: 2, _deviceIdKey: 'device-a'});
      final store = await DeviceSettingsStore.open(file);
      final before = file.readAsStringSync();

      await expectLater(
        store.dismissFirstRunCard(),
        throwsA(isA<DeviceSettingsReadOnlyException>()),
      );

      expect(store.firstRunCardDismissed, isTrue);
      expect(file.readAsStringSync(), before);
    });

    test('overlapping writes land in call order', () async {
      final store = await DeviceSettingsStore.open(file);

      await Future.wait([
        store.setAppearance({'mode': 'light'}),
        store.setAppearance({'mode': 'dark'}),
      ]);

      final reopened = await DeviceSettingsStore.open(file);
      expect(reopened.appearance, {'mode': 'dark'});
    });

    test('keeps the safety preferences across reloads; a value that is '
        'not an object reads as none', () async {
      final store = await DeviceSettingsStore.open(file);
      expect(store.safety, isNull, reason: 'every server observe-only');
      final servers = <String, Object?>{
        'srv-a': {'management': true},
      };
      final saved = store.setSafety({
        'globalReadOnly': false,
        'servers': servers,
      });
      servers['srv-b'] = {'management': true};
      await saved;

      final reopened = await DeviceSettingsStore.open(file);
      expect(reopened.safety, {
        'globalReadOnly': false,
        'servers': {
          'srv-a': {'management': true},
        },
      });

      writeDocument({...document(), _safetyKey: 'on'});
      expect((await DeviceSettingsStore.open(file)).safety, isNull);
    });

    test('keeps the acknowledged problems across reloads (TRI-03); a '
        'value that is not an object reads as none', () async {
      final store = await DeviceSettingsStore.open(file);
      expect(store.attention, isNull);
      await store.setAttention({
        'srv-a': {
          'failedUnit:nginx.service': {
            'at': '2026-10-26T12:00:00.000Z',
            'note': 'restarts tonight',
          },
        },
      });

      final reopened = await DeviceSettingsStore.open(file);
      expect(reopened.attention, {
        'srv-a': {
          'failedUnit:nginx.service': {
            'at': '2026-10-26T12:00:00.000Z',
            'note': 'restarts tonight',
          },
        },
      });

      writeDocument({
        ...document(),
        _attentionKey: ['srv-a'],
      });
      expect((await DeviceSettingsStore.open(file)).attention, isNull);
    });

    test('saves the appearance as it was passed', () async {
      final store = await DeviceSettingsStore.open(file);
      final palette = <String, Object?>{'name': 'Klabautermann'};
      final appearance = <String, Object?>{'palette': palette, 'mode': 'dark'};

      final saved = store.setAppearance(appearance);
      appearance['mode'] = 'light';
      palette['name'] = 'changed';
      await saved;

      expect(store.appearance, _darkAppearance);
      expect(document()[_appearanceKey], _darkAppearance);
    });

    test('a valid file without a device id mints one and saves it', () async {
      writeDocument({_versionKey: 1, _appearanceKey: _darkAppearance});

      final store = await DeviceSettingsStore.open(file);

      expect(store.issue, isNull);
      expect(store.deviceId, matches(_uuidV4));
      expect(document(), {
        _versionKey: 1,
        _appearanceKey: _darkAppearance,
        _deviceIdKey: store.deviceId,
      });
      expect(entries(), [deviceSettingsFileName]);
    });

    test('a failed write keeps the change in memory and the file as it '
        'was', () async {
      var failing = false;
      Future<void> writer(File target, List<int> contents) {
        if (failing) throw const FileSystemException('disk full');
        return writeFileAtomically(target, contents);
      }

      final store = await DeviceSettingsStore.open(file, writer: writer);
      final before = file.readAsBytesSync();

      failing = true;
      await expectLater(
        store.setAppearance(_darkAppearance),
        throwsA(isA<FileSystemException>()),
      );
      expect(store.appearance, _darkAppearance);
      expect(file.readAsBytesSync(), before);

      // The queue is not wedged by the failure.
      failing = false;
      await store.setAppearance({'mode': 'light'});
      expect(document()[_appearanceKey], {'mode': 'light'});
    });

    test('a failed first write hands out no device id', () async {
      Future<void> failingWriter(File target, List<int> contents) =>
          throw const FileSystemException('read-only file system');

      final store = await DeviceSettingsStore.open(file, writer: failingWriter);

      expect(store.issue?.kind, DeviceSettingsIssueKind.notSaved);
      expect(store.issue?.error, isA<FileSystemException>());
      expect(store.deviceId, isNull);
      expect(file.existsSync(), isFalse);

      // The next launch that can write mints and keeps one.
      final next = await DeviceSettingsStore.open(file);
      expect(next.issue, isNull);
      expect(next.deviceId, matches(_uuidV4));
    });

    group('a damaged file', () {
      test('is copied aside byte for byte, and its device id kept', () async {
        const damaged =
            '{"klabautermann.settings.version":1,'
            '"klabautermann.sync.deviceId":"device-a",'
            '"klabautermann.appearance":{"mode":"da';
        file.writeAsStringSync(damaged);

        final store = await DeviceSettingsStore.open(file, now: () => _time);

        final issue = store.issue!;
        expect(issue.kind, DeviceSettingsIssueKind.recovered);
        expect(issue.error, isA<FormatException>());
        expect(
          issue.preservedAs,
          '${file.path}.corrupt-$_stamp',
          reason: "Poltergeist's UTC-stamped copy name",
        );
        expect(File(issue.preservedAs!).readAsStringSync(), damaged);
        expect(store.deviceId, 'device-a');
        expect(store.appearance, isNull);
        // The defaults and the kept id are written back at once (Séance's
        // rule), so the next launch does not mint a new id.
        expect(document(), {_versionKey: 1, _deviceIdKey: 'device-a'});
        expect(entries(), [
          deviceSettingsFileName,
          '$deviceSettingsFileName.corrupt-$_stamp',
        ]);
      });

      final invalid = <String, List<int>>{
        'a list': utf8.encode('[]'),
        'no version': utf8.encode('{"$_deviceIdKey":"device-a"}'),
        'a text version': utf8.encode('{"$_versionKey":"1"}'),
        'version zero': utf8.encode('{"$_versionKey":0}'),
        'a numeric device id': utf8.encode(
          '{"$_versionKey":1,"$_deviceIdKey":7}',
        ),
        'an empty device id': utf8.encode(
          '{"$_versionKey":1,"$_deviceIdKey":""}',
        ),
        'bytes that are not UTF-8': [0xff, 0xfe, 0x7b],
        'an empty file': [],
      };
      for (final MapEntry(key: name, value: bytes) in invalid.entries) {
        test('is recovered when it holds $name', () async {
          file.writeAsBytesSync(bytes);

          final store = await DeviceSettingsStore.open(file, now: () => _time);

          expect(store.issue?.kind, DeviceSettingsIssueKind.recovered);
          expect(File(store.issue!.preservedAs!).readAsBytesSync(), bytes);
          expect(document()[_versionKey], deviceSettingsSchemaVersion);
          // 'no version' still shows a usable id; the others get a new one.
          if (name == 'no version') {
            expect(store.deviceId, 'device-a');
          } else {
            expect(store.deviceId, matches(_uuidV4));
          }
          expect(document()[_deviceIdKey], store.deviceId);
        });
      }

      test('never overwrites the copy of an earlier damage', () async {
        file.writeAsStringSync('first damage');
        final first = await DeviceSettingsStore.open(file, now: () => _time);
        file.writeAsStringSync('second damage');
        final second = await DeviceSettingsStore.open(file, now: () => _time);

        final firstCopy = first.issue!.preservedAs!;
        final secondCopy = second.issue!.preservedAs!;
        expect(secondCopy, isNot(firstCopy));
        expect(second.issue!.kind, DeviceSettingsIssueKind.recovered);
        expect(File(firstCopy).readAsStringSync(), 'first damage');
        expect(File(secondCopy).readAsStringSync(), 'second damage');
      });

      test('is left untouched when its copy fails, and nothing is '
          'saved', () async {
        const damaged = '{"klabautermann.sync.deviceId":"device-a",';
        file.writeAsStringSync(damaged);
        Future<void> writer(File target, List<int> contents) {
          if (target.path.contains('.corrupt-')) {
            throw const FileSystemException('permission denied');
          }
          return writeFileAtomically(target, contents);
        }

        final store = await DeviceSettingsStore.open(file, writer: writer);

        expect(store.issue?.kind, DeviceSettingsIssueKind.unpreserved);
        expect(store.issue?.kind.readOnly, isTrue);
        expect(store.deviceId, 'device-a');
        await expectLater(
          store.setAppearance(_darkAppearance),
          throwsA(isA<DeviceSettingsReadOnlyException>()),
        );
        expect(store.appearance, _darkAppearance, reason: 'kept in memory');
        expect(file.readAsStringSync(), damaged);
        expect(entries(), [deviceSettingsFileName]);
      });

      test('stays in place when the write-back fails, for the next launch '
          'to recover', () async {
        const damaged = '{"klabautermann.sync.deviceId":"device-a"';
        file.writeAsStringSync(damaged);
        Future<void> writer(File target, List<int> contents) {
          if (target.path == file.path) {
            throw const FileSystemException('disk full');
          }
          return writeFileAtomically(target, contents);
        }

        final store = await DeviceSettingsStore.open(
          file,
          writer: writer,
          now: () => _time,
        );

        // The copy was made, but the file was not reset, so the user is
        // not told it was.
        final issue = store.issue!;
        expect(issue.kind, DeviceSettingsIssueKind.recoveredNotSaved);
        expect(issue.kind.readOnly, isFalse);
        expect(issue.preservedAs, '${file.path}.corrupt-$_stamp');
        expect(File(issue.preservedAs!).readAsStringSync(), damaged);
        expect(
          issue.error,
          isA<FileSystemException>(),
          reason: "the write's failure, not the parse error",
        );
        expect(store.deviceId, 'device-a', reason: 'still on disk');
        expect(file.readAsStringSync(), damaged);

        final next = await DeviceSettingsStore.open(file);
        expect(next.issue?.kind, DeviceSettingsIssueKind.recovered);
        expect(next.deviceId, 'device-a');
        expect(document(), {_versionKey: 1, _deviceIdKey: 'device-a'});
      });

      test('hands out no new device id when the write-back fails', () async {
        file.writeAsStringSync('no id here');
        Future<void> writer(File target, List<int> contents) {
          if (target.path == file.path) {
            throw const FileSystemException('disk full');
          }
          return writeFileAtomically(target, contents);
        }

        final store = await DeviceSettingsStore.open(file, writer: writer);

        expect(store.issue?.kind, DeviceSettingsIssueKind.recoveredNotSaved);
        expect(store.deviceId, isNull, reason: 'the minted id never saved');
        expect(file.readAsStringSync(), 'no id here');
      });
    });

    test('an unreadable file is left alone and nothing is saved', () async {
      // A directory where the file should be: present, but not readable as
      // a file, whoever runs the test.
      Directory(file.path).createSync();

      final store = await DeviceSettingsStore.open(file);

      expect(store.issue?.kind, DeviceSettingsIssueKind.unreadable);
      expect(store.issue?.error, isA<FileSystemException>());
      expect(store.deviceId, isNull, reason: 'no id is invented');
      await expectLater(
        store.setAppearance(_darkAppearance),
        throwsA(isA<DeviceSettingsReadOnlyException>()),
      );
      expect(Directory(file.path).existsSync(), isTrue);
      expect(entries(), [deviceSettingsFileName]);
    });

    test('a newer schema is read but never rewritten', () async {
      writeDocument({
        _versionKey: deviceSettingsSchemaVersion + 1,
        _deviceIdKey: 'device-b',
        _appearanceKey: _darkAppearance,
        'klabautermann.newer': 1,
      });
      final bytes = file.readAsBytesSync();

      final store = await DeviceSettingsStore.open(file);

      expect(store.issue?.kind, DeviceSettingsIssueKind.newerVersion);
      expect(store.deviceId, 'device-b');
      expect(store.appearance, _darkAppearance);
      await expectLater(
        store.setAppearance({'mode': 'light'}),
        throwsA(isA<DeviceSettingsReadOnlyException>()),
      );
      expect(file.readAsBytesSync(), bytes);
    });
  });

  group('writeFileAtomically', () {
    test('replaces the file, creating its folder, and leaves no temp '
        'file', () async {
      final nested = File('${directory.path}/support/settings.json');

      await writeFileAtomically(nested, utf8.encode('first'));
      await writeFileAtomically(nested, utf8.encode('second'));

      expect(nested.readAsStringSync(), 'second');
      expect(nested.parent.listSync().map((e) => e.path), [nested.path]);
    });

    test('a failed replace leaves the target as it was and removes the '
        'temp file', () async {
      // rename(2) cannot replace a non-empty directory.
      final target = Directory(file.path)..createSync();
      File('${target.path}/keep').writeAsStringSync('kept');

      await expectLater(
        writeFileAtomically(file, utf8.encode('{}')),
        throwsA(isA<FileSystemException>()),
      );

      expect(File('${target.path}/keep').readAsStringSync(), 'kept');
      expect(entries(), [deviceSettingsFileName]);
    });
  });
}
