@TestOn('linux')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'repository_root.dart';

// scripts/flatpak-repack.sh, sourced the way each product's
// build-flatpak.sh sources it. Only the parts that need no flatpak run
// here: staging a .deb and the smoke check the built sandbox runs.
void main() {
  late Directory sandbox;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('hauntware-flatpak-test-');
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  group('smoke check', () {
    late Directory prefix;

    setUp(() {
      prefix = Directory(p.join(sandbox.path, 'app'))..createSync();
    });

    void writeExecutable(String relative, String contents) {
      final file = File(p.join(prefix.path, relative))
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);
      Process.runSync('chmod', ['+x', file.path]);
    }

    void writeWrapper(String target) =>
        writeExecutable('bin/demo', '#!/bin/sh\nexec $target "\$@"\n');

    void copyRealBinary() {
      final binary = File(p.join(prefix.path, 'lib/demo/demo_app'))
        ..parent.createSync(recursive: true);
      File('/bin/true').copySync(binary.path);
    }

    test('follows the wrapper to a binary whose libraries resolve', () async {
      copyRealBinary();
      writeWrapper(p.join(prefix.path, 'lib/demo/demo_app'));

      final result = await _smokeCheck(prefix, 'demo');

      expect(result.exitCode, 0, reason: result.stderr as String);
    });

    test('fails when the wrapper runs a binary that is missing', () async {
      // A /usr path the remap missed.
      writeWrapper('/usr/lib/demo/demo_app');

      final result = await _smokeCheck(prefix, 'demo');

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('/usr/lib/demo/demo_app'));
    });

    test('fails when the real binary links an unresolved library', () async {
      // The wrapper itself is no ELF: an ldd of it alone finds nothing.
      copyRealBinary();
      writeWrapper(p.join(prefix.path, 'lib/demo/demo_app'));
      final bin = Directory(p.join(sandbox.path, 'fake-bin'))..createSync();
      // The real ldd for everything but the bundle's binary, which misses
      // a library.
      // Resolved before the stub shadows it on PATH.
      final realLdd =
          (Process.runSync('bash', ['-c', 'command -v ldd']).stdout as String)
              .trim();
      final ldd = File(p.join(bin.path, 'ldd'))
        ..writeAsStringSync(
          '#!/bin/sh\n'
          'case "\$1" in\n'
          '  */demo_app) printf "\\tlibgtk-3.so.0 => not found\\n" ;;\n'
          '  *) exec $realLdd "\$@" ;;\n'
          'esac\n',
        );
      Process.runSync('chmod', ['+x', ldd.path]);

      final result = await _smokeCheck(
        prefix,
        'demo',
        path: '${bin.path}:${Platform.environment['PATH']}',
      );

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('libgtk-3.so.0 => not found'));
    });

    test('fails when the wrapper runs something ldd cannot read', () async {
      writeExecutable('lib/demo/demo_app', '#!/bin/sh\nexit 0\n');
      writeWrapper(p.join(prefix.path, 'lib/demo/demo_app'));

      final result = await _smokeCheck(prefix, 'demo');

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('ldd cannot read'));
    });

    test('checks a command that is itself the binary', () async {
      final binary = File(p.join(prefix.path, 'bin/demo'))
        ..parent.createSync(recursive: true);
      File('/bin/true').copySync(binary.path);

      final result = await _smokeCheck(prefix, 'demo');

      expect(result.exitCode, 0, reason: result.stderr as String);
    });

    test('fails when the command is missing', () async {
      Directory(p.join(prefix.path, 'bin')).createSync();

      final result = await _smokeCheck(prefix, 'demo');

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('missing ${prefix.path}/bin/demo'));
    });
  });

  // The Flathub runtimes are gigabytes; where their download lands decides
  // whether every job pays for it or one job per runner does.
  group('flatpak user installation', () {
    Future<String> userInstall(Map<String, String> environment) async {
      // The harness runs on CI itself, so drop the runner's own values
      // before setting the ones under test. Without
      // includeParentEnvironment: false the parent leaks them back in and
      // the scrub is a no-op.
      final base = Map<String, String>.of(Platform.environment)
        ..remove('RUNNER_TOOL_CACHE')
        ..remove('FLATPAK_USER_DIR');
      final result = await Process.run(
        'bash',
        [
          '-c',
          r'source "$1"; printf %s "${FLATPAK_USER_DIR:-}"',
          '_',
          _repackScript,
        ],
        environment: {...base, ...environment},
        includeParentEnvironment: false,
      );
      expect(result.exitCode, 0, reason: result.stderr as String);
      return result.stdout as String;
    }

    test('rides the runner tool cache', () async {
      expect(
        await userInstall({'RUNNER_TOOL_CACHE': '/opt/toolcache'}),
        '/opt/toolcache/flatpak-user',
      );
    });

    test('leaves a local build to the flatpak default', () async {
      expect(await userInstall({}), isEmpty);
    });

    test('respects a caller-chosen installation', () async {
      expect(
        await userInstall({
          'RUNNER_TOOL_CACHE': '/opt/toolcache',
          'FLATPAK_USER_DIR': '/elsewhere',
        }),
        '/elsewhere',
      );
    });
  });

  group('ZFS runtime cache', () {
    late String cache;
    late String scratch;

    setUp(() {
      cache = p.join(sandbox.path, 'tools/flatpak-user');
      scratch = p.join(sandbox.path, 'scratch');
    });

    Future<ProcessResult> build({
      String runnerEnvironment = 'self-hosted',
      String cacheFilesystem = 'zfs',
      String scratchFilesystem = 'tmpfs',
      String? userInstallation,
      String revision = '1',
      int dependencyExitCode = 0,
      int copyExitCode = 0,
    }) async {
      Directory(scratch).createSync(recursive: true);
      final manifest = File(p.join(sandbox.path, 'manifest.yml'))
        ..writeAsStringSync('command: demo\n');
      final environment = Map<String, String>.of(Platform.environment)
        ..remove('FLATPAK_USER_DIR');

      return Process.run(
        'bash',
        [
          '-c',
          r'''
set -euo pipefail
die() { printf '%s\n' "$*" >&2; exit 1; }
flatpak() { mkdir -p "$FLATPAK_USER_DIR"; }
stat() {
  if [[ "${@: -1}" == "$TMPDIR/"* ]]; then
    printf '%s\n' "$SCRATCH_FILESYSTEM"
    return
  fi
  printf '%s\n' "$CACHE_FILESYSTEM"
}
sync() {
  [[ "$1" == -f && "$2" == "$RUNNER_TOOL_CACHE/flatpak-user" ]]
  printf 'flush\n'
}
cp() {
  local destination="${@: -1}"
  if [[ "${destination%/}" == "$RUNNER_TOOL_CACHE/flatpak-user" && "$COPY_EXIT_CODE" != 0 ]]; then
    rm -rf "$destination"
    mkdir -p "$destination"
    printf incomplete > "$destination/runtime"
    return "$COPY_EXIT_CODE"
  fi
  command cp "$@"
}
flatpak-builder() {
  case " $* " in
    *' --install-deps-only '*)
      [[ "$FLATPAK_USER_DIR" == "$TMPDIR/"* ]]
      if [[ -f "$FLATPAK_USER_DIR/runtime" ]]; then
        printf 'deps:reuse\n'
      else
        printf 'deps:fresh\n'
      fi
      if [[ "$DEPENDENCY_EXIT_CODE" != 0 ]]; then
        return "$DEPENDENCY_EXIT_CODE"
      fi
      rm -f "$FLATPAK_USER_DIR/obsolete"
      rm -f "$FLATPAK_USER_DIR/runtime"
      printf '%s' "$DEPENDENCY_REVISION" > "$FLATPAK_USER_DIR/runtime"
      chmod 444 "$FLATPAK_USER_DIR/runtime"
      ln -sfn runtime "$FLATPAK_USER_DIR/active" ;;
    *' --run '*) printf 'smoke\n' ;;
    *' --install-deps-from=flathub '*) printf 'build:pull\n' ;;
    *) printf 'build:cached\n' ;;
  esac
}
source "$1"
flatpak_build "$2" "$3" https://example.test/flathub.flatpakrepo
''',
          '_',
          _repackScript,
          p.join(sandbox.path, 'work'),
          manifest.path,
        ],
        environment: {
          ...environment,
          'RUNNER_ENVIRONMENT': runnerEnvironment,
          'RUNNER_TOOL_CACHE': p.join(sandbox.path, 'tools'),
          'TMPDIR': scratch,
          'CACHE_FILESYSTEM': cacheFilesystem,
          'SCRATCH_FILESYSTEM': scratchFilesystem,
          'DEPENDENCY_REVISION': revision,
          'DEPENDENCY_EXIT_CODE': '$dependencyExitCode',
          'COPY_EXIT_CODE': '$copyExitCode',
          if (userInstallation != null) 'FLATPAK_USER_DIR': userInstallation,
        },
        includeParentEnvironment: false,
      );
    }

    test(
      'fills off ZFS, persists, then builds from the original cache',
      () async {
        final result = await build();

        expect(result.exitCode, 0, reason: result.stderr as String);
        expect(result.stdout, 'deps:fresh\nflush\nbuild:cached\nsmoke\n');
        expect(File(p.join(cache, 'runtime')).readAsStringSync(), '1');
        expect(Link(p.join(cache, 'active')).targetSync(), 'runtime');
        expect(Directory(scratch).listSync(), isEmpty);
      },
    );

    test('reuses cached runtimes and stages their updates off ZFS', () async {
      expect((await build()).exitCode, 0);

      final result = await build(revision: '2');

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, 'deps:reuse\nflush\nbuild:cached\nsmoke\n');
      expect(File(p.join(cache, 'active')).readAsStringSync(), '2');
      expect(Directory(scratch).listSync(), isEmpty);
    });

    test('preserves the cache and stops when dependency setup fails', () async {
      expect((await build()).exitCode, 0);
      const dependencyFailure = 23;

      final result = await build(dependencyExitCode: dependencyFailure);

      expect(result.exitCode, dependencyFailure);
      expect(result.stdout, 'deps:reuse\n');
      expect(File(p.join(cache, 'runtime')).readAsStringSync(), '1');
      expect(Directory(scratch).listSync(), isEmpty);
    });

    test('propagates runtime removals back to the persistent cache', () async {
      expect((await build()).exitCode, 0);
      final obsolete = File(p.join(cache, 'obsolete'))
        ..writeAsStringSync('old');

      final result = await build();

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(obsolete.existsSync(), isFalse);
    });

    test(
      'rebuilds an installation without a completed cache snapshot',
      () async {
        File(p.join(cache, 'runtime'))
          ..createSync(recursive: true)
          ..writeAsStringSync('incomplete');

        final result = await build();

        expect(result.exitCode, 0, reason: result.stderr as String);
        expect(result.stdout, 'deps:fresh\nflush\nbuild:cached\nsmoke\n');
        expect(File(p.join(cache, 'runtime')).readAsStringSync(), '1');
      },
    );

    test('recovers from a failed persistent copy on the next build', () async {
      expect((await build()).exitCode, 0);
      const copyFailure = 28;

      final failed = await build(copyExitCode: copyFailure);

      expect(failed.exitCode, copyFailure);
      expect(Directory(scratch).listSync(), isEmpty);

      final retried = await build();

      expect(retried.exitCode, 0, reason: retried.stderr as String);
      expect(retried.stdout, 'deps:fresh\nflush\nbuild:cached\nsmoke\n');
      expect(File(p.join(cache, 'runtime')).readAsStringSync(), '1');
    });

    for (final environment in ['', 'github-hosted']) {
      test('keeps normal dependency setup for "$environment" builds', () async {
        final result = await build(runnerEnvironment: environment);

        expect(result.exitCode, 0, reason: result.stderr as String);
        expect(result.stdout, 'build:pull\nsmoke\n');
      });
    }

    test('keeps normal setup for a non-ZFS runner cache', () async {
      final result = await build(cacheFilesystem: 'ext2/ext3');

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, 'build:pull\nsmoke\n');
    });

    test('respects a caller-chosen installation', () async {
      final result = await build(
        userInstallation: p.join(sandbox.path, 'installation'),
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, 'build:pull\nsmoke\n');
    });

    test(
      'rejects slow scratch storage before installing dependencies',
      () async {
        final result = await build(scratchFilesystem: 'zfs');

        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('TMPDIR'));
        expect(result.stdout, isEmpty);
        expect(Directory(scratch).listSync(), isEmpty);
      },
    );
  });

  final dpkgDeb = Process.runSync('bash', ['-c', 'command -v dpkg-deb']);
  group(
    'staging a .deb',
    skip: dpkgDeb.exitCode == 0 ? false : 'no dpkg-deb',
    () {
      const appId = 'com.example.Demo';

      test(
        'remaps /usr to /app and names the launcher after the app',
        () async {
          final deb = _buildDeb(sandbox);
          final work = p.join(sandbox.path, 'work');

          final result = await _stage(deb, work, appId);

          expect(result.exitCode, 0, reason: result.stderr as String);
          final stage = p.join(work, 'stage');
          final wrapperFile = File(p.join(stage, 'bin/demo'));
          // Still executable: staging copies modes along with the bytes.
          expect(wrapperFile.statSync().mode & 0x49, isNot(0));
          final wrapper = wrapperFile.readAsStringSync();
          expect(wrapper, startsWith('#!/bin/sh\n'));
          expect(wrapper, contains('exec /app/lib/demo/demo_app'));

          final applications = p.join(stage, 'share/applications');
          expect(
            File(p.join(applications, 'demo.desktop')).existsSync(),
            isFalse,
          );
          final desktop = File(
            p.join(applications, '$appId.desktop'),
          ).readAsStringSync();
          expect(desktop, contains('Exec=demo %U'));
          expect(desktop, contains('Icon=$appId'));
          expect(desktop, isNot(contains('TryExec=')));
          expect(
            File(
              p.join(stage, 'share/icons/hicolor/256x256/apps/$appId.png'),
            ).existsSync(),
            isTrue,
          );
        },
      );

      test('refuses a .deb that ships paths outside /usr', () async {
        final deb = _buildDeb(sandbox, extra: 'etc/demo.conf');

        final result = await _stage(deb, p.join(sandbox.path, 'work'), appId);

        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('ships paths outside /usr'));
      });
    },
  );
}

String get _repackScript =>
    p.join(findRepositoryRoot().path, 'scripts', 'flatpak-repack.sh');

/// Runs the smoke check the way flatpak_build does inside the sandbox,
/// with [prefix] standing in for /app.
Future<ProcessResult> _smokeCheck(
  Directory prefix,
  String command, {
  String? path,
}) => Process.run(
  'bash',
  [
    '-c',
    r'source "$1"; sh -c "$FLATPAK_SMOKE_CHECK" _ "$2" "$3"',
    '_',
    _repackScript,
    command,
    prefix.path,
  ],
  environment: {if (path != null) 'PATH': path},
);

Future<ProcessResult> _stage(String deb, String work, String appId) =>
    Process.run('bash', [
      '-c',
      r'die() { echo "die: $*" >&2; exit 1; }; source "$1"; '
          r'flatpak_stage_deb "$2" "$3" "$4"',
      '_',
      _repackScript,
      deb,
      work,
      appId,
    ]);

/// A .deb laid out like the products' packagers write them: a wrapper on
/// PATH, the bundle under /usr/lib, a desktop entry and an icon named after
/// the binary. [extra] adds one file outside /usr.
String _buildDeb(Directory sandbox, {String? extra}) {
  final root = p.join(sandbox.path, 'debroot');
  void write(String relative, String contents) => File(p.join(root, relative))
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);

  write(
    'DEBIAN/control',
    'Package: demo\nVersion: 1.0.0\nArchitecture: amd64\n'
        'Maintainer: Demo <demo@example.com>\nDescription: Demo\n',
  );
  write('usr/bin/demo', '#!/bin/sh\nexec /usr/lib/demo/demo_app "\$@"\n');
  write('usr/lib/demo/demo_app', 'ELF');
  Process.runSync('chmod', [
    '+x',
    p.join(root, 'usr/bin/demo'),
    p.join(root, 'usr/lib/demo/demo_app'),
  ]);
  write(
    'usr/share/applications/demo.desktop',
    '[Desktop Entry]\nType=Application\nName=Demo\n'
        'Exec=/usr/bin/demo %U\nTryExec=/usr/bin/demo\nIcon=demo\n',
  );
  write('usr/share/icons/hicolor/256x256/apps/demo.png', 'PNG');
  if (extra != null) write(extra, 'extra');

  final deb = p.join(sandbox.path, 'demo.deb');
  final result = Process.runSync('dpkg-deb', [
    '--root-owner-group',
    '--build',
    root,
    deb,
  ]);
  if (result.exitCode != 0) {
    throw StateError('dpkg-deb failed: ${result.stderr}');
  }
  return deb;
}
