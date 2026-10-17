// Moved from Poltergeist's app test/file_stores_test.dart with
// FileHostKeyStore (docs/design/catalog-library.md section 8).
import 'dart:io';

import 'package:seance_core/catalog.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'seance_file_host_key_store_test_',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  group('FileHostKeyStore', () {
    const key = HostKey(
      host: 'nas.local',
      port: 2222,
      type: 'ssh-ed25519',
      fingerprintSha256: 'SHA256:abc123',
      pinnedAt: 1700000000,
    );

    test('pins and reloads host keys across instances', () async {
      final file = File('${temporaryDirectory.path}/known_hosts.json');
      await FileHostKeyStore(file).put(key);

      final reloaded = await FileHostKeyStore(file).get('nas.local', 2222);
      expect(reloaded!.fingerprintSha256, 'SHA256:abc123');
      expect(await FileHostKeyStore(file).all(), hasLength(1));
    });

    test(
      'a corrupt known_hosts file starts empty instead of wedging startup',
      () async {
        final file = File('${temporaryDirectory.path}/known_hosts.json');
        await file.parent.create(recursive: true);
        await file.writeAsString('[{');

        final store = FileHostKeyStore(file);
        expect(await store.get('nas.local', 2222), isNull);
        expect(await store.all(), isEmpty);

        expect(
          temporaryDirectory.listSync().whereType<File>().where(
            (f) => f.path.contains('.corrupt-'),
          ),
          hasLength(1),
        );
      },
    );

    test('a failed write cannot leak into a later snapshot', () async {
      final file = File('${temporaryDirectory.path}/known_hosts.json');
      var failNextWrite = true;
      final store = FileHostKeyStore(
        file,
        atomicWriter: (target, contents) async {
          if (failNextWrite) {
            failNextWrite = false;
            throw StateError('write failed');
          }

          await target.parent.create(recursive: true);
          await target.writeAsString(contents);
        },
      );
      const failed = HostKey(
        host: 'failed.example.com',
        port: 22,
        type: 'ssh-ed25519',
        fingerprintSha256: 'SHA256:failed',
        pinnedAt: 1700000001,
      );

      await expectLater(store.put(failed), throwsStateError);
      await store.put(key);

      final reloaded = await FileHostKeyStore(file).all();
      expect(reloaded.map((entry) => entry.locator), [key.locator]);
      expect(await store.get(failed.host, failed.port), isNull);
    });

    test('a conflicting conditional pin leaves storage unchanged', () async {
      final file = File('${temporaryDirectory.path}/known_hosts.json');
      final store = FileHostKeyStore(file);
      await store.put(key);
      final before = await file.readAsString();
      const conflicting = HostKey(
        host: 'nas.local',
        port: 2222,
        type: 'ssh-ed25519',
        fingerprintSha256: 'SHA256:changed',
        pinnedAt: 1700000001,
      );

      final result = await store.putIfNoConflict(conflicting);

      expect(result, HostKeyInstallResult.conflict);
      expect(
        (await store.get(key.host, key.port))!.fingerprintSha256,
        key.fingerprintSha256,
      );
      expect(await file.readAsString(), before);
    });

    test('conditional replacement requires the expected current pin', () async {
      final file = File('${temporaryDirectory.path}/known_hosts.json');
      final store = FileHostKeyStore(file);
      await store.put(key);
      const replacement = HostKey(
        host: 'nas.local',
        port: 2222,
        type: 'ssh-ed25519',
        fingerprintSha256: 'SHA256:replacement',
        pinnedAt: 1700000001,
      );
      const staleReplacement = HostKey(
        host: 'nas.local',
        port: 2222,
        type: 'ssh-ed25519',
        fingerprintSha256: 'SHA256:stale',
        pinnedAt: 1700000002,
      );

      expect(
        await store.replaceIfCurrent(key, replacement),
        HostKeyInstallResult.installed,
      );
      final beforeConflict = await file.readAsString();

      expect(
        await store.replaceIfCurrent(key, staleReplacement),
        HostKeyInstallResult.conflict,
      );
      expect(await file.readAsString(), beforeConflict);
      expect(
        () => store.replaceIfCurrent(
          replacement,
          const HostKey(
            host: 'other.local',
            port: 2222,
            type: 'ssh-ed25519',
            fingerprintSha256: 'SHA256:other',
            pinnedAt: 1700000003,
          ),
        ),
        throwsArgumentError,
      );
    });
  });
}
