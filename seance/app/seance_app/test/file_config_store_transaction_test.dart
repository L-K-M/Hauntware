import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/file_stores.dart';
import 'package:seance_core/seance_core.dart';

import 'support/atomic_write_blocker.dart';

void main() {
  late Directory directory;
  late File file;
  late FileConfigStore store;

  final original = ServerConfig(
    id: 'server',
    label: 'Original',
    host: 'host.example',
    username: 'user',
    authMethod: AuthMethod.password,
    secretRef: 'old-credential',
    createdAt: 1,
    updatedAt: 1,
  );

  final unrelated = ServerConfig(
    id: 'unrelated',
    label: 'Other',
    host: 'other.example',
    username: 'user',
    authMethod: AuthMethod.agent,
    createdAt: 1,
    updatedAt: 1,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-config-commit-');
    file = File('${directory.path}/servers.json');
    store = FileConfigStore(file);
    await store.putServer(original);
  });

  tearDown(() => directory.delete(recursive: true));

  test(
    'a failed credential config save keeps the old reference in memory and on disk',
    () async {
      final blocker = await AtomicWriteBlocker(file).create();
      final replacement = original.copyWith(
        secretRef: 'new-credential',
        updatedAt: 2,
      );

      await expectLater(
        store.putServer(replacement),
        throwsA(isA<FileSystemException>()),
      );

      expect((await store.getServer(original.id))!.secretRef, 'old-credential');
      await blocker.delete();
      expect(
        (await FileConfigStore(file).getServer(original.id))!.secretRef,
        'old-credential',
      );

      await store.putServer(unrelated);
      expect(
        (await FileConfigStore(file).getServer(original.id))!.secretRef,
        'old-credential',
      );
      await store.putServer(replacement);
      expect(
        (await FileConfigStore(file).getServer(original.id))!.secretRef,
        'new-credential',
      );
    },
  );

  test(
    'a read queued behind a failed save sees only committed credentials',
    () async {
      final blocker = await AtomicWriteBlocker(file).create();
      final failedSave = store.putServer(
        original.copyWith(secretRef: 'new-credential'),
      );
      final queuedRead = store.getServer(original.id);

      await expectLater(failedSave, throwsA(isA<FileSystemException>()));
      expect((await queuedRead)!.secretRef, 'old-credential');
      await blocker.delete();
    },
  );

  test(
    'cold concurrent saves and reads preserve every committed server',
    () async {
      final cold = FileConfigStore(File('${directory.path}/cold.json'));
      final first = cold.putServer(original);
      final second = cold.putServer(unrelated);
      final read = cold.listServers();

      await Future.wait([first, second]);
      expect(
        (await read).map((server) => server.id),
        unorderedEquals(['server', 'unrelated']),
      );
      expect(
        (await FileConfigStore(
          cold.file,
        ).listServers()).map((server) => server.id),
        unorderedEquals(['server', 'unrelated']),
      );
    },
  );

  test(
    'a failed deletion cannot ride a later successful config save',
    () async {
      final blocker = await AtomicWriteBlocker(file).create();

      await expectLater(
        store.deleteServer(original.id),
        throwsA(isA<FileSystemException>()),
      );

      expect(await store.getServer(original.id), isNotNull);
      await blocker.delete();
      await store.putServer(unrelated);
      expect(await FileConfigStore(file).getServer(original.id), isNotNull);
    },
  );
}
