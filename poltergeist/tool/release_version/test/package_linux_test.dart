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
      // The shared packager loads the table itself; a wrapper loads it by
      // sourcing the shared packager.
      expect(
        RegExp(
          r'^source .*package-linux-gcc-floors\.sh"$',
          multiLine: true,
        ).hasMatch(_sharedPackager.readAsStringSync()),
        isTrue,
      );

      for (final product in _packagerProducts) {
        final packager = File(
          p.join(
            _repositoryRoot.parent.path,
            product,
            'scripts/package-linux.sh',
          ),
        );
        final stanza = RegExp(
          r'^source .*package-linux-(gcc-floors|common)\.sh"$',
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
        final script = _packagerSource(product);
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
    // The writer is shared; the wrapper supplies the title line.
    final block = _markerBlock(
      _sharedPackager.readAsStringSync(),
      'copyright file writer',
    );

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
        environment: {
          'DEB_COPYRIGHT_TITLE': 'Fake: a title line',
          'PRODUCT_NAME': 'Fake',
          'PACKAGE_NAME': 'fake',
          'VERSION': '9.9.9',
          'LICENSE_FILE': license.path,
        },
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      final text = out.readAsStringSync();
      expect(text, startsWith('$_dep5Format\n'));
      expect(text, contains('Comment: Fake: a title line'));
      expect(text, contains('Upstream-Version: 9.9.9'));
      // The standalone license paragraph: the text as continuation lines.
      expect(
        text,
        contains('\n\nLicense: Unlicense\n FAKE LICENSE TEXT\n line two\n'),
      );
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
        environment: {
          'DEB_COPYRIGHT_TITLE': 'Poltergeist',
          'PRODUCT_NAME': 'Poltergeist',
          'PACKAGE_NAME': 'poltergeist',
          'VERSION': '0.1.0',
          'LICENSE_FILE': license.path,
        },
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(
        out.readAsStringSync(),
        contains(_dep5Text(license.readAsStringSync())),
      );
    });

    test('the .deb build writes its copyright through the writer', () {
      expect(
        _sharedPackager.readAsStringSync(),
        allOf(
          contains(
            r'write_copyright "$DEBROOT/usr/share/doc/$PACKAGE_NAME/copyright"',
          ),
          // A missing LICENSE must fail the build, not ship a pointerless
          // file.
          contains('LICENSE not found at'),
        ),
      );
      expect(
        script,
        allOf(
          contains('PACKAGE_NAME="poltergeist"'),
          contains(r'LICENSE_FILE="$ROOT/LICENSE"'),
          contains(
            'DEB_COPYRIGHT_TITLE="Poltergeist — a cross-platform two-pane '
            'file transfer client"',
          ),
        ),
      );
    });
  });

  // Planchette and Séance keep their own copies of the two marked
  // writers; the wrappers run the shared packager's. Every package must
  // scope the Unlicense to its own code and ship the bundle's NOTICES
  // readable next to it.
  group('every packager ships the license and the notices', () {
    const die = 'die() { echo "package-linux: \$*" >&2; exit 1; }\n';

    for (final product in _packagerProducts) {
      final source = _packagerSource(product);

      test('$product scopes the license and points to the notices', () async {
        final license = _repositoryFile('LICENSE');
        final sandbox = Directory.systemTemp.createTempSync(
          'poltergeist-copyright-test-',
        );
        addTearDown(() {
          if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
        });
        final out = File(p.join(sandbox.path, 'copyright'));

        final result = await _sourceAndCall(
          _markerBlock(source, 'copyright file writer'),
          'write_copyright ${_shellQuote(out.path)}',
          environment: {
            'DEB_COPYRIGHT_TITLE': 'Title',
            'PRODUCT_NAME': 'Product',
            'PACKAGE_NAME': product,
            'VERSION': '9.9.9',
            'LICENSE_FILE': license.path,
          },
        );

        expect(result.exitCode, 0, reason: result.stderr as String);
        // Machine-readable (DEP-5): a header, a Files paragraph for the
        // package's own code, one for the Flutter bundle, which compiles
        // in the third-party components, and a standalone paragraph with
        // each license's text.
        final paragraphs = _dep5Paragraphs(out.readAsStringSync());
        expect(paragraphs.map((fields) => fields.keys.first), [
          'Format',
          'Files',
          'Files',
          'License',
          'License',
        ]);
        expect(paragraphs[0]['Upstream-Version'], '9.9.9');
        expect(
          paragraphs[0]['Comment'],
          contains('Third-Party-Notices.txt next to this file.'),
        );
        expect(paragraphs[1], containsPair('Files', '*'));
        expect(paragraphs[1], containsPair('License', 'Unlicense'));
        expect(paragraphs[2], containsPair('Files', 'usr/lib/$product/*'));
        expect(
          paragraphs[2],
          containsPair('License', 'Unlicense and LicenseRef-Bundled-Flutter'),
        );
        expect(
          '${paragraphs[3]['License']}\n',
          'Unlicense\n${_dep5Text(license.readAsStringSync())}',
        );
        expect(
          paragraphs[4]['License'],
          allOf(
            startsWith('LicenseRef-Bundled-Flutter\n'),
            contains('Third-Party-Notices.txt next to this file.'),
          ),
        );
      });

      test("$product ships the bundle's NOTICES readable", () async {
        final sandbox = Directory.systemTemp.createTempSync(
          'poltergeist-notices-test-',
        );
        addTearDown(() {
          if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
        });
        // Flutter writes NOTICES.Z gzip-compressed.
        final notices = 'pdfium_dart\n\nMIT\n${'-' * 80}\nPDFium\n\nBSD\n';
        File(p.join(sandbox.path, 'bundle/data/flutter_assets/NOTICES.Z'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(gzip.encode(notices.codeUnits));
        final out = File(p.join(sandbox.path, 'Third-Party-Notices.txt'));

        final result = await _sourceAndCall(
          _markerBlock(source, 'third-party notices writer'),
          '${die}write_third_party_notices '
          '${_shellQuote(p.join(sandbox.path, 'bundle'))} '
          '${_shellQuote(out.path)}',
        );

        expect(result.exitCode, 0, reason: result.stderr as String);
        expect(out.readAsStringSync(), notices);
      });

      test('$product refuses a bundle without NOTICES', () async {
        final sandbox = Directory.systemTemp.createTempSync(
          'poltergeist-notices-test-',
        );
        addTearDown(() {
          if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
        });
        Directory(
          p.join(sandbox.path, 'bundle/data/flutter_assets'),
        ).createSync(recursive: true);

        final result = await _sourceAndCall(
          _markerBlock(source, 'third-party notices writer'),
          '${die}write_third_party_notices '
          '${_shellQuote(p.join(sandbox.path, 'bundle'))} '
          '${_shellQuote(p.join(sandbox.path, 'out.txt'))}',
        );

        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('NOTICES.Z not found'));
      });

      test('$product writes both into its doc directory', () {
        final doc = source.contains('package-linux-common.sh"')
            ? r'$PACKAGE_NAME'
            : product;
        expect(
          source,
          allOf(
            contains(
              'write_copyright "\$DEBROOT/usr/share/doc/$doc/copyright"',
            ),
            contains(
              'write_third_party_notices "\$BUNDLE" '
              '"\$DEBROOT/usr/share/doc/$doc/Third-Party-Notices.txt"',
            ),
          ),
        );
      });
    }
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

/// The suite's shared Linux packager, which the product wrappers source.
final _sharedPackager = File(
  p.join(_repositoryRoot.parent.path, 'scripts/package-linux-common.sh'),
);

/// The first line of a machine-readable Debian copyright file.
const _dep5Format =
    'Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/';

/// [text] as DEP-5 continuation lines: each line indented by one space,
/// an empty line written as " .".
String _dep5Text(String text) {
  final lines = [
    for (final line in text.trimRight().split('\n'))
      line.trim().isEmpty ? ' .' : ' $line',
  ];
  return '${lines.join('\n')}\n';
}

/// The paragraphs of a DEP-5 file, each as its fields in order.
List<Map<String, String>> _dep5Paragraphs(String text) => [
  for (final paragraph in text.trimRight().split('\n\n'))
    _dep5Fields(paragraph),
];

/// A DEP-5 paragraph's fields; a value keeps its continuation lines,
/// joined by newlines. Fails on a line that is neither.
Map<String, String> _dep5Fields(String paragraph) {
  final fields = <String, String>{};
  String? field;
  for (final line in paragraph.split('\n')) {
    if (line.startsWith(' ')) {
      if (field == null) throw FormatException('no field to continue', line);
      fields[field] = '${fields[field]}\n$line';
      continue;
    }

    final colon = line.indexOf(': ');
    if (colon <= 0) throw FormatException('not a DEP-5 field', line);
    field = line.substring(0, colon);
    fields[field] = line.substring(colon + 2);
  }
  return fields;
}

/// [product]'s packager source, followed by the shared packager's when the
/// product's script is a wrapper over it: the code that runs either way.
String _packagerSource(String product) {
  final script = File(
    p.join(_repositoryRoot.parent.path, product, 'scripts/package-linux.sh'),
  ).readAsStringSync();
  if (!script.contains('package-linux-common.sh"')) return script;

  return '$script\n${_sharedPackager.readAsStringSync()}';
}

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
