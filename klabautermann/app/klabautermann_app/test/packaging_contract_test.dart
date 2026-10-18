import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/app_identity.dart';
import 'package:klabautermann_app/l10n/app_localizations_en.dart';

// Paths are relative to the app directory, where `flutter test` runs.
const _packager = '../../scripts/package-linux.sh';
const _sharedPackager = '../../../scripts/package-linux-common.sh';
const _flatpakBuilder = '../../scripts/build-flatpak.sh';
const _flatpakManifest = '../../flatpak/ch.lkmc.klabautermann.yml';
const _buildScript = '../../scripts/build.sh';
const _releaseScript = '../../scripts/release.sh';
const _masterIcon = '../../media-sources/klabautermann-icon.png';

// The fixed identities (03 D38, 04 §12.3). None of them carries the
// preview label; only the release asset names do, until v1.
const _linuxBinaryName = 'klabautermann';
const _linuxApplicationId = 'ch.lkmc.klabautermann';
const _linuxStartupWmClass = 'Ch.lkmc.klabautermann';
const _linuxDesktopFile = '$_linuxApplicationId.desktop';
const _packageName = 'klabautermann';
const _assetStem = 'klabautermann-preview';

// 04 §12.1: network, ssh-agent, the Secret Service and the display
// sockets the siblings use, plus read-only ~/.ssh/config for the FL-02
// import. No home access, and no other file under ~/.ssh.
const _flatpakFinishArgs = {
  '--share=ipc',
  '--socket=wayland',
  '--socket=fallback-x11',
  '--device=dri',
  '--share=network',
  '--socket=ssh-auth',
  '--filesystem=~/.ssh/config:ro',
  '--talk-name=org.freedesktop.secrets',
};

const _iconSizes = [16, 24, 32, 48, 64, 96, 128, 256, 512];
const _pngSignature = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

void main() {
  group('Linux packaging', () {
    test('the wrapper carries the fixed Linux identities', () {
      expect(
        '${_linuxApplicationId[0].toUpperCase()}'
        '${_linuxApplicationId.substring(1)}',
        _linuxStartupWmClass,
      );
      expect(
        _read(_packager),
        allOf([
          contains('BUNDLE_EXECUTABLE="$_linuxBinaryName"'),
          contains('LINUX_APPLICATION_ID="$_linuxApplicationId"'),
          contains(r'LINUX_STARTUP_WM_CLASS="${LINUX_APPLICATION_ID^}"'),
          contains(r'LINUX_DESKTOP_FILE="$LINUX_APPLICATION_ID.desktop"'),
          contains(r'StartupWMClass=$LINUX_STARTUP_WM_CLASS'),
          contains('PACKAGE_NAME="$_packageName"'),
          contains(r'MASTER_ICON="$ROOT/media-sources/klabautermann-icon.png"'),
          contains(
            r'source "$(dirname "$SELF")/../../scripts/package-linux-common.sh"',
          ),
          contains(r'package_linux_main "$@"'),
        ]),
      );
      // The runner reports what the desktop entry promises.
      expect(
        _read('linux/CMakeLists.txt'),
        allOf(
          contains('set(BINARY_NAME "$_linuxBinaryName")'),
          contains('set(APPLICATION_ID "$_linuxApplicationId")'),
        ),
      );
    });

    test('release asset names carry the preview label until v1', () {
      expect(_read(_packager), contains('ASSET_STEM="$_assetStem"'));
      expect(
        _read(_sharedPackager),
        allOf(
          contains(r'out="$OUT_DIR/$ASSET_STEM-linux-$FLUTTER_ARCH.AppImage"'),
          // Debian's versioned file name, never the label.
          contains(
            r'deb_name="${PACKAGE_NAME}_${DEB_VERSION}_${DEB_ARCH}.deb"',
          ),
        ),
      );
      expect(
        _read(_flatpakBuilder),
        allOf(
          contains('readonly ASSET_STEM=$_assetStem'),
          contains(r'BUNDLE="$ROOT/dist/$ASSET_STEM-linux-x64.flatpak"'),
        ),
      );
      expect(_read(_buildScript), contains('ASSET_STEM="$_assetStem"'));
      // The package name stays klabautermann; its description says
      // preview with the app's own label, as the app title does (M16), so
      // M7 drops both together.
      expect(
        _read(_packager),
        contains('DEB_DESCRIPTION="Klabautermann $kPreviewLabel: '),
      );
      expect(AppLocalizationsEn().appTitle, 'Klabautermann $kPreviewLabel');
    });

    test('the master icon covers the largest hicolor size', () {
      final bytes = File(_masterIcon).readAsBytesSync();
      final data = ByteData.sublistView(bytes);
      final width = data.getUint32(16);

      expect(bytes.sublist(0, _pngSignature.length), _pngSignature);
      expect(width, greaterThanOrEqualTo(_iconSizes.last));
      expect(data.getUint32(20), width);
    });

    test(
      'packages a bundle into the .deb and the preview AppImage',
      () async {
        final run = await _packageStubBundle();

        expect(run.result.exitCode, 0, reason: '${run.result.stderr}');
        final version = _appVersion();
        final deb = Directory(
          '${run.out.path}/${_packageName}_$version-1_amd64.deb',
        );
        final appImage = File('${run.out.path}/$_assetStem-linux-x64.AppImage');
        expect(deb.existsSync(), isTrue, reason: '${run.result.stdout}');
        expect(appImage.existsSync(), isTrue, reason: '${run.result.stdout}');

        final control = _read('${deb.path}/DEBIAN/control');
        expect(
          control.split('\n'),
          containsAllInOrder([
            'Package: $_packageName',
            'Version: $version-1',
            'Section: admin',
            'Architecture: amd64',
            startsWith('Depends: '),
            startsWith('Description: Klabautermann (preview): '),
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
          _read('${deb.path}/usr/share/applications/$_linuxDesktopFile'),
          _desktopEntry(exec: _packageName),
        );
        expect(
          _read('${deb.path}/usr/bin/$_packageName'),
          '#!/bin/sh\n'
          'exec /usr/lib/$_packageName/$_linuxBinaryName "\$@"\n',
        );
        expect(
          File(
            '${deb.path}/usr/lib/$_packageName/$_linuxBinaryName',
          ).existsSync(),
          isTrue,
        );
        for (final size in _iconSizes) {
          expect(
            _read(
              '${deb.path}/usr/share/icons/hicolor/${size}x$size/apps/'
              '$_packageName.png',
            ),
            '${size}x$size',
            reason: 'hicolor $size',
          );
        }
        final copyright = _read(
          '${deb.path}/usr/share/doc/$_packageName/copyright',
        );
        expect(copyright, startsWith('Klabautermann: '));
        expect(copyright, contains('Upstream-Version: $version\n'));
        expect(copyright, endsWith(_read('../../LICENSE')));

        final appDir = '${appImage.path}.appdir';
        expect(
          _read('$appDir/$_linuxDesktopFile'),
          _desktopEntry(exec: 'AppRun'),
        );
        expect(
          _read('$appDir/AppRun'),
          contains(
            'exec "\$HERE/usr/lib/$_packageName/$_linuxBinaryName" "\$@"',
          ),
        );
        expect(_read('$appDir/$_packageName.png'), '512x512');
        expect(File('$appDir/.DirIcon').existsSync(), isTrue);
        expect(Directory('$appDir/usr/bin').existsSync(), isFalse);
      },
      skip: Platform.isLinux ? false : 'the Linux packager needs a Linux host',
    );
  });

  group('Flatpak', () {
    test('grants exactly the 04 §12.1 permissions', () {
      final manifest = _read(_flatpakManifest);
      final finishArgs = _finishArgs(manifest);

      expect(finishArgs.toSet(), _flatpakFinishArgs);
      expect(finishArgs, hasLength(_flatpakFinishArgs.length));
      expect(manifest, isNot(contains('--filesystem=home')));
      expect(manifest, isNot(contains('--filesystem=host')));
    });

    test('the manifest and builder agree on the app id and command', () {
      expect(
        _read(_flatpakManifest),
        allOf(
          contains('id: $_linuxApplicationId\n'),
          // The .deb's /usr/bin wrapper, relaid under /app/bin.
          contains('command: $_packageName\n'),
        ),
      );
      expect(
        _read(_flatpakBuilder),
        allOf([
          contains('readonly APP_ID=$_linuxApplicationId'),
          contains(r'source "$ROOT/../scripts/flatpak-repack.sh"'),
          contains("-name '${_packageName}_*.deb'"),
          contains('(cd app/klabautermann_app && flutter build linux'),
        ]),
      );
    });
  });

  group('build and release scripts', () {
    test('build.sh fails closed and defers to the suite orchestrator', () {
      expect(
        _read(_buildScript),
        allOf([
          contains('APP_DIR="app/klabautermann_app"'),
          contains('platform scaffold is missing'),
          isNot(contains('flutter create --org')),
          contains('HAUNTWARE_BUILD_ORCHESTRATED'),
          contains('scripts/package-linux.sh --appimage=best-effort'),
          contains('scripts/build-flatpak.sh "\$deb"'),
        ]),
      );
    });

    test('release.sh forwards to the suite release', () {
      final release = _read(_releaseScript);

      expect(release, contains('/scripts/release.sh" "\$@"'));
      expect(release, isNot(contains('once it exists')));
    });
  });
}

/// The desktop entry both installers ship, with [exec] as its command.
String _desktopEntry({required String exec}) =>
    '[Desktop Entry]\n'
    'Type=Application\n'
    'Name=Klabautermann\n'
    'GenericName=Server Manager\n'
    "Comment=The kobold that keeps the ship's engines lit\n"
    'Exec=$exec\n'
    'Icon=$_packageName\n'
    'Terminal=false\n'
    'Categories=Network;System;Monitor;\n'
    'Keywords=SSH;Server;Docker;Monitoring;Fleet;\n'
    '# The packaged build reports this X11 WM_CLASS class (the instance is the'
    '\n# lowercase application id); StartupWMClass is case-sensitive.\n'
    'StartupWMClass=$_linuxStartupWmClass\n';

/// Runs the real packager on a stub bundle in a scratch directory. Stubs
/// stand in for the host tools: readelf and objdump report a glibc,
/// libstdc++ and GTK runtime, magick writes each requested size into its
/// output, dpkg-deb copies the staged tree to the .deb path, and
/// appimagetool copies the AppDir next to its output.
Future<({ProcessResult result, Directory out})> _packageStubBundle() async {
  final sandbox = Directory.systemTemp.createTempSync('klab-package-test-');
  addTearDown(() => sandbox.deleteSync(recursive: true));

  final bundle = Directory('${sandbox.path}/bundle/lib')
    ..createSync(recursive: true);
  File('${bundle.parent.path}/$_linuxBinaryName').writeAsStringSync('ELF');
  File('${bundle.path}/libapp.so').writeAsStringSync('ELF');

  final bin = Directory('${sandbox.path}/bin')..createSync();
  void tool(String name, String body) {
    File('${bin.path}/$name').writeAsStringSync('#!/usr/bin/env bash\n$body');
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
  final tools = bin.listSync().map((entity) => entity.path);
  await Process.run('chmod', ['+x', ...tools]);

  final out = Directory('${sandbox.path}/out');
  final result = await Process.run(
    'bash',
    [_packager, '--bundle', bundle.parent.path, '--output-dir', out.path],
    environment: {
      'PATH': '${bin.path}:${Platform.environment['PATH']}',
      'APPIMAGETOOL': '${bin.path}/appimagetool',
    },
  );

  return (result: result, out: out);
}

/// Every item of the manifest's `finish-args` block, up to the next
/// top-level key. flatpak-builder also applies quoted, commented and
/// folded items, so a line in the block that is not a plain `  - --flag`
/// item fails the test rather than escaping the permission check.
List<String> _finishArgs(String manifest) {
  final lines = manifest.split('\n');
  final keys = lines.where(
    (line) => !line.trimLeft().startsWith('#') && line.contains('finish-args'),
  );
  expect(keys, ['finish-args:'], reason: 'one block-style finish-args key');

  final plainItem = RegExp(r'^  - (--\S+)$');
  final items = <String>[];
  for (final line in lines.skip(lines.indexOf('finish-args:') + 1)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    if (!line.startsWith(' ')) break;

    final item = plainItem.firstMatch(line);
    expect(item, isNotNull, reason: 'not a plain finish-args item: "$line"');
    items.add(item![1]!);
  }

  return items;
}

/// The app's semantic version, as the packager reads it from pubspec.yaml.
String _appVersion() {
  final line = _read(
    'pubspec.yaml',
  ).split('\n').firstWhere((line) => line.startsWith('version:'));

  return line.substring('version:'.length).trim().split('+').first;
}

/// Reads a text file with line endings normalized, so a CRLF checkout
/// compares like an LF one.
String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');
