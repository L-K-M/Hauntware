import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/services/ssh_config_source.dart';

void main() {
  group('sshConfigSourceFor (FL-02)', () {
    const home = {'HOME': '/home/me'};

    test('phones have no ssh_config', () {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.fuchsia,
      ]) {
        expect(sshConfigSourceFor(platform, home), isNull, reason: '$platform');
      }
    });

    test('desktops read ~/.ssh/config under the home directory', () {
      for (final platform in [TargetPlatform.linux, TargetPlatform.macOS]) {
        final source = sshConfigSourceFor(platform, home);
        expect(
          (source as FileSshConfigSource).path,
          '/home/me/.ssh/config',
          reason: '$platform',
        );
      }

      final windows = sshConfigSourceFor(TargetPlatform.windows, const {
        'USERPROFILE': r'C:\Users\me',
      });
      expect((windows as FileSshConfigSource).path, r'C:\Users\me/.ssh/config');
    });

    test('Windows ignores HOME, as Win32-OpenSSH does', () {
      // HOME set globally for Emacs or MSYS tools must not move the file.
      final source = sshConfigSourceFor(TargetPlatform.windows, const {
        'HOME': r'D:\home',
        'USERPROFILE': r'C:\Users\me',
      });
      expect((source as FileSshConfigSource).path, r'C:\Users\me/.ssh/config');

      expect(
        sshConfigSourceFor(TargetPlatform.windows, const {'HOME': r'D:\home'}),
        isNull,
      );
    });

    test('a macOS sandbox container home resolves to the real home', () {
      final source = sshConfigSourceFor(TargetPlatform.macOS, const {
        'HOME': '/Users/me/Library/Containers/ch.lkmc.klabautermannApp/Data',
      });
      expect((source as FileSshConfigSource).path, '/Users/me/.ssh/config');
    });

    test('no home directory means no import entry', () {
      expect(sshConfigSourceFor(TargetPlatform.linux, const {}), isNull);
    });
  });

  group('FileSshConfigSource', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('klab-ssh-config'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<SshConfigRead> readAt(String name) =>
        FileSshConfigSource('${dir.path}/$name').read();

    test('reads a regular file\'s text', () async {
      File('${dir.path}/config').writeAsStringSync('Host a\n  HostName b\n');

      final read = await readAt('config');

      expect((read as SshConfigText).text, 'Host a\n  HostName b\n');
    });

    test('reports a missing file as missing', () async {
      final read = await readAt('config');

      expect(
        (read as SshConfigUnavailable).failure,
        SshConfigReadFailure.missing,
      );
    });

    test('reports a directory at the path as unreadable', () async {
      Directory('${dir.path}/config').createSync();

      final read = await readAt('config');

      expect(
        (read as SshConfigUnavailable).failure,
        SshConfigReadFailure.unreadable,
      );
    });

    test('decodes stray non-UTF-8 bytes instead of failing', () async {
      // `# caf\xE9` is Latin-1; ssh ignores comments, and so must the read.
      File('${dir.path}/config').writeAsBytesSync([
        ...'# caf'.codeUnits,
        0xE9,
        ...'\nHost a\n'.codeUnits,
      ]);

      final read = await readAt('config');

      expect((read as SshConfigText).text, '# caf\uFFFD\nHost a\n');
    });

    test('keeps a byte-order mark, which ssh rejects the file for', () async {
      // Dart's UTF-8 decoder drops a leading mark; ssh reads its bytes as
      // part of the first keyword, so the engine must see it.
      File(
        '${dir.path}/config',
      ).writeAsBytesSync([0xEF, 0xBB, 0xBF, ...'Host a\n'.codeUnits]);

      final read = await readAt('config');

      expect((read as SshConfigText).text, '\u{FEFF}Host a\n');
    });

    test('refuses a file over the size cap', () async {
      File(
        '${dir.path}/config',
      ).writeAsBytesSync(List.filled(kSshConfigMaxBytes + 1, 0x23));

      final read = await readAt('config');

      expect(
        (read as SshConfigUnavailable).failure,
        SshConfigReadFailure.tooLarge,
      );
    });
  });
}
