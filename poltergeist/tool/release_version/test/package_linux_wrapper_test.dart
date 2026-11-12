@TestOn('posix')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Static identity assertions and a stub-bundle packaging run for every
/// product's scripts/package-linux.sh wrapper. The wrappers carry the
/// identities; the shared packager turns them into the .deb and AppImage.
/// The stub tools stand in for readelf, objdump, ImageMagick, dpkg-deb and
/// appimagetool, so the run works on any POSIX host.
void main() {
  group('wrapper identities', () {
    for (final product in _products.keys) {
      test('$product carries its identities and metadata', () {
        final spec = _products[product]!;
        final source = _wrapper(product).readAsStringSync();

        expect(source, contains('PRODUCT_NAME="${spec.productName}"'));
        expect(source, contains('PACKAGE_NAME="${spec.packageName}"'));
        expect(source, contains('ASSET_STEM="${spec.assetStem}"'));
        expect(source, contains('BUNDLE_EXECUTABLE="${spec.executable}"'));
        expect(
          source,
          contains('LINUX_APPLICATION_ID="${spec.applicationId}"'),
        );
        expect(
          source,
          contains(r'LINUX_DESKTOP_FILE="$LINUX_APPLICATION_ID.desktop"'),
        );
        expect(source, contains('MASTER_ICON="\$ROOT/${spec.icon}"'));
        expect(source, contains(r'LICENSE_FILE="$ROOT/LICENSE"'));
        expect(source, contains('DEB_SECTION="${spec.section}"'));
        expect(
          source,
          contains('DEB_DESCRIPTION="${spec.description}'),
          reason: 'the synopsis and extended lines',
        );
        expect(
          source,
          contains('DEB_COPYRIGHT_TITLE="${spec.copyrightTitle}"'),
        );
        expect(
          source,
          contains('EXTRA_DEPENDS=${spec.extraDependsSource}'),
          reason: 'runtime tools the app spawns',
        );
        expect(
          source,
          contains(
            r'source "$(dirname "$SELF")/../../scripts/package-linux-common.sh"',
          ),
        );
        expect(source, contains(r'package_linux_main "$@"'));
      });

      test('$product keeps its desktop entry lines', () {
        final spec = _products[product]!;
        final source = _wrapper(product).readAsStringSync();

        for (final line in spec.desktopLines) {
          expect(source, contains(line), reason: line);
        }
        expect(
          source,
          contains(spec.startupWmClassSource),
          reason: 'the resolved WM class',
        );
      });
    }
  });

  group('stub-bundle packaging', () {
    for (final product in _products.keys) {
      test('$product stages the expected .deb and AppDir', () async {
        final spec = _products[product]!;
        final run = await _packageStubBundle(product, spec);

        expect(
          run.result.exitCode,
          0,
          reason: '${run.result.stdout}\n${run.result.stderr}',
        );
        final version = _appVersion(product);
        final deb = Directory(
          p.join(run.out.path, '${spec.packageName}_$version-1_amd64.deb'),
        );
        final appImage = File(
          p.join(run.out.path, '${spec.assetStem}-linux-x64.AppImage'),
        );
        expect(deb.existsSync(), isTrue, reason: '${run.result.stdout}');
        expect(appImage.existsSync(), isTrue, reason: '${run.result.stdout}');

        final control = _read(p.join(deb.path, 'DEBIAN/control'));
        expect(
          control.split('\n'),
          containsAllInOrder([
            'Package: ${spec.packageName}',
            'Version: $version-1',
            'Section: ${spec.section}',
            'Architecture: amd64',
            startsWith('Depends: '),
            'Maintainer: L-K-M <l-k-m@users.noreply.github.com>',
            'Homepage: https://github.com/L-K-M/Hauntware',
            'Description: ${spec.description}',
          ]),
        );
        expect(
          control,
          allOf(
            contains('libc6 (>= 2.34)'),
            contains('libstdc++6 (>= 12.1)'),
            contains('libgcc-s1 (>= 12.1)'),
            contains('libgtk-3-0 | libgtk-3-0t64'),
          ),
        );

        expect(
          _read(
            p.join(
              deb.path,
              'usr/share/applications/${spec.applicationId}.desktop',
            ),
          ),
          spec.desktopEntry,
        );
        expect(
          _read(p.join(deb.path, 'usr/bin/${spec.packageName}')),
          '#!/bin/sh\n'
          'exec /usr/lib/${spec.packageName}/${spec.executable} "\$@"\n',
        );
        expect(
          File(
            p.join(deb.path, 'usr/lib/${spec.packageName}/${spec.executable}'),
          ).existsSync(),
          isTrue,
        );
        for (final size in _iconSizes) {
          expect(
            _read(
              p.join(
                deb.path,
                'usr/share/icons/hicolor/${size}x$size/apps/'
                '${spec.packageName}.png',
              ),
            ),
            '${size}x$size',
            reason: 'hicolor $size',
          );
        }

        final copyright = _read(
          p.join(deb.path, 'usr/share/doc/${spec.packageName}/copyright'),
        );
        expect(copyright, startsWith('Format: https://www.debian.org/'));
        expect(copyright, contains('\nComment: ${spec.copyrightTitle}.\n'));
        expect(copyright, contains('\nUpstream-Version: $version\n'));
        expect(copyright, contains('\n\nFiles: *\n'));
        expect(
          copyright,
          contains('\n\nFiles: usr/lib/${spec.packageName}/*\n'),
        );
        expect(copyright, contains('\n\nLicense: Unlicense\n'));
        expect(
          copyright,
          contains('Third-Party-Notices.txt next to this file'),
        );
        expect(
          _read(
            p.join(
              deb.path,
              'usr/share/doc/${spec.packageName}/Third-Party-Notices.txt',
            ),
          ),
          _stubNotices,
        );

        final appDir = '${appImage.path}.appdir';
        expect(
          _read(p.join(appDir, '${spec.applicationId}.desktop')),
          spec.desktopEntry.replaceFirst(
            'Exec=${spec.packageName}',
            'Exec=AppRun',
          ),
        );
        expect(
          _read(p.join(appDir, 'AppRun')),
          '#!/bin/sh\n'
          '# AppImages mount read-only at a random path; resolve through '
          'symlinks so the\n'
          "# runner's \$ORIGIN-relative lib/ and data/ lookups work.\n"
          'HERE="\$(dirname "\$(readlink -f "\$0")")"\n'
          'exec "\$HERE/usr/lib/${spec.packageName}/${spec.executable}" "\$@"\n',
        );
        expect(_read(p.join(appDir, '${spec.packageName}.png')), '512x512');
        expect(File(p.join(appDir, '.DirIcon')).existsSync(), isTrue);
        expect(Directory(p.join(appDir, 'usr/bin')).existsSync(), isFalse);
        expect(
          _read(
            p.join(
              appDir,
              'usr/share/doc/${spec.packageName}/Third-Party-Notices.txt',
            ),
          ),
          _stubNotices,
        );
      });
    }
  });
}

const _iconSizes = [16, 24, 32, 48, 64, 96, 128, 256, 512];

const _stubNotices = 'ghost_fonts\n\nUnlicense\n';

class _ProductSpec {
  const _ProductSpec({
    required this.productName,
    required this.packageName,
    required this.assetStem,
    required this.executable,
    required this.applicationId,
    required this.icon,
    required this.section,
    required this.description,
    required this.copyrightTitle,
    required this.extraDependsSource,
    required this.desktopLines,
    required this.startupWmClassSource,
    required this.desktopEntry,
  });

  final String productName;
  final String packageName;
  final String assetStem;
  final String executable;
  final String applicationId;
  final String icon;
  final String section;
  final String description;
  final String copyrightTitle;
  final String extraDependsSource;
  final List<String> desktopLines;
  final String startupWmClassSource;
  final String desktopEntry;
}

const _products = {
  'planchette': _ProductSpec(
    productName: 'Planchette',
    packageName: 'planchette',
    assetStem: 'planchette',
    executable: 'planchette',
    applicationId: 'ch.lkmc.planchette',
    icon: 'media-sources/icon.png',
    section: 'editors',
    description: 'Planchette — a cross-platform text editor',
    copyrightTitle: 'Planchette — a cross-platform text editor',
    extraDependsSource: '()',
    desktopLines: [
      'Exec=\$2 %F',
      'MimeType=text/plain;text/x-source;',
      'StartupWMClass=\$LINUX_STARTUP_WM_CLASS',
      'Categories=Utility;Development;TextEditor;',
      'Keywords=Text;Editor;Code;Planchette;',
    ],
    startupWmClassSource: r'LINUX_STARTUP_WM_CLASS="${LINUX_APPLICATION_ID^}"',
    desktopEntry:
        '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=Planchette\n'
        'GenericName=Text Editor\n'
        'Comment=The pointer that spells it out\n'
        'Exec=planchette %F\n'
        'Icon=planchette\n'
        'Terminal=false\n'
        'Categories=Utility;Development;TextEditor;\n'
        'Keywords=Text;Editor;Code;Planchette;\n'
        'MimeType=text/plain;text/x-source;\n'
        '# The packaged build reports this X11 WM_CLASS class (the instance is'
        ' the\n'
        '# lowercase application id); StartupWMClass is case-sensitive.\n'
        'StartupWMClass=Ch.lkmc.planchette\n',
  ),
  'seance': _ProductSpec(
    productName: 'Séance',
    packageName: 'seance',
    assetStem: 'seance',
    executable: 'seance_app',
    applicationId: 'ch.lkmc.seance',
    icon: 'media-sources/seance-icon.png',
    section: 'net',
    description: 'Séance — a personal cross-platform SSH client',
    copyrightTitle: 'Séance — a personal cross-platform SSH client',
    extraDependsSource: '()',
    desktopLines: [
      'Exec=\$2 %u',
      'MimeType=x-scheme-handler/seance;',
      'StartupWMClass=\$LINUX_STARTUP_WM_CLASS',
      'Categories=Network;System;Utility;',
    ],
    startupWmClassSource: 'LINUX_STARTUP_WM_CLASS="ch.lkmc.seance"',
    desktopEntry:
        '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=Séance\n'
        'GenericName=SSH Client\n'
        'Comment=Summon remote machines and talk to them\n'
        'Exec=seance %u\n'
        'Icon=seance\n'
        'Terminal=false\n'
        'Categories=Network;System;Utility;\n'
        'MimeType=x-scheme-handler/seance;\n'
        '# The GApplication id is also the prgname GTK reports to the session'
        ' (seen\n'
        '# in its warnings: "(ch.lkmc.seance:pid): …"), hence StartupWMClass —\n'
        "# that's what lets desktops map windows onto this entry.\n"
        'StartupWMClass=ch.lkmc.seance\n',
  ),
  'poltergeist': _ProductSpec(
    productName: 'Poltergeist',
    packageName: 'poltergeist',
    assetStem: 'poltergeist',
    executable: 'poltergeist',
    applicationId: 'ch.lkmc.poltergeist',
    icon: 'media-sources/icon.png',
    section: 'net',
    description: 'Poltergeist — a two-pane file transfer client',
    copyrightTitle:
        'Poltergeist — a cross-platform two-pane file transfer client',
    extraDependsSource: "('libglib2.0-bin')",
    desktopLines: [
      'Exec=\$2 %u',
      'MimeType=x-scheme-handler/poltergeist;',
      'StartupWMClass=\$LINUX_STARTUP_WM_CLASS',
      'Categories=Network;FileTransfer;FileManager;',
    ],
    startupWmClassSource: r'LINUX_STARTUP_WM_CLASS="${LINUX_APPLICATION_ID^}"',
    desktopEntry:
        '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=Poltergeist\n'
        'GenericName=File Transfer Client\n'
        'Comment=The ghost that moves your files\n'
        'Exec=poltergeist %u\n'
        'Icon=poltergeist\n'
        'Terminal=false\n'
        'Categories=Network;FileTransfer;FileManager;\n'
        'MimeType=x-scheme-handler/poltergeist;\n'
        '# The packaged build reports this X11 WM_CLASS class (the instance is'
        ' the\n'
        '# lowercase application id); StartupWMClass is case-sensitive.\n'
        'StartupWMClass=Ch.lkmc.poltergeist\n',
  ),
};

Future<({ProcessResult result, Directory out})> _packageStubBundle(
  String product,
  _ProductSpec spec,
) async {
  final sandbox = Directory.systemTemp.createTempSync('package-wrapper-test-');
  addTearDown(() => sandbox.deleteSync(recursive: true));

  final bundle = Directory(
    p.join(sandbox.path, 'stub/linux/x64/release/bundle/lib'),
  )..createSync(recursive: true);
  File(p.join(bundle.parent.path, spec.executable)).writeAsStringSync('ELF');
  File(p.join(bundle.path, 'libapp.so')).writeAsStringSync('ELF');
  File(p.join(bundle.parent.path, 'data/flutter_assets/NOTICES.Z'))
    ..createSync(recursive: true)
    ..writeAsBytesSync(gzip.encode(_stubNotices.codeUnits));

  final bin = Directory(p.join(sandbox.path, 'bin'))..createSync();
  void tool(String name, String body) {
    File(
      p.join(bin.path, name),
    ).writeAsStringSync('#!/usr/bin/env bash\n$body');
  }

  tool('readelf', r'''
case "$1" in
  -h) echo '  Machine:                           Advanced Micro Devices X86-64' ;;
  -d) printf ' 0x1 (NEEDED) Shared library: [%s]\n' \
        libc.so.6 libstdc++.so.6 libgcc_s.so.1 libgtk-3.so.0 ;;
esac
''');
  tool(
    'objdump',
    r"printf '0 DF *UND* 0 %s f\n' GLIBC_2.34 GLIBCXX_3.4.30 GCC_12.0.0"
        '\n',
  );
  tool(
    'magick',
    r'printf %s "$3" > "$4"'
        '\n',
  );
  tool('file', 'exit 0\n');
  tool('dpkg-deb', r'''
[[ "$1" == --root-owner-group && "$2" == --build ]] || exit 2
cp -a "$3" "$4"
''');
  tool('appimagetool', r'''
[[ "$1" == --no-appstream ]] || exit 2
cp -a "$2" "$3.appdir" && touch "$3"
''');
  final tools = bin.listSync().map((entity) => entity.path).toList();
  await Process.run('chmod', ['+x', ...tools]);

  final out = Directory(p.join(sandbox.path, 'out'));
  final result = await Process.run(
    'bash',
    [
      _wrapper(product).path,
      '--bundle',
      bundle.parent.path,
      '--output-dir',
      out.path,
    ],
    environment: {
      ...Platform.environment,
      'PATH': '${bin.path}:${Platform.environment['PATH']}',
      'APPIMAGETOOL': p.join(bin.path, 'appimagetool'),
    },
  );

  return (result: result, out: out);
}

String _appVersion(String product) {
  final pubspec = File(
    p.join(
      _wrapper(product).parent.parent.path,
      'app',
      _appName(product),
      'pubspec.yaml',
    ),
  );
  final line = pubspec
      .readAsStringSync()
      .split('\n')
      .firstWhere((line) => line.startsWith('version:'));
  return line.substring('version:'.length).trim().split('+').first;
}

String _appName(String product) => switch (product) {
  'planchette' => 'planchette_app',
  'seance' => 'seance_app',
  _ => 'poltergeist_app',
};

File _wrapper(String product) => File(
  p.join(_repositoryRoot.parent.path, product, 'scripts/package-linux.sh'),
);

String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

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
