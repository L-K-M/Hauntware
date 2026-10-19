// Séance #56 on this app's own stores (catalog-library.md §7): a pulled pin
// that disagrees with known_hosts.json is held back and leaves the file
// byte for byte as it was; the user's verdicts live in settings.json.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/app_settings.dart';
import 'package:seance_app/services/file_stores.dart';
import 'package:seance_app/services/pin_verdicts.dart';
import 'package:seance_core/catalog.dart' show HostKeyInstallResult;
import 'package:seance_core/seance_core.dart';

const _k1 = HostKey(
  host: 'alpha.example.com',
  type: 'ssh-ed25519',
  fingerprintSha256: 'SHA256:k1',
  pinnedAt: 10,
);
const _k2 = HostKey(
  host: 'alpha.example.com',
  type: 'ssh-ed25519',
  fingerprintSha256: 'SHA256:k2',
  pinnedAt: 20,
);

void main() {
  late Directory dir;
  late File knownHosts;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('seance-pulled-pin-');
    knownHosts = File('${dir.path}/known_hosts.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a conflicting pulled pin leaves known_hosts.json unchanged', () async {
    await FileHostKeyStore(knownHosts).put(_k1);
    final before = knownHosts.readAsBytesSync();

    final codec = RecordCodec(secureRandomBytes(32));
    final mirror = InMemoryLocalRecordStore();
    await mirror.putRemote(
      await codec.encrypt(
        DecryptedRecord(
          id: _k2.recordId,
          kind: RecordKind.hostKey,
          updatedAt: 20,
          deviceId: 'B',
          data: _k2.toJson(),
        ),
      ),
    );
    final configs = InMemoryConfigStore();
    await configs.putServer(
      const ServerConfig(
        id: 's1',
        label: 'alpha',
        host: 'alpha.example.com',
        username: 'u',
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    final settings = AppSettings();
    final coordinator = SyncCoordinator(
      configStore: configs,
      hostKeyStore: FileHostKeyStore(knownHosts),
      pinVerdicts: SettingsPinVerdictStore(
        settings: () => settings,
        save: () async {},
      ),
      codec: codec,
      local: mirror,
      deviceId: 'A',
    );

    await coordinator.applyToStores();

    expect(knownHosts.readAsBytesSync(), before);
    expect(
      coordinator.pinConflicts.single.pulled.fingerprintSha256,
      'SHA256:k2',
    );
  });

  test('the file store writes only an agreeing or still-current pin', () async {
    final store = FileHostKeyStore(knownHosts);
    expect(await store.putIfNoConflict(_k1), HostKeyInstallResult.installed);
    expect(await store.putIfNoConflict(_k2), HostKeyInstallResult.conflict);
    expect(
      await store.replaceIfCurrent(_k2, _k1),
      HostKeyInstallResult.conflict,
    );
    expect(
      await store.replaceIfCurrent(_k1, _k2),
      HostKeyInstallResult.installed,
    );

    final reread = await FileHostKeyStore(
      knownHosts,
    ).get('alpha.example.com', 22);
    expect(reread?.fingerprintSha256, 'SHA256:k2');
  });

  group('the verdicts in settings', () {
    test('are saved, and untrusting drops the kept verdict', () async {
      final settings = AppSettings();
      var saves = 0;
      final verdicts = SettingsPinVerdictStore(
        settings: () => settings,
        save: () async => saves++,
      );

      await verdicts.recordKeptVerdict('alpha.example.com:22', 'SHA256:k2');
      await verdicts.recordKeptVerdict('alpha.example.com:22', 'SHA256:k2');
      expect(saves, 1, reason: 'an unchanged verdict is not saved again');
      expect(
        await verdicts.rejectedFingerprintFor('alpha.example.com:22'),
        'SHA256:k2',
      );

      await verdicts.addNegativePin('alpha.example.com:22');
      expect(await verdicts.negativePins(), {'alpha.example.com:22'});
      expect(
        await verdicts.rejectedFingerprintFor('alpha.example.com:22'),
        isNull,
      );

      await verdicts.removeNegativePin('alpha.example.com:22');
      expect(await verdicts.negativePins(), isEmpty);
      expect(saves, 3);
    });

    test('are put back when the save fails', () async {
      final settings = AppSettings();
      final verdicts = SettingsPinVerdictStore(
        settings: () => settings,
        save: () async => throw const FileSystemException('disk full'),
      );

      await expectLater(
        verdicts.recordKeptVerdict('alpha.example.com:22', 'SHA256:k2'),
        throwsA(isA<FileSystemException>()),
      );
      expect(settings.keptPinVerdicts, isEmpty);
    });

    test('round-trip through settings.json, tolerating damage', () {
      final settings = AppSettings(
        untrustedPinLocators: {'b.example.com:22', 'a.example.com:22'},
        keptPinVerdicts: {'c.example.com:22': 'SHA256:x'},
      );
      final json = settings.toJson();
      expect(json['untrustedPinLocators'], [
        'a.example.com:22',
        'b.example.com:22',
      ]);
      final back = AppSettings.fromJson(json);
      expect(back.untrustedPinLocators, settings.untrustedPinLocators);
      expect(back.keptPinVerdicts, settings.keptPinVerdicts);

      final damaged = AppSettings().toJson()
        ..['untrustedPinLocators'] = 'a'
        ..['keptPinVerdicts'] = {
          'd.example.com:22': 7,
          'e.example.com:22': 'y',
        };
      final read = AppSettings.fromJson(damaged);
      expect(read.untrustedPinLocators, isEmpty);
      expect(read.keptPinVerdicts, {'e.example.com:22': 'y'});
    });
  });
}
