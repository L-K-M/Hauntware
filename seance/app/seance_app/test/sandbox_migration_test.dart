import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/macos_sandbox.dart';
import 'package:seance_app/services/sandbox_migration.dart';

/// Dropping the macOS App Sandbox moves every store the app owns. These run
/// against real directories — the thing being tested is filesystem behaviour,
/// and a fake would prove nothing about the case that matters (an interrupted
/// copy leaving an install that looks migrated but isn't).
void main() {
  const linkSkipReason = 'Requires POSIX symbolic links';
  final linkTestSkip = Platform.isMacOS || Platform.isLinux
      ? false
      : linkSkipReason;

  late Directory root;
  late Directory support;
  late Directory legacy;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('seance-migration-');
    // Registered here, not as a bare tearDown: if createTemp throws there is
    // nothing to clean up, and a tearDown that reached for `root` anyway would
    // die of a LateInitializationError — hiding the failure that actually
    // matters behind one that does not.
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    // Mirrors the real shape: staging is created beside the support directory,
    // so `support` must have a parent it can be renamed within.
    support = Directory('${root.path}/Application Support/ch.lkmc.seanceApp')
      ..createSync(recursive: true);
    legacy = Directory('${root.path}/container')..createSync(recursive: true);
  });

  SandboxMigration migration() =>
      SandboxMigration(support: support, legacySupport: legacy);

  void writeLegacy(String relativePath, String contents) {
    final file = File('${legacy.path}/$relativePath');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  String readSupport(String relativePath) =>
      File('${support.path}/$relativePath').readAsStringSync();

  group('the migration itself', () {
    test(
      'carries every store, and the checkout tree, out of the container',
      () async {
        writeLegacy('settings.json', '{"deviceId":"abc-123"}');
        writeLegacy('servers.json', '[{"id":"s1"}]');
        writeLegacy('vault.json', '{"secret-1":"blob"}');
        writeLegacy('known_hosts.json', '{}');
        writeLegacy('snippets.json', '[]');
        writeLegacy('command_stats.json', '{}');
        writeLegacy('managed_remote_files.json', '{"files":[]}');
        writeLegacy('identity_reads.jsonl', '{"path":"~/.ssh/id_ed25519"}\n');
        // Nested, because a managed edit lives under a per-session directory.
        writeLegacy('sftp-checkouts/session-1/deep/notes.txt', 'hello');

        expect(await migration().run(), SandboxMigrationOutcome.migrated);

        // deviceId is the one that matters most: it is the LWW tiebreaker, so
        // losing it re-enters this device into sync as a stranger.
        expect(jsonDecode(readSupport('settings.json'))['deviceId'], 'abc-123');
        expect(readSupport('vault.json'), '{"secret-1":"blob"}');
        expect(readSupport('sftp-checkouts/session-1/deep/notes.txt'), 'hello');
        for (final name in const [
          'servers.json',
          'known_hosts.json',
          'snippets.json',
          'command_stats.json',
          'managed_remote_files.json',
          'identity_reads.jsonl',
        ]) {
          expect(
            File('${support.path}/$name').existsSync(),
            isTrue,
            reason: name,
          );
        }
      },
    );

    test(
      'copies rather than moves, so the container is still a fallback',
      () async {
        writeLegacy('settings.json', '{}');
        expect(await migration().run(), SandboxMigrationOutcome.migrated);
        expect(File('${legacy.path}/settings.json').existsSync(), isTrue);
      },
    );

    test('leaves no staging directory behind', () async {
      writeLegacy('settings.json', '{}');
      expect(await migration().run(), SandboxMigrationOutcome.migrated);
      expect(
        Directory(
          '${support.parent.path}/${SandboxMigration.stagingName}',
        ).existsSync(),
        isFalse,
      );
    });

    test('several stray dot-files are all carried across', () async {
      // The destination is listed to completion before any of them moves:
      // renaming out of a directory that is still streaming can skip entries,
      // and one left behind would fail the rename with ENOTEMPTY — turning a
      // migration that was about to succeed into a refused launch.
      for (final name in const ['.DS_Store', '.Spotlight-V100', '.localized']) {
        File('${support.path}/$name').writeAsStringSync(name);
      }
      writeLegacy('settings.json', '{"deviceId":"abc"}');

      expect(await migration().run(), SandboxMigrationOutcome.migrated);
      expect(jsonDecode(readSupport('settings.json'))['deviceId'], 'abc');
      for (final name in const ['.DS_Store', '.Spotlight-V100', '.localized']) {
        expect(
          File('${support.path}/$name').existsSync(),
          isTrue,
          reason: name,
        );
      }
    });

    test(
      'a destination that does not exist yet is created by the rename',
      () async {
        // path_provider documents that it creates the support directory, so this
        // should not arise — but if it ever did, listing a missing directory
        // would throw and turn a perfectly migratable install into a refused
        // launch. The parent is what the rename actually needs.
        await support.delete();
        writeLegacy('settings.json', '{"deviceId":"abc"}');

        expect(await migration().run(), SandboxMigrationOutcome.migrated);
        expect(jsonDecode(readSupport('settings.json'))['deviceId'], 'abc');
      },
    );

    test('a stray dot-file does not block it, and is not destroyed', () async {
      // Someone opened ~/Library/Application Support in Finder. That must
      // neither read as "this install is in use" nor cost them the file.
      File('${support.path}/.DS_Store').writeAsStringSync('finder');
      writeLegacy('settings.json', '{"deviceId":"abc"}');

      expect(await migration().run(), SandboxMigrationOutcome.migrated);
      expect(jsonDecode(readSupport('settings.json'))['deviceId'], 'abc');
      expect(File('${support.path}/.DS_Store').existsSync(), isTrue);
    });

    test('a link inside the container is skipped, never followed', () async {
      // The container copy's documented rule: nothing in this tree creates
      // a link, so an unexpected one is not ours and is not followed —
      // chasing it could drag outside content into the published support
      // directory. The stray copy carries links instead; see 'a stray
      // directory keeps its links as links' for why the rules differ.
      File('${root.path}/outside.txt').writeAsStringSync('outside');
      writeLegacy('settings.json', '{"deviceId":"abc"}');
      Link('${legacy.path}/vault.json').createSync('${root.path}/outside.txt');

      expect(await migration().run(), SandboxMigrationOutcome.migrated);
      expect(
        FileSystemEntity.typeSync(
          '${support.path}/vault.json',
          followLinks: false,
        ),
        FileSystemEntityType.notFound,
        reason: 'the destination gets neither the link nor its target',
      );
      expect(File('${root.path}/outside.txt').readAsStringSync(), 'outside');
      // And the container is untouched, link included.
      expect(
        FileSystemEntity.typeSync(
          '${legacy.path}/vault.json',
          followLinks: false,
        ),
        FileSystemEntityType.link,
      );
    }, skip: linkTestSkip);
  });

  group('when it must not run', () {
    test('an install already using this location is left alone', () async {
      File(
        '${support.path}/settings.json',
      ).writeAsStringSync('{"deviceId":"current"}');
      writeLegacy('settings.json', '{"deviceId":"stale"}');

      expect(await migration().run(), SandboxMigrationOutcome.notNeeded);
      expect(
        jsonDecode(readSupport('settings.json'))['deviceId'],
        'current',
        reason: 'a live install must never be overwritten by a stale container',
      );
    });

    test('a fresh install with no container does nothing', () async {
      // setUp creates the container, so it has to go for this to be the
      // absent-directory branch rather than a second copy of the empty one
      // below — `exists()` false and `exists()` true-but-empty are different
      // paths through _hasData.
      await legacy.delete(recursive: true);
      expect(await migration().run(), SandboxMigrationOutcome.noLegacyData);
    });

    test('an empty container does nothing', () async {
      expect(await migration().run(), SandboxMigrationOutcome.noLegacyData);
      expect(support.listSync(), isEmpty);
    });

    test('running twice is a no-op the second time', () async {
      writeLegacy('settings.json', '{"deviceId":"abc"}');
      expect(await migration().run(), SandboxMigrationOutcome.migrated);
      // Change the container after the fact; the second run must not pick it
      // up, or a stale container would keep clobbering live data.
      writeLegacy('settings.json', '{"deviceId":"stale"}');
      expect(await migration().run(), SandboxMigrationOutcome.notNeeded);
      expect(jsonDecode(readSupport('settings.json'))['deviceId'], 'abc');
    });
  });

  group('when a previous run was interrupted', () {
    test('a leftover staging directory does not count as data', () async {
      // This is the failure the staging design exists to prevent: a partial
      // copy that reads as "already migrated" would strand the rest forever.
      final staging = Directory(
        '${support.parent.path}/${SandboxMigration.stagingName}',
      )..createSync(recursive: true);
      File('${staging.path}/settings.json').writeAsStringSync('{"half":true}');
      writeLegacy('settings.json', '{"deviceId":"abc"}');

      expect(await migration().run(), SandboxMigrationOutcome.migrated);
      expect(jsonDecode(readSupport('settings.json'))['deviceId'], 'abc');
      expect(staging.existsSync(), isFalse);
    });

    test(
      'a container that vanished first reports noLegacyData, not failure',
      () async {
        await legacy.delete(recursive: true);
        final run = SandboxMigration(support: support, legacySupport: legacy);

        expect(await run.run(), SandboxMigrationOutcome.noLegacyData);
        expect(run.error, isNull);
        expect(support.listSync(), isEmpty);
      },
    );

    test('a staging path that cannot be created reports failed', () async {
      writeLegacy('settings.json', '{}');
      // A file where the staging directory needs to go: create() throws, which
      // is the closest reliable stand-in for a full or read-only disk.
      File(
        '${support.parent.path}/${SandboxMigration.stagingName}',
      ).writeAsStringSync('not a directory');
      final run = SandboxMigration(support: support, legacySupport: legacy);

      expect(await run.run(), SandboxMigrationOutcome.failed);
      expect(run.error, isNotNull);
      expect(
        File('${support.path}/settings.json').existsSync(),
        isFalse,
        reason: 'a failed run must not leave a half-migrated install',
      );
      expect(
        File(
          '${support.parent.path}/${SandboxMigration.stagingName}',
        ).readAsStringSync(),
        'not a directory',
        reason:
            'the run aborted — whatever occupies the staging name is '
            'unknown data, never something to delete',
      );
    });

    test('a copy that dies partway leaves the destination untouched', () async {
      // The real hazard, reproduced: several files copy, then one cannot.
      // Everything the app can see must still be exactly as it was, because a
      // destination holding half an install is indistinguishable from one
      // that is simply in use — and the next launch would skip the rest.
      writeLegacy('settings.json', '{"deviceId":"abc"}');
      writeLegacy('servers.json', '[]');
      writeLegacy('vault.json', '{"secret-1":"blob"}');
      writeLegacy('sftp-checkouts/session-1/notes.txt', 'hello');

      var copied = 0;
      final run = SandboxMigration(
        support: support,
        legacySupport: legacy,
        copyFile: (from, to) async {
          if (++copied == 3) throw const FileSystemException('disk full');
          await from.copy(to);
        },
      );
      expect(await run.run(), SandboxMigrationOutcome.failed);
      expect(run.error, isNotNull);
      expect(
        support.listSync(),
        isEmpty,
        reason: 'all-or-nothing: no partial install may become visible',
      );
      expect(
        Directory(
          '${support.parent.path}/${SandboxMigration.stagingName}',
        ).existsSync(),
        isFalse,
      );
      // And the container is still whole, so the next launch can retry.
      expect(File('${legacy.path}/settings.json').existsSync(), isTrue);
    });

    test(
      'a failed publish gives the moved strays back instead of deleting them',
      () async {
        // The strays' originals are parked in a uniquely-named backup and
        // only copies reach staging, so a failed run can give them back
        // home — the staging delete is never allowed to take them.
        File('${support.path}/.DS_Store').writeAsStringSync('finder');
        Directory('${support.path}/.Spotlight-V100').createSync();
        File(
          '${support.path}/.Spotlight-V100/index.db',
        ).writeAsStringSync('spotlight');
        writeLegacy('settings.json', '{"deviceId":"abc"}');

        final run = SandboxMigration(
          support: support,
          legacySupport: legacy,
          publish: (_, __) => throw const FileSystemException('ENOTEMPTY'),
        );
        expect(await run.run(), SandboxMigrationOutcome.failed);
        expect(
          File('${support.path}/.DS_Store').readAsStringSync(),
          'finder',
          reason: 'a stray that was already moved must come home',
        );
        expect(
          File('${support.path}/.Spotlight-V100/index.db').readAsStringSync(),
          'spotlight',
          reason: 'a stray directory restores whole',
        );
        expect(
          Directory(
            '${support.parent.path}/${SandboxMigration.stagingName}',
          ).existsSync(),
          isFalse,
          reason: 'no staging left to misread on the next launch',
        );
        expect(
          run.backup.existsSync(),
          isFalse,
          reason: 'a backup that gave everything back has no reason to stay',
        );
        expect(
          File('${legacy.path}/settings.json').existsSync(),
          isTrue,
          reason: 'the container is still the fallback it promised to be',
        );

        // The retry then carries the same strays across with the data.
        expect(await migration().run(), SandboxMigrationOutcome.migrated);
        expect(jsonDecode(readSupport('settings.json'))['deviceId'], 'abc');
        expect(File('${support.path}/.DS_Store').existsSync(), isTrue);
        expect(
          File('${support.path}/.Spotlight-V100/index.db').existsSync(),
          isTrue,
        );
      },
    );

    test(
      'a newcomer claiming a stray\'s name mid-run is never overwritten',
      () async {
        File('${support.path}/.DS_Store').writeAsStringSync('original');
        writeLegacy('settings.json', '{"deviceId":"abc"}');

        // The Finder-write the publish rename is documented to race: the
        // stray's name is claimed again before the run can fail.
        final run = SandboxMigration(
          support: support,
          legacySupport: legacy,
          publish: (_, __) {
            File('${support.path}/.DS_Store').writeAsStringSync('newcomer');
            throw const FileSystemException('ENOTEMPTY');
          },
        );
        expect(await run.run(), SandboxMigrationOutcome.failed);

        // The newcomer wins the name — the restore must not touch it.
        expect(
          File('${support.path}/.DS_Store').readAsStringSync(),
          'newcomer',
        );
        expect(
          File('${run.backup.path}/.DS_Store').readAsStringSync(),
          'original',
          reason: 'an unrestored stray is kept, never deleted with staging',
        );
        expect(
          Directory(
            '${support.parent.path}/${SandboxMigration.stagingName}',
          ).existsSync(),
          isFalse,
        );

        // And the next run's cleanup does not own the backup either: the
        // newcomer is carried across while the original stays recoverable.
        expect(await migration().run(), SandboxMigrationOutcome.migrated);
        expect(
          File('${support.path}/.DS_Store').readAsStringSync(),
          'newcomer',
          reason: 'the second run carries the name\'s current owner',
        );
        expect(
          File('${run.backup.path}/.DS_Store').readAsStringSync(),
          'original',
          reason: 'the leftover backup survives the relaunch untouched',
        );
      },
    );

    test(
      'a run interrupted after moving strays leaves them recoverable',
      () async {
        // As a previous run left it when the process died mid-move: the
        // staged copy under the staging name, and the original inside a
        // uniquely-named backup. The next launch owns the staging name —
        // the backup is never its cleanup's business. The backup path comes
        // from a sibling run's own field, so a rename upstream breaks this
        // test loudly instead of letting it pass against a name nothing
        // writes anymore.
        final staleStaging = Directory(
          '${support.parent.path}/${SandboxMigration.stagingName}',
        )..createSync();
        File('${staleStaging.path}/.DS_Store').writeAsStringSync('stale copy');
        final abandoned = migration().backup..createSync();
        File('${abandoned.path}/.DS_Store').writeAsStringSync('original');
        writeLegacy('settings.json', '{"deviceId":"abc"}');

        expect(await migration().run(), SandboxMigrationOutcome.migrated);
        expect(
          staleStaging.existsSync(),
          isFalse,
          reason: 'stale staging is dropped — it only ever held copies',
        );
        expect(
          File('${abandoned.path}/.DS_Store').readAsStringSync(),
          'original',
          reason: 'the abandoned backup is user data, not scratch',
        );
        expect(jsonDecode(readSupport('settings.json'))['deviceId'], 'abc');
      },
    );

    test('a stray directory keeps its links as links', () async {
      // The stray tree is the user's, not the app's — the container copy's
      // "skip unexpected links" rule does not apply. A link inside a stray
      // is carried as a link: never followed, never dropped.
      File('${root.path}/outside.txt').writeAsStringSync('outside');
      Directory('${support.path}/.Spotlight-V100').createSync();
      File(
        '${support.path}/.Spotlight-V100/index.db',
      ).writeAsStringSync('spotlight');
      Link(
        '${support.path}/.Spotlight-V100/alias',
      ).createSync('${root.path}/outside.txt');
      writeLegacy('settings.json', '{"deviceId":"abc"}');

      expect(await migration().run(), SandboxMigrationOutcome.migrated);

      final alias = Link('${support.path}/.Spotlight-V100/alias');
      expect(
        FileSystemEntity.typeSync(alias.path, followLinks: false),
        FileSystemEntityType.link,
        reason: 'the destination gets the user\'s link, not a copy or a loss',
      );
      expect(await alias.target(), '${root.path}/outside.txt');
      expect(File('${root.path}/outside.txt').readAsStringSync(), 'outside');
      expect(
        File('${support.path}/.Spotlight-V100/index.db').readAsStringSync(),
        'spotlight',
      );
    }, skip: linkTestSkip);
  });

  group('choosing where to migrate from', () {
    test('derives the container path from the support directory', () {
      final resolved = SandboxMigration.forSupportDirectory(
        Directory('/Users/ada/Library/Application Support/ch.lkmc.seanceApp'),
        home: '/Users/ada',
        isMacOS: true,
      );
      expect(
        resolved!.legacySupport.path,
        '/Users/ada/Library/Containers/ch.lkmc.seanceApp/Data'
        '/Library/Application Support/ch.lkmc.seanceApp',
      );
    });

    test('stages beside the support directory, never inside it', () {
      // Inside would mean the destination is non-empty during the copy, which
      // both defeats the atomic rename and risks reading as "already in use".
      final resolved = SandboxMigration.forSupportDirectory(
        Directory('/Users/ada/Library/Application Support/ch.lkmc.seanceApp'),
        home: '/Users/ada',
        isMacOS: true,
      );
      expect(
        resolved!.staging.path,
        '/Users/ada/Library/Application Support/'
        '${SandboxMigration.stagingName}',
      );
    });

    test('is skipped off macOS, where no container ever existed', () {
      expect(
        SandboxMigration.forSupportDirectory(
          Directory('/home/ada/.local/share/seance'),
          home: '/home/ada',
          isMacOS: false,
        ),
        isNull,
      );
    });

    test('is skipped when there is no home to look under', () {
      expect(
        SandboxMigration.forSupportDirectory(
          Directory('/Users/ada/Library/Application Support/ch.lkmc.seanceApp'),
          home: '',
          isMacOS: true,
        ),
        isNull,
      );
    });
  });

  group('sandbox detection', () {
    test('reads the container variable, and only on macOS', () {
      const inside = {'APP_SANDBOX_CONTAINER_ID': 'ch.lkmc.seanceApp'};
      expect(macOsSandboxed(environment: inside, isMacOS: true), isTrue);
      expect(macOsSandboxed(environment: const {}, isMacOS: true), isFalse);
      expect(macOsSandboxed(environment: inside, isMacOS: false), isFalse);
    });
  });
}
