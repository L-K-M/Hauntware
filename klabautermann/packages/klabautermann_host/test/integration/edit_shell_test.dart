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
const _token = 'feedfacefeedface';

/// The octal permission bits of [path].
String _mode(String path) =>
    (File(path).statSync().mode & 0x1ff).toRadixString(8);

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
        temp = EditCommands.tempPathFor(target, _token);
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

      test('the manifest is written whole and verified by sha256sum', () async {
        final manifest = '${dir.path}/config/klabautermann/manifest.json';
        final write = await run(
          EditCommands.manifestWrite(manifest),
          stdin: '{"v":1}',
        );
        expect(write.exitCode, 0, reason: '${write.stderr}');
        expect(File(manifest).readAsStringSync(), '{"v":1}');
        expect(
          File(manifest).parent.listSync().map((e) => e.path),
          isNot(contains(contains('klabautermann-tmp'))),
        );

        final read = await run(EditCommands.manifestRead(manifest));
        expect(read.stdout, '{"v":1}');

        final sums = await run(
          EditCommands.sha256List([manifest, '${dir.path}/gone']),
        );
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
