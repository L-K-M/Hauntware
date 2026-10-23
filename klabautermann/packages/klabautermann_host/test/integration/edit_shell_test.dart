// The edit pipeline's scripts through real shells (03 §8.5, D67): each
// installed shell (dash, bash) runs the builders' argv over a scratch
// directory, as the login user, with GNU coreutils. Stand-ins first on
// PATH play BusyBox's `cp`, which refuses `--attributes-only`, and the
// `getfacl` and `getfattr` of a target that carries an ACL entry or an
// xattr. Tagged `shell`; a shell that is not installed gets no tests.
@Tags(['shell'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

String? _which(String name) {
  for (final dir in ['/bin', '/usr/bin']) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f.path;
  }
  return null;
}

final _shells = <String, String>{
  for (final name in ['dash', 'bash'])
    if (_which(name) case final p?) name: p,
};

// Low entropy, so the secret scan does not read it as a key.
const _tempId = 'feedfacefeedface';

/// The octal permission bits of [path].
String _mode(String path) =>
    (File(path).statSync().mode & 0x1ff).toRadixString(8);

/// SHA-256 of the empty text: what an absent file reads as.
const _emptySha256 =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

String _sha256Of(String path) =>
    (Process.runSync('sha256sum', [path]).stdout as String).split(' ').first;

void main() {
  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    group(name, () {
      late Directory dir;
      late Directory shims;
      late String target;
      late String temp;

      setUp(() {
        dir = Directory.systemTemp.createTempSync('klab-edit-');
        shims = Directory('${dir.path}/shims')..createSync();
        addTearDown(() => dir.deleteSync(recursive: true));
        target = '${dir.path}/app.conf';
        File(target).writeAsStringSync('original\n');
        Process.runSync('chmod', ['0640', target]);
        temp = EditCommands.tempPathFor(target, _tempId);
      });

      /// Runs [argv] with [shell] as its `sh` and [stdin], with the shims
      /// first on PATH.
      Future<ProcessResult> run(List<String> argv, {String? stdin}) async {
        final executable = argv.first == 'sh' ? shell : argv.first;
        final process = await Process.start(
          executable,
          argv.sublist(1),
          environment: {
            'PATH': '${shims.path}:${Platform.environment['PATH'] ?? ''}',
            'LC_ALL': 'C',
          },
        );
        // A refused command exits without reading its input, and the
        // write then races its exit into a broken pipe; its exit code
        // and stderr are what the test reads.
        try {
          process.stdin.write(stdin ?? '');
          await process.stdin.close();
        } on SocketException {
          // The command closed its stdin first.
        }
        final out = process.stdout.transform(utf8.decoder).join();
        final err = process.stderr.transform(utf8.decoder).join();
        return ProcessResult(
          process.pid,
          await process.exitCode,
          await out,
          await err,
        );
      }

      /// A stand-in for [tool] that runs [body] as its script.
      void shim(String tool, String body) {
        final file = File('${shims.path}/$tool')
          ..writeAsStringSync('#!/bin/sh\n$body\n');
        Process.runSync('chmod', ['0755', file.path]);
      }

      void busyboxCp() => shim(
        'cp',
        'for a in "\$@"; do case \$a in --attributes-only) '
            'echo "cp: unrecognized option" >&2; exit 1;; esac; done; '
            'exec /bin/cp "\$@"',
      );

      test(
        'a read prints size and hash, then the content within the cap',
        () async {
          final read = await run(EditCommands.readFile(target));
          expect(read.exitCode, 0, reason: '${read.stderr}');
          final lines = (read.stdout as String).split('\n');
          final ids =
              (Process.runSync('stat', ['-c', '%u %g', target]).stdout
                      as String)
                  .trim()
                  .split(' ');
          expect(parseReadHeader(lines.first), (
            size: 9,
            uid: int.parse(ids[0]),
            gid: int.parse(ids[1]),
            mode: 416,
            sha256: _sha256Of(target),
          ));
          expect(lines.skip(1).join('\n'), 'original\n');

          final capped = await run(EditCommands.readFile(target, cap: 4));
          expect(
            capped.stdout,
            '${lines.first}\n',
            reason: 'the header alone past the cap',
          );

          final missing = await run(
            EditCommands.readFile('${dir.path}/missing'),
          );
          expect(missing.exitCode, isNot(0));
        },
      );

      test('a write, its attributes and the swap replace the target', () async {
        final hash = _sha256Of(target);
        final write = await run(
          EditCommands.writeTemp(temp),
          stdin: 'edited\n',
        );
        expect(write.exitCode, 0, reason: '${write.stderr}');
        expect(_mode(temp), '600');

        final again = await run(EditCommands.writeTemp(temp), stdin: 'x');
        expect(again.exitCode, isNot(0), reason: 'a temp is never reused');
        expect(File(temp).readAsStringSync(), 'edited\n');

        final attributes = await run(EditCommands.copyAttributes(target, temp));
        expect(attributes.exitCode, 0, reason: '${attributes.stderr}');
        expect(_mode(temp), '640');

        final swap = await run(EditCommands.replaceIfHash(target, temp, hash));
        expect(swap.exitCode, 0, reason: '${swap.stderr}');
        expect(File(target).readAsStringSync(), 'edited\n');
        expect(_mode(target), '640');
        expect(File(temp).existsSync(), isFalse);
      });

      test('a changed target is never replaced, and the temp goes', () async {
        final hash = _sha256Of(target);
        await run(EditCommands.writeTemp(temp), stdin: 'edited\n');
        File(target).writeAsStringSync('someone else\n');

        final swap = await run(EditCommands.replaceIfHash(target, temp, hash));
        expect(swap.exitCode, EditExit.hashMismatch);
        expect(File(target).readAsStringSync(), 'someone else\n');
        expect(File(temp).existsSync(), isFalse);
      });

      test('a failed rename removes the temp', () async {
        final hash = _sha256Of(target);
        await run(EditCommands.writeTemp(temp), stdin: 'edited\n');
        shim('mv', 'exit 1');

        final swap = await run(EditCommands.replaceIfHash(target, temp, hash));
        expect(swap.exitCode, 1);
        expect(File(target).readAsStringSync(), 'original\n');
        expect(File(temp).existsSync(), isFalse);
      });

      test(
        'without cp --attributes-only, stat carries owner and mode',
        () async {
          busyboxCp();
          await run(EditCommands.writeTemp(temp), stdin: 'edited\n');

          final attributes = await run(
            EditCommands.copyAttributes(target, temp),
          );
          expect(attributes.exitCode, 0, reason: '${attributes.stderr}');
          expect(_mode(temp), '640');
        },
      );

      test('the fallback refuses a target with an ACL entry or an xattr, '
          'but not one with only a label', () async {
        busyboxCp();
        await run(EditCommands.writeTemp(temp), stdin: 'edited\n');

        shim(
          'getfacl',
          r"printf 'user::rw-\nuser:klab:r--\ngroup::r--\nmask::r--\nother::---\n\n'",
        );
        final acl = await run(EditCommands.copyAttributes(target, temp));
        expect(acl.exitCode, EditExit.aclNotCarried);

        // A getfacl that fails says nothing about the ACL, so it refuses.
        shim('getfacl', 'exit 1');
        final failed = await run(EditCommands.copyAttributes(target, temp));
        expect(failed.exitCode, EditExit.aclNotCarried);

        shim('getfacl', r"printf 'user::rw-\ngroup::r--\nother::---\n\n'");
        shim('getfattr', r"""printf '# file: x\nuser.klab="spike"\n\n'""");
        final xattr = await run(EditCommands.copyAttributes(target, temp));
        expect(xattr.exitCode, EditExit.xattrNotCarried);

        shim(
          'getfattr',
          r"""printf '# file: x\nsecurity.selinux="system_u:object_r:etc_t:s0"\n\n'""",
        );
        final label = await run(EditCommands.copyAttributes(target, temp));
        expect(label.exitCode, 0, reason: '${label.stderr}');
        expect(_mode(temp), '640');
      });

      test('a backup copies the target and appends to the index', () async {
        final backups = '${dir.path}/state$kBackupsDirSuffix';
        final hash = _sha256Of(target);

        final first = await run(EditCommands.backupFile(target, backups));
        expect(first.exitCode, 0, reason: '${first.stderr}');
        final copy = (first.stdout as String).trim();
        expect(copy, startsWith('$backups/$hash-'));
        expect(File(copy).readAsStringSync(), 'original\n');
        expect(_mode(backups), '700');

        File(target).writeAsStringSync('edited\n');
        final second = await run(EditCommands.backupFile(target, backups));
        expect(second.exitCode, 0, reason: '${second.stderr}');
        final index = File(
          '$backups/$kEditBackupIndexName',
        ).readAsLinesSync().map((l) => l.split('\t')).toList();
        expect(index.map((f) => (f[1], f[2])), [
          (hash, target),
          (_sha256Of(target), target),
        ]);
        expect(
          Directory(backups).listSync().map((e) => e.path),
          isNot(contains(contains('.tmp'))),
        );
      });

      test(
        'a crontab is swapped only while its hash holds, and backed up',
        () async {
          // A stand-in crontab keeping its table in a file: `-l` prints it
          // or fails as an absent crontab does, `-` replaces it from stdin.
          final table = '${dir.path}/crontab';
          shim(
            'crontab',
            'f=${dir.path}/crontab; '
                r'for a in "$@"; do case $a in '
                r'-l) [ -f "$f" ] && exec cat "$f"; echo "no crontab" >&2; exit 1;; '
                r'-) exec cat > "$f";; esac; done; exit 2',
          );
          String sha(String text) =>
              (Process.runSync('sh', [
                        '-c',
                        'printf %s "\$1" | sha256sum',
                        'sh',
                        text,
                      ]).stdout
                      as String)
                  .split(' ')
                  .first;

          final first = await run(
            EditCommands.crontabWriteIfHash(sha('')),
            stdin: '0 3 * * * a\n',
          );
          expect(first.exitCode, 0, reason: '${first.stderr}');
          expect(File(table).readAsStringSync(), '0 3 * * * a\n');

          final stale = await run(
            EditCommands.crontabWriteIfHash(sha('')),
            stdin: 'lost\n',
          );
          expect(stale.exitCode, EditExit.hashMismatch);
          expect(File(table).readAsStringSync(), '0 3 * * * a\n');

          final backups = '${dir.path}/state$kBackupsDirSuffix';
          final backup = await run(
            EditCommands.crontabBackup(backups, indexName: 'crontab:deploy'),
          );
          expect(backup.exitCode, 0, reason: '${backup.stderr}');
          final copy = (backup.stdout as String).trim();
          expect(File(copy).readAsStringSync(), '0 3 * * * a\n');
          expect(
            File('$backups/$kEditBackupIndexName').readAsStringSync(),
            endsWith('\t${sha('0 3 * * * a\n')}\tcrontab:deploy\n'),
          );

          final next = await run(
            EditCommands.crontabWriteIfHash(sha('0 3 * * * a\n')),
            stdin: '0 4 * * * a\n',
          );
          expect(next.exitCode, 0, reason: '${next.stderr}');
          expect(File(table).readAsStringSync(), '0 4 * * * a\n');
        },
      );

      test('the user backup directory resolves under XDG_STATE_HOME', () async {
        final resolved = await run(EditCommands.userBackupsDir());
        expect(
          (resolved.stdout as String).trim(),
          endsWith('/.local/state/klabautermann/backups'),
        );
      });

      test('an index is rewritten only while its hash holds; presence and '
          'an absent manifest read cleanly', () async {
        final backups = '${dir.path}/state$kBackupsDirSuffix';
        Directory(backups).createSync(recursive: true);
        final index = File('$backups/$kEditBackupIndexName')
          ..writeAsStringSync('1\ta\t/x\n');

        final stale = await run(
          EditCommands.backupIndexWrite(backups, _sha256Of(target)),
          stdin: '',
        );
        expect(stale.exitCode, EditExit.hashMismatch);
        expect(index.readAsStringSync(), '1\ta\t/x\n');

        final fresh = await run(
          EditCommands.backupIndexWrite(backups, _sha256Of(index.path)),
          stdin: '2\tb\t/y\n',
        );
        expect(fresh.exitCode, 0, reason: '${fresh.stderr}');
        expect(index.readAsStringSync(), '2\tb\t/y\n');

        final present = await run(
          EditCommands.existingPaths([backups, '${dir.path}/gone', index.path]),
        );
        expect(present.exitCode, 0);
        expect((present.stdout as String).trim().split('\n'), [
          backups,
          index.path,
        ]);

        final manifest = await run(
          EditCommands.manifestRead('${dir.path}/c$kManifestSuffix'),
        );
        expect(manifest.exitCode, 0);
        expect(manifest.stdout, '');
      });

      test('the manifest is written whole and verified by sha256sum', () async {
        final manifest = '${dir.path}/config/klabautermann/manifest.json';
        // An absent manifest hashes as the empty read.
        final write = await run(
          EditCommands.manifestWrite(manifest, _emptySha256),
          stdin: '{"v":1}',
        );
        expect(write.exitCode, 0, reason: '${write.stderr}');
        expect(File(manifest).readAsStringSync(), '{"v":1}');

        // A manifest that changed since the read is left as it is.
        final stale = await run(
          EditCommands.manifestWrite(manifest, _emptySha256),
          stdin: '{"v":2}',
        );
        expect(stale.exitCode, EditExit.hashMismatch);
        expect(File(manifest).readAsStringSync(), '{"v":1}');
        expect(
          File(manifest).parent.listSync().map((e) => e.path),
          isNot(contains(contains('klabautermann-tmp'))),
        );

        // One that exists but cannot be read never passes for absent: a
        // directory at the path once hashed as empty and took the file.
        final blockedManifest =
            '${dir.path}/blocked/config/klabautermann/manifest.json';
        final blockedBackups = '${dir.path}/blocked$kBackupsDirSuffix';
        final targets = {
          blockedManifest: EditCommands.manifestWrite(
            blockedManifest,
            _emptySha256,
          ),
          '$blockedBackups/$kEditBackupIndexName':
              EditCommands.backupIndexWrite(blockedBackups, _emptySha256),
        };
        for (final MapEntry(key: path, value: write) in targets.entries) {
          Directory(path).createSync(recursive: true);
          final refused = await run(write, stdin: '{"v":3}');
          expect(refused.exitCode, isNot(0), reason: path);
          expect(refused.exitCode, isNot(EditExit.hashMismatch), reason: path);
          expect(Directory(path).listSync(), isEmpty, reason: path);
        }

        final read = await run(EditCommands.manifestRead(manifest));
        expect(read.stdout, '{"v":1}');

        final sums = await run(
          EditCommands.sha256List([manifest, '${dir.path}/gone']),
        );
        // A gone path is left out, not a failure.
        expect(sums.exitCode, 0);
        expect(parseSha256List(sums.stdout as String), {
          manifest: _sha256Of(manifest),
        });
      });
    });
  }

  test('at least one shell is installed', () {
    expect(_shells, isNotEmpty);
  });
}
