@TestOn('posix')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// scripts/package-linux.sh only runs on a host with a built Flutter bundle,
/// so these tests extract its marker-delimited blocks and execute them
/// against fixtures — the same sandbox pattern release_workflow_test.dart
/// applies to workflow steps.
void main() {
  final script = _repositoryFile('scripts/package-linux.sh').readAsStringSync();

  group('ABI-tag → GCC mapping', () {
    // The table is shared with Planchette's packager at the suite root.
    final block = File(
      p.join(
        _repositoryRoot.parent.path,
        'scripts/package-linux-gcc-floors.sh',
      ),
    ).readAsStringSync();

    // Mirrors GCC's ABI policy table
    // (https://gcc.gnu.org/onlinedocs/libstdc++/manual/abi.html): the tag →
    // the first GCC release shipping it. A wrong entry ships an
    // uninstallable or under-constrained .deb Depends floor.
    const glibcxxTags = <String, String>{
      '3.4.21': '5.1',
      '3.4.22': '6.1',
      '3.4.23': '7.1',
      '3.4.24': '7.2',
      '3.4.25': '8.1',
      '3.4.26': '9.1',
      '3.4.27': '9.2',
      '3.4.28': '9.3',
      '3.4.29': '11.1',
      '3.4.30': '12.1',
      '3.4.31': '13.1',
      '3.4.32': '13.2',
      '3.4.33': '14.1',
      '3.4.34': '15.1',
    };
    const gccTags = <String, String>{
      '7.0.0': '7.1',
      '9.0.0': '9.1',
      '11.0': '11.1',
      '12.0.0': '12.1',
      '13.0.0': '13.1',
    };

    for (final entry in glibcxxTags.entries) {
      test('GLIBCXX_${entry.key} → GCC ${entry.value}', () async {
        final result = await _sourceAndCall(block, 'glibcxx_gcc ${entry.key}');

        expect(result.exitCode, 0, reason: result.stderr as String);
        expect(result.stdout.trim(), entry.value);
      });
    }

    for (final entry in gccTags.entries) {
      test('GCC_${entry.key} → GCC ${entry.value}', () async {
        final result = await _sourceAndCall(block, 'gcc_gcc ${entry.key}');

        expect(result.exitCode, 0, reason: result.stderr as String);
        expect(result.stdout.trim(), entry.value);
      });
    }

    test('pre-3.4.21 GLIBCXX tags carry no floor', () async {
      // The real Flutter 3.47.2 bundle floors at the base tag GLIBCXX_3.4 —
      // CI proved it on the first run of this mapping.
      for (final tag in const ['3.4', '3.4.9', '3.4.13', '3.4.20']) {
        final result = await _sourceAndCall(block, 'glibcxx_gcc $tag');

        expect(result.exitCode, 0, reason: tag);
        expect(result.stdout.trim(), isEmpty, reason: tag);
      }
    });

    test('pre-libgcc-s1 GCC tags carry no floor', () async {
      final result = await _sourceAndCall(block, 'gcc_gcc 3.0');

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout.trim(), isEmpty);
    });

    test('unmapped tags fail closed', () async {
      for (final call in const ['glibcxx_gcc 3.4.35', 'gcc_gcc 14.0.0']) {
        final result = await _sourceAndCall(block, call);

        expect(result.exitCode, isNot(0), reason: call);
      }
    });

    test('every Linux packager loads the shared table', () async {
      for (final product in _packagerProducts) {
        final packager = File(
          p.join(
            _repositoryRoot.parent.path,
            product,
            'scripts/package-linux.sh',
          ),
        );
        final stanza = RegExp(
          r'^source .*package-linux-gcc-floors\.sh"$',
          multiLine: true,
        ).firstMatch(packager.readAsStringSync())?[0];
        expect(stanza, isNotNull, reason: product);

        final result = await Process.run('bash', [
          '-euo',
          'pipefail',
          '-c',
          'SELF=${_shellQuote(packager.path)}\n$stanza\nglibcxx_gcc 3.4.30',
        ]);
        expect(result.exitCode, 0, reason: '$product: ${result.stderr}');
        expect((result.stdout as String).trim(), '12.1', reason: product);
      }
    });

    test('every packager maps floors through the table, never the raw tag', () {
      for (final product in _packagerProducts) {
        final script = File(
          p.join(
            _repositoryRoot.parent.path,
            product,
            'scripts/package-linux.sh',
          ),
        ).readAsStringSync();
        expect(script, contains(r'no GCC mapping for GLIBCXX_$'), reason: product);
        expect(script, contains(r'no GCC mapping for GCC_$'), reason: product);
        expect(script, isNot(contains(r'(>= $GLIBCXX')), reason: product);
        expect(script, isNot(contains(r'(>= $GCC')), reason: product);
        // An empty mapping (pre-3.4.21 tags) must keep the unversioned
        // dependency, not emit "(>= )" — dpkg-deb rejects an empty version.
        expect(
          script,
          contains(r'[[ -n "$mapped" ]] && dep_version libstdc++6'),
          reason: product,
        );
      }
    });
  });

  // Each real packager, run with --print-deps against a stub bundle whose
  // readelf and objdump answers are scripted: the floors it computes, and
  // what it does when objdump cannot read an ELF.
  group('dependency floors, end to end', () {
    for (final MapEntry(key: product, value: executable)
        in _packagerExecutables.entries) {
      test('$product maps symbol tags to package floors', () async {
        final result = await _printDeps(product, executable);

        expect(result.exitCode, 0, reason: result.stderr as String);
        expect(
          result.stdout,
          allOf(
            contains('libc6 (>= 2.34)'),
            contains('libstdc++6 (>= 12.1)'),
            contains('libgcc-s1 (>= 12.1)'),
          ),
        );
      });

      test('$product keeps libstdc++6 unversioned below 3.4.21', () async {
        final result = await _printDeps(
          product,
          executable,
          symbolTags: 'GLIBC_2.34 GLIBCXX_3.4.20 GCC_12.0.0',
        );

        expect(result.exitCode, 0, reason: result.stderr as String);
        expect(
          result.stdout,
          allOf(
            contains('libstdc++6'),
            isNot(contains('libstdc++6 (>=')),
            contains('libgcc-s1 (>= 12.1)'),
          ),
        );
      });

      test('$product stops when objdump cannot read an ELF', () async {
        final result = await _printDeps(
          product,
          executable,
          objdumpFails: true,
        );

        expect(result.exitCode, isNot(0), reason: result.stdout as String);
        expect(result.stderr, contains('objdump failed'));
      });
    }
  });

  group('Debian copyright file', () {
    final block = _markerBlock(script, 'copyright file writer');

    test('embeds the license verbatim under the header', () async {
      final sandbox = Directory.systemTemp.createTempSync(
        'poltergeist-copyright-test-',
      );
      addTearDown(() {
        if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
      });

      final license = File(p.join(sandbox.path, 'LICENSE'))
        ..writeAsStringSync('FAKE LICENSE TEXT\nline two\n');
      final out = File(p.join(sandbox.path, 'copyright'));

      final result = await _sourceAndCall(
        block,
        'write_copyright ${_shellQuote(out.path)}',
        environment: {'VERSION': '9.9.9', 'LICENSE_FILE': license.path},
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      final text = out.readAsStringSync();
      expect(text, contains('Upstream-Version: 9.9.9'));
      expect(text, contains('License: Unlicense'));
      expect(text, contains('FAKE LICENSE TEXT\nline two\n'));
    });

    test('embeds the repository LICENSE as shipped', () async {
      final license = _repositoryFile('LICENSE');
      final sandbox = Directory.systemTemp.createTempSync(
        'poltergeist-copyright-test-',
      );
      addTearDown(() {
        if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
      });

      final out = File(p.join(sandbox.path, 'copyright'));
      final result = await _sourceAndCall(
        block,
        'write_copyright ${_shellQuote(out.path)}',
        environment: {'VERSION': '0.1.0', 'LICENSE_FILE': license.path},
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(out.readAsStringSync(), contains(license.readAsStringSync()));
    });

    test('the .deb build writes its copyright through the writer', () {
      expect(
        script,
        contains(
          r'write_copyright "$DEBROOT/usr/share/doc/poltergeist/copyright"',
        ),
      );
      // A missing LICENSE must fail the build, not ship a pointerless file.
      expect(script, contains('LICENSE not found at'));
    });
  });
}

/// Runs [product]'s real packager with --print-deps on a stub bundle
/// (its [executable] plus one library) behind stub readelf/objdump that
/// report GLIBC_2.34, GLIBCXX_3.4.30 and GCC_12.0.0, or, with
/// [objdumpFails], an objdump that cannot read the files.
Future<ProcessResult> _printDeps(
  String product,
  String executable, {
  bool objdumpFails = false,
  String symbolTags = 'GLIBC_2.34 GLIBCXX_3.4.30 GCC_12.0.0',
}) async {
  final sandbox = Directory.systemTemp.createTempSync('package-deps-test-');
  addTearDown(() => sandbox.deleteSync(recursive: true));
  final bundle = Directory(p.join(sandbox.path, 'bundle', 'lib'))
    ..createSync(recursive: true);
  File(p.join(bundle.parent.path, executable)).writeAsStringSync('ELF');
  File(p.join(bundle.path, 'libapp.so')).writeAsStringSync('ELF');
  final bin = Directory(p.join(sandbox.path, 'bin'))..createSync();
  File(p.join(bin.path, 'readelf')).writeAsStringSync(r'''#!/usr/bin/env bash
case "$1" in
  -h) echo '  Machine:                           Advanced Micro Devices X86-64' ;;
  -d) printf ' 0x1 (NEEDED) Shared library: [%s]\n' \
        libc.so.6 libstdc++.so.6 libgcc_s.so.1 ;;
esac
''');
  File(p.join(bin.path, 'objdump')).writeAsStringSync(
    objdumpFails
        ? '#!/usr/bin/env bash\nexit 1\n'
        : '#!/usr/bin/env bash\n'
              "printf '0 DF *UND* 0 %s f\\n' $symbolTags\n",
  );
  Process.runSync('chmod', [
    '+x',
    p.join(bin.path, 'readelf'),
    p.join(bin.path, 'objdump'),
  ]);

  return Process.run(
    'bash',
    [
      p.join(_repositoryRoot.parent.path, product, 'scripts/package-linux.sh'),
      '--bundle',
      bundle.parent.path,
      '--print-deps',
    ],
    environment: {
      ...Platform.environment,
      'PATH': '${bin.path}:${Platform.environment['PATH']}',
    },
  );
}

/// The products whose Linux packagers take their libstdc++ and libgcc
/// floors from the shared ABI-tag table, with each bundle's executable.
const _packagerExecutables = {
  'planchette': 'planchette',
  'seance': 'seance_app',
  'poltergeist': 'poltergeist',
};

final _packagerProducts = _packagerExecutables.keys;

/// scripts/package-linux.sh delimits the units its tests execute with
/// `# --- <name> (…)` … `# --- end <name>` comment markers; keep them.
String _markerBlock(String script, String name) {
  final marker = script.indexOf('--- $name');
  if (marker < 0) {
    throw StateError('start marker for "$name" not found');
  }
  // Keep the whole marker line — starting at "---" would drop its "# " and
  // ship a syntax error to bash.
  final start = script.lastIndexOf('\n', marker) + 1;
  final end = script.indexOf('--- end $name', start);
  if (end < 0) {
    throw StateError('end marker for "$name" not found');
  }

  return script.substring(start, end);
}

Future<ProcessResult> _sourceAndCall(
  String block,
  String call, {
  Map<String, String> environment = const {},
}) async {
  final sandbox = Directory.systemTemp.createTempSync(
    'poltergeist-package-linux-test-',
  );
  addTearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });
  final blockFile = File(p.join(sandbox.path, 'block.sh'))
    ..writeAsStringSync(block);

  return Process.run(
    'bash',
    ['-euo', 'pipefail', '-c', '. ${_shellQuote(blockFile.path)}\n$call'],
    environment: {...Platform.environment, ...environment},
  );
}

String _shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

File _repositoryFile(String path) => File(p.join(_repositoryRoot.path, path));

final Directory _repositoryRoot = _findRepositoryRoot();

Directory _findRepositoryRoot() {
  var candidate = Directory.current.absolute;
  while (true) {
    if (File(
          p.join(candidate.path, '.github/workflows/release.yml'),
        ).existsSync() &&
        File(p.join(candidate.path, 'pubspec.yaml')).existsSync()) {
      return candidate;
    }

    final parent = candidate.parent;
    if (p.equals(parent.path, candidate.path)) {
      throw StateError('repository root not found from ${Directory.current}');
    }
    candidate = parent;
  }
}
