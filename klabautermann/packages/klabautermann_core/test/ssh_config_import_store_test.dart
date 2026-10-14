import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/fleet/ssh_config_entries.dart';
import 'package:klabautermann_core/src/fleet/ssh_config_import_store.dart';
import 'package:klabautermann_core/src/settings/device_settings_store.dart'
    show writeFileAtomically;
import 'package:test/test.dart';

import 'fixtures/ssh_config_fixture.dart';

/// A fixed clock, so the kept copy of a damaged file has a known name.
final _time = DateTime.utc(2026, 10, 14, 9, 30, 5, 250);
const _stamp = '20261014T093005250Z';

final _web = importedFleetEntry(
  alias: 'web-1',
  host: 'web-1.example.com',
  port: 2222,
  user: 'deploy',
);
final _bastion = importedFleetEntry(
  alias: 'bastion',
  host: 'bastion',
  port: kSshDefaultPort,
);

void main() {
  late Directory directory;
  late File file;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('klab-imports-');
    file = File('${directory.path}/$sshConfigImportsFileName');
  });

  tearDown(() => directory.deleteSync(recursive: true));

  List<String> names() =>
      directory
          .listSync()
          .map((entity) => entity.uri.pathSegments.lastWhere((s) => s != ''))
          .toList()
        ..sort();

  group('SshConfigImportStore', () {
    test('a missing file is an empty store and nothing is written', () async {
      final store = await SshConfigImportStore.open(file);

      expect(store.issue, isNull);
      expect(store.entries, isEmpty);
      expect(names(), isEmpty);
    });

    test('a replace saves the set, which the next open restores', () async {
      final store = await SshConfigImportStore.open(file);

      expect(await store.replace([_web, _bastion]), isTrue);

      expect(jsonDecode(file.readAsStringSync()), {
        'version': sshConfigImportsSchemaVersion,
        'entries': [
          {
            'alias': 'web-1',
            'host': 'web-1.example.com',
            'port': 2222,
            'user': 'deploy',
          },
          // No `User` in the config, no key in the file.
          {'alias': 'bastion', 'host': 'bastion', 'port': 22},
        ],
      });
      expect(names(), [sshConfigImportsFileName], reason: 'no temp file left');

      final reopened = await SshConfigImportStore.open(file);
      expect(reopened.issue, isNull);
      // By value, ids and origin included: they derive from the alias.
      expect(reopened.entries, [_web, _bastion]);
      expect(reopened.entries.first.serverId, 'ssh-config:web-1');
      expect(() => reopened.entries.add(_web), throwsUnsupportedError);
    });

    test('what the importer produces survives a save and a reload', () async {
      final imported = fleetEntriesFromSshConfig(sshConfigFixture).entries;
      final store = await SshConfigImportStore.open(file);
      await store.replace(imported);

      final reopened = await SshConfigImportStore.open(file);
      expect(reopened.entries, imported);
      expect(reopened.entries.map((e) => e.label), sshConfigFixtureEntries);
    });

    test('each replace drops the previous set, an empty one too', () async {
      final store = await SshConfigImportStore.open(file);
      await store.replace([_web, _bastion]);
      await store.replace([_bastion]);
      expect((await SshConfigImportStore.open(file)).entries, [_bastion]);

      await store.replace(const []);
      expect(store.entries, isEmpty);
      expect((await SshConfigImportStore.open(file)).entries, isEmpty);
      expect(jsonDecode(file.readAsStringSync()), {
        'version': 1,
        'entries': <Object?>[],
      });
    });

    test('saves go through the atomic writer, whole file at once', () async {
      final writes = <(String, String)>[];
      Future<void> recordingWriter(File target, List<int> bytes) {
        writes.add((target.path, utf8.decode(bytes)));
        return writeFileAtomically(target, bytes);
      }

      final store = await SshConfigImportStore.open(
        file,
        writer: recordingWriter,
      );
      await store.replace([_web]);

      final (path, contents) = writes.single;
      expect(path, file.path);
      expect(contents, file.readAsStringSync());
    });

    test('a failed save keeps the file as it was and reports it', () async {
      final first = await SshConfigImportStore.open(file);
      await first.replace([_web]);
      final bytes = file.readAsBytesSync();

      Future<void> failingWriter(File target, List<int> contents) async {
        throw const FileSystemException('disk full');
      }

      final store = await SshConfigImportStore.open(
        file,
        writer: failingWriter,
      );
      expect(await store.replace([_bastion]), isFalse);

      expect(store.entries, [_bastion], reason: 'shown for this run');
      expect(file.readAsBytesSync(), bytes);
      expect((await SshConfigImportStore.open(file)).entries, [_web]);
    });

    group('a damaged file', () {
      final damaged = <String, List<int>>{
        'no JSON': utf8.encode('{"version": 1, "entries": ['),
        'no UTF-8': [0x7b, 0xff, 0xfe, 0x7d],
        'no object': utf8.encode('[]'),
        'no version': utf8.encode('{"entries": []}'),
        'version 0': utf8.encode('{"version": 0, "entries": []}'),
        'a string version': utf8.encode('{"version": "1", "entries": []}'),
        'no entries': utf8.encode('{"version": 1}'),
        'an entry that is no object': utf8.encode(
          '{"version": 1, "entries": ["web-1"]}',
        ),
        'an empty alias': _document([
          {'alias': '', 'host': 'h', 'port': 22},
        ]),
        'a repeated alias': _document([
          {'alias': 'a', 'host': 'h', 'port': 22},
          {'alias': 'a', 'host': 'i', 'port': 22},
        ]),
        'no host': _document([
          {'alias': 'a', 'port': 22},
        ]),
        'port 0': _document([
          {'alias': 'a', 'host': 'h', 'port': 0},
        ]),
        'port 65536': _document([
          {'alias': 'a', 'host': 'h', 'port': 65536},
        ]),
        'a string port': _document([
          {'alias': 'a', 'host': 'h', 'port': '22'},
        ]),
        'an empty user': _document([
          {'alias': 'a', 'host': 'h', 'port': 22, 'user': ''},
        ]),
      };

      for (final MapEntry(key: name, value: bytes) in damaged.entries) {
        test('holding $name is renamed aside byte for byte', () async {
          file.writeAsBytesSync(bytes);

          final store = await SshConfigImportStore.open(file, now: () => _time);

          final issue = store.issue!;
          expect(issue.kind, ImportStoreIssueKind.recovered);
          expect(issue.preservedAs, '${file.path}.corrupt-$_stamp');
          expect(issue.detail, isNotEmpty);
          expect(File(issue.preservedAs!).readAsBytesSync(), bytes);
          expect(file.existsSync(), isFalse);
          expect(store.entries, isEmpty, reason: 'all or nothing');
        });
      }

      test('frees the path, so the next import saves and loads', () async {
        file.writeAsStringSync('not json');
        final store = await SshConfigImportStore.open(file, now: () => _time);

        expect(await store.replace([_web]), isTrue);

        final reopened = await SshConfigImportStore.open(file);
        expect(reopened.issue, isNull);
        expect(reopened.entries, [_web]);
        expect(names(), [
          sshConfigImportsFileName,
          '$sshConfigImportsFileName.corrupt-$_stamp',
        ]);
      });

      test('never replaces the copy of an earlier damage', () async {
        file.writeAsStringSync('first damage');
        final first = await SshConfigImportStore.open(file, now: () => _time);
        file.writeAsStringSync('second damage');
        final second = await SshConfigImportStore.open(file, now: () => _time);

        final firstCopy = first.issue!.preservedAs!;
        final secondCopy = second.issue!.preservedAs!;
        expect(secondCopy, '$firstCopy-2');
        expect(File(firstCopy).readAsStringSync(), 'first damage');
        expect(File(secondCopy).readAsStringSync(), 'second damage');
      });

      test('stays in place when it cannot be renamed, and nothing is '
          'saved', () async {
        // A name with no room for the `.corrupt-<time>` suffix: rename(2)
        // fails with ENAMETOOLONG, whoever runs the test.
        final longName = File('${directory.path}/${'i' * 240}.json');
        longName.writeAsStringSync('not json');
        var writes = 0;
        Future<void> countingWriter(File target, List<int> bytes) {
          writes++;
          return writeFileAtomically(target, bytes);
        }

        final store = await SshConfigImportStore.open(
          longName,
          writer: countingWriter,
          now: () => _time,
        );

        expect(store.issue?.kind, ImportStoreIssueKind.leftAsIs);
        expect(store.issue?.preservedAs, isNull);
        expect(await store.replace([_web]), isFalse);
        expect(store.entries, [_web], reason: 'shown for this run');
        expect(writes, 0);
        expect(longName.readAsStringSync(), 'not json');
      });
    });

    test('an unreadable file is left alone and nothing is saved', () async {
      // A directory where the file should be: present, but not readable as
      // a file, whoever runs the test.
      Directory(file.path).createSync();
      // A write would fail on the directory too; counting shows the store
      // never tries.
      var writes = 0;
      Future<void> countingWriter(File target, List<int> bytes) {
        writes++;
        return writeFileAtomically(target, bytes);
      }

      final store = await SshConfigImportStore.open(
        file,
        writer: countingWriter,
      );

      expect(store.issue?.kind, ImportStoreIssueKind.leftAsIs);
      expect(store.issue?.detail, isNotEmpty);
      expect(await store.replace([_web]), isFalse);
      expect(writes, 0);
      expect(Directory(file.path).existsSync(), isTrue);
      expect(names(), [sshConfigImportsFileName]);
    });

    test('a newer schema is left alone and never rewritten', () async {
      file.writeAsStringSync(
        jsonEncode({
          'version': sshConfigImportsSchemaVersion + 1,
          'entries': [
            {'alias': 'a', 'host': 'h', 'port': 22, 'identityFile': '~/k'},
          ],
        }),
      );
      final bytes = file.readAsBytesSync();

      final store = await SshConfigImportStore.open(file);

      expect(store.issue?.kind, ImportStoreIssueKind.newerVersion);
      expect(store.entries, isEmpty);
      expect(await store.replace([_web]), isFalse);
      expect(file.readAsBytesSync(), bytes);
      expect(names(), [sshConfigImportsFileName]);
    });

    test('keys this build does not know are ignored', () async {
      file.writeAsBytesSync(
        _document(
          [
            {'alias': 'a', 'host': 'h', 'port': 22, 'later': true},
          ],
          extra: {'later': 1},
        ),
      );

      final store = await SshConfigImportStore.open(file);

      expect(store.issue, isNull);
      expect(store.entries, [
        importedFleetEntry(alias: 'a', host: 'h', port: 22),
      ]);
    });
  });
}

List<int> _document(
  List<Map<String, Object?>> entries, {
  Map<String, Object?> extra = const {},
}) => utf8.encode(jsonEncode({'version': 1, 'entries': entries, ...extra}));
