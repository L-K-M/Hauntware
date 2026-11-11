// The edit pipeline's scripts through real shells (03 §8.5, D67): each
// installed shell (dash, bash, mksh, BusyBox ash) runs the builders' argv
// over a scratch directory, as the login user, with GNU coreutils; the
// symlink reads run with BusyBox's applets too where BusyBox is
// installed. Stand-ins first on
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
  final path = Platform.environment['PATH'] ?? '';
  for (final dir in ['/bin', '/usr/bin', ...path.split(':')]) {
    if (dir.isEmpty) continue;
    final f = File('$dir/$name');
    if (f.existsSync()) return f.path;
  }
  return null;
}

final _busybox = _which('busybox');

/// Each installed shell, as the words that start it.
final _shells = <String, List<String>>{
  for (final name in ['dash', 'bash', 'mksh'])
    if (_which(name) case final p?) name: [p],
  if (_busybox case final p?) 'busybox ash': [p, 'sh'],
};

/// The tools a symlink read runs with: GNU's, and BusyBox's applets.
const _tools = ['gnu', 'busybox'];

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
        final process = await Process.start(
          argv.first == 'sh' ? shell.first : argv.first,
          [if (argv.first == 'sh') ...shell.skip(1), ...argv.sublist(1)],
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

      /// Why a test that stands in for [tools] on PATH cannot run here: the
      /// shell runs its own (mksh's `realpath`, or a BusyBox built to run
      /// its applets before PATH), or null.
      String? ownTools(List<String> tools) {
        for (final tool in tools) {
          final found =
              Process.runSync(shell.first, [
                    ...shell.skip(1),
                    '-c',
                    'command -v $tool',
                  ]).stdout
                  as String;
          if (found.trim().isNotEmpty && !found.startsWith('/')) {
            return '$name runs its own $tool';
          }
        }
        return null;
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
            path: File(target).resolveSymbolicLinksSync(),
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

      /// Puts BusyBox's applets for what the read runs first on PATH.
      void busyboxTools() {
        for (final tool in ['readlink', 'realpath', 'stat', 'sha256sum']) {
          Link('${shims.path}/$tool').createSync(_busybox!);
        }
      }

      for (final tools in _tools) {
        final skip = tools == 'busybox' && _busybox == null
            ? 'BusyBox is not installed'
            : null;

        test('$tools: a read through a link names the real file, and the '
            'write through that name leaves the link a link', () async {
          if (tools == 'busybox') busyboxTools();
          final real = '${dir.path}/real.conf';
          File(real).writeAsStringSync('real\n');
          Process.runSync('chmod', ['0604', real]);
          final link = '${dir.path}/link.conf';
          Link(link).createSync('real.conf');
          final resolved = File(real).resolveSymbolicLinksSync();

          final read = await run(EditCommands.readFile(link));
          expect(read.exitCode, 0, reason: '${read.stderr}');
          final out = read.stdout as String;
          final header = parseReadHeader(out.substring(0, out.indexOf('\n')));
          expect(header?.path, resolved);
          expect(header?.mode, 0x184);
          expect(out.substring(out.indexOf('\n') + 1), 'real\n');

          final realTemp = EditCommands.tempPathFor(resolved, _tempId);
          await run(EditCommands.writeTemp(realTemp), stdin: 'edited\n');
          await run(EditCommands.copyAttributes(resolved, realTemp));
          final swap = await run(
            EditCommands.replaceIfHash(resolved, realTemp, header!.sha256),
          );
          expect(swap.exitCode, 0, reason: '${swap.stderr}');
          expect(FileSystemEntity.isLinkSync(link), isTrue);
          expect(File(link).readAsStringSync(), 'edited\n');
          expect(_mode(real), '604');
        }, skip: skip);

        test('$tools: a linked directory, a relative link up a level and a '
            'chain of links each resolve to the real file', () async {
          if (tools == 'busybox') busyboxTools();
          Directory('${dir.path}/real/sub').createSync(recursive: true);
          final real = '${dir.path}/real/sub/app.conf';
          File(real).writeAsStringSync('x\n');
          final resolved = File(real).resolveSymbolicLinksSync();
          Link('${dir.path}/linked').createSync('real/sub');
          Link('${dir.path}/real/up.conf').createSync('sub/app.conf');
          Link('${dir.path}/real/sub/down').createSync('..');
          Link('${dir.path}/a.conf').createSync('b.conf');
          Link('${dir.path}/b.conf').createSync('${dir.path}/real/up.conf');

          for (final path in [
            '${dir.path}/linked/app.conf',
            '${dir.path}/real/sub/down/sub/app.conf',
            '${dir.path}/a.conf',
          ]) {
            final read = await run(EditCommands.readFile(path));
            expect(read.exitCode, 0, reason: '$path: ${read.stderr}');
            final out = read.stdout as String;
            expect(
              parseReadHeader(out.substring(0, out.indexOf('\n')))?.path,
              resolved,
              reason: path,
            );
          }
        }, skip: skip);

        test('$tools: a dangling link reads as missing, and a retargeted '
            'link reads as its new file', () async {
          if (tools == 'busybox') busyboxTools();
          final link = '${dir.path}/link.conf';
          Link(link).createSync('gone.conf');
          final dangling = await run(EditCommands.readFile(link));
          expect(dangling.exitCode, isNot(0));
          expect(dangling.stderr, contains('No such file'));

          File('${dir.path}/one.conf').writeAsStringSync('1\n');
          File('${dir.path}/two.conf').writeAsStringSync('2\n');
          Link(link).updateSync('one.conf');
          String? pathOf(ProcessResult read) =>
              parseReadHeader((read.stdout as String).split('\n').first)?.path;
          final first = pathOf(await run(EditCommands.readFile(link)));
          Link(link).updateSync('two.conf');
          final second = pathOf(await run(EditCommands.readFile(link)));
          expect(first, endsWith('/one.conf'));
          expect(second, endsWith('/two.conf'));
        }, skip: skip);
      }

      test('without readlink -f or realpath a link is refused, and a file '
          'reads as it is', () async {
        shim('readlink', 'exit 1');
        shim('realpath', 'exit 1');
        final real = '${dir.path}/real.conf';
        File(real).writeAsStringSync('real\n');
        final link = '${dir.path}/link.conf';
        Link(link).createSync('real.conf');

        final refused = await run(EditCommands.readFile(link));
        expect(refused.exitCode, EditExit.symlink, reason: '${refused.stderr}');
        expect(refused.stdout, '');

        final plain = await run(EditCommands.readFile(real));
        expect(plain.exitCode, 0, reason: '${plain.stderr}');
        expect(
          parseReadHeader((plain.stdout as String).split('\n').first)?.path,
          real,
        );
      }, skip: ownTools(['readlink', 'realpath']));

      test('the swap refuses a real file that has become a link', () async {
        final real = '${dir.path}/real.conf';
        File(real).writeAsStringSync('real\n');
        final hash = _sha256Of(real);
        final realTemp = EditCommands.tempPathFor(real, _tempId);
        await run(EditCommands.writeTemp(realTemp), stdin: 'edited\n');
        File(real).renameSync('${dir.path}/moved.conf');
        Link(real).createSync('moved.conf');

        final swap = await run(
          EditCommands.replaceIfHash(real, realTemp, hash),
        );
        expect(swap.exitCode, EditExit.symlink);
        expect(FileSystemEntity.isLinkSync(real), isTrue);
        expect(File('${dir.path}/moved.conf').readAsStringSync(), 'real\n');
        expect(File(realTemp).existsSync(), isFalse);
      });

      test('the root-only check resolves the directory and refuses one '
          'another account could write', () async {
        final safe = await run(
          EditCommands.rootOnlyDirectory('/etc/klabautermann-none.conf'),
        );
        expect(safe.exitCode, 0, reason: '${safe.stderr}');
        expect(safe.stdout, '/etc\n');

        // The scratch directory is under the sticky, world-writable /tmp.
        final open = await run(EditCommands.rootOnlyDirectory(target));
        expect(open.exitCode, EditExit.userWritableDirectory);

        // A link to a root-only directory resolves to it: the steps then
        // write there, never through the link.
        Link('${dir.path}/etc').createSync('/etc');
        final linked = await run(
          EditCommands.rootOnlyDirectory('${dir.path}/etc/app.conf'),
        );
        expect(linked.exitCode, 0, reason: '${linked.stderr}');
        expect(linked.stdout, '/etc\n');

        // Owners and modes the scratch host cannot make, through `stat`.
        for (final (owner, verdict) in [
          ('1000 755', EditExit.userWritableDirectory),
          ('0 775', EditExit.userWritableDirectory),
          ('0 757', EditExit.userWritableDirectory),
          ('0 1777', EditExit.userWritableDirectory),
          ('0 7', EditExit.userWritableDirectory),
          ('0 2755', 0),
          ('0 750', 0),
        ]) {
          shim(
            'stat',
            'case \$4 in /etc) echo "$owner" ;; '
                '*) exec /usr/bin/stat "\$@" ;; esac',
          );
          final checked = await run(
            EditCommands.rootOnlyDirectory('/etc/app.conf'),
          );
          expect(checked.exitCode, verdict, reason: owner);
        }
      }, skip: ownTools(['stat']));

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
      }, skip: ownTools(['mv']));

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
        skip: ownTools(['crontab']),
      );

      test('a crontab backup leaves another run\'s temps alone', () async {
        // Two devices may back up crontabs into one directory at once
        // (root's, in admin mode). Directories stand in for the other
        // run's temps: a shared temp name would write into them or fail.
        shim('crontab', r'printf "0 3 * * * a\n"');
        final backups = '${dir.path}/state$kBackupsDirSuffix';
        for (final name in ['.crontab.tmp', '.index.tmp']) {
          Directory('$backups/$name').createSync(recursive: true);
        }

        final backup = await run(
          EditCommands.crontabBackup(backups, indexName: 'crontab:deploy'),
        );
        expect(backup.exitCode, 0, reason: '${backup.stderr}');
        expect(
          File((backup.stdout as String).trim()).readAsStringSync(),
          '0 3 * * * a\n',
        );
        expect(
          File('$backups/$kEditBackupIndexName').readAsStringSync(),
          endsWith('\tcrontab:deploy\n'),
        );
        expect(
          Directory(backups).listSync().map((e) => e.path.split('/').last),
          isNot(contains(matches(r'^\.(crontab|index)\.tmp\..'))),
        );
      }, skip: ownTools(['crontab']));

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
