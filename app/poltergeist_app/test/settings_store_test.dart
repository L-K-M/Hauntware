import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/settings_store.dart';

import 'support/memory_settings_file_system.dart';

final _temporarySettingsPath = RegExp(
  r'^/support/\.poltergeist-'
  r'[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
  r'[0-9a-f]{12}\.tmp$',
);

void main() {
  test('writes the complete settings snapshot atomically', () async {
    final files = MemorySettingsFileSystem();
    final store = SettingsStore(
      path: '/support/settings.json',
      fileSystem: files,
    );

    await store.set('window.width', 1180.0);
    await store.set('window.height', 760.0);

    expect(files.writes, hasLength(2));
    expect(files.writes.toSet(), hasLength(2));
    expect(files.writes, everyElement(matches(_temporarySettingsPath)));
    expect(
      files.renames,
      files.writes.map((source) => (source, '/support/settings.json')).toList(),
    );
    expect(jsonDecode(files.contents['/support/settings.json']!), {
      'window.width': 1180.0,
      'window.height': 760.0,
    });
  });

  test('serializes overlapping writes', () async {
    final files = MemorySettingsFileSystem()..blockWrites = true;
    final store = SettingsStore(
      path: '/support/settings.json',
      fileSystem: files,
    );

    final first = store.set('first', 1);
    await files.firstWriteStarted.future;
    final second = store.set('second', 2);
    await Future<void>.delayed(Duration.zero);
    expect(files.writes, hasLength(1));

    files.releaseWrites();
    await Future.wait([first, second]);

    expect(jsonDecode(files.contents['/support/settings.json']!), {
      'first': 1,
      'second': 2,
    });
  });

  test('quarantines corrupt settings and starts empty', () async {
    final errors = <Object>[];
    final files = MemorySettingsFileSystem()
      ..contents['/support/settings.json'] = '{broken';
    final store = SettingsStore(
      path: '/support/settings.json',
      fileSystem: files,
      now: () => DateTime.utc(2026, 9, 2, 12),
      onError: (error, _) => errors.add(error),
    );

    expect(await store.get<double>('missing'), isNull);
    expect(files.renames.single.$1, '/support/settings.json');
    expect(
      files.renames.single.$2,
      '/support/settings.json.corrupt-20260902T120000000Z',
    );
    expect(errors, [isA<FormatException>()]);
  });

  test('reports both corrupt input and a failed quarantine', () async {
    final quarantineFailure = StateError('rename failed');
    final errors = <Object>[];
    final files = MemorySettingsFileSystem()
      ..contents['/support/settings.json'] = '{broken'
      ..renameError = quarantineFailure;
    final store = SettingsStore(
      path: '/support/settings.json',
      fileSystem: files,
      onError: (error, _) => errors.add(error),
    );

    expect(await store.get<double>('missing'), isNull);
    expect(errors, [same(quarantineFailure), isA<FormatException>()]);
  });

  test('reverts failed writes for the caller to report', () async {
    final files = MemorySettingsFileSystem()..failWrites = true;
    final errors = <Object>[];
    final store = SettingsStore(
      path: '/support/settings.json',
      fileSystem: files,
      onError: (error, _) => errors.add(error),
    );

    await expectLater(store.set('density', 2), throwsA(isA<StateError>()));
    expect(await store.get<int>('density'), isNull);
    expect(errors, isEmpty);
  });

  test('removes a partial temporary sibling after a failed write', () async {
    final files = MemorySettingsFileSystem()..failWrites = true;
    final store = SettingsStore(
      path: '/support/settings.json',
      fileSystem: files,
    );

    await expectLater(store.set('density', 2), throwsA(isA<StateError>()));

    final temporaryPath = files.writes.single;
    expect(temporaryPath, matches(_temporarySettingsPath));
    expect(files.deletes, [temporaryPath]);
    expect(files.contents, isNot(contains(temporaryPath)));
  });

  test('cleanup failure preserves the original rename failure', () async {
    final renameFailure = StateError('rename failed');
    final files = MemorySettingsFileSystem()
      ..renameError = renameFailure
      ..deleteError = StateError('delete failed');
    final store = SettingsStore(
      path: '/support/settings.json',
      fileSystem: files,
    );

    await expectLater(store.set('density', 2), throwsA(same(renameFailure)));

    final temporaryPath = files.writes.single;
    expect(files.deletes, [temporaryPath]);
    expect(files.contents, contains(temporaryPath));
  });

  test('does not reintroduce a rolled-back value in a queued write', () async {
    final files = MemorySettingsFileSystem()
      ..blockWrites = true
      ..failFirstWrite = true;
    final store = SettingsStore(
      path: '/support/settings.json',
      fileSystem: files,
    );

    final first = store.set('first', 1);
    await files.firstWriteStarted.future;
    final second = store.set('second', 2);
    files.releaseWrites();

    await expectLater(first, throwsA(isA<StateError>()));
    await second;
    expect(jsonDecode(files.contents['/support/settings.json']!), {
      'second': 2,
    });
  });
}
