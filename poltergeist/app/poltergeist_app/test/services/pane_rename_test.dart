import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_rename.dart';

void main() {
  group('renameNameError (02 §2.6)', () {
    test('a plain name passes on every pane', () {
      expect(
        renameNameError(
          'report.txt',
          remote: false,
          platform: TargetPlatform.linux,
        ),
        isNull,
      );
      expect(
        renameNameError(
          'report.txt',
          remote: true,
          platform: TargetPlatform.linux,
        ),
        isNull,
      );
    });

    test('blank and whitespace-only names are empty', () {
      for (final name in ['', '   ', '\t']) {
        expect(
          renameNameError(
            name,
            remote: false,
            platform: TargetPlatform.linux,
          ),
          RenameNameError.empty,
          reason: '"$name" must reject as empty',
        );
      }
    });

    test('the path separator rejects everywhere', () {
      for (final remote in [true, false]) {
        expect(
          renameNameError(
            'a/b',
            remote: remote,
            platform: TargetPlatform.linux,
          ),
          RenameNameError.separator,
          reason: 'a rename never moves an item across folders',
        );
      }
    });

    test('a local Windows pane rejects the NTFS-reserved set', () {
      for (final name in [
        'a<b',
        'a>b',
        'a:b',
        'a"b',
        'a\\b',
        'a|b',
        'a?b',
        'a*b',
        'a\x01b',
        'a\x7Fb',
      ]) {
        expect(
          renameNameError(
            name,
            remote: false,
            platform: TargetPlatform.windows,
          ),
          RenameNameError.invalid,
          reason: '$name must reject on a local Windows pane',
        );
      }
    });

    test('a local Windows pane rejects device names and a trailing '
        'dot or space', () {
      for (final name in [
        'CON',
        'con.txt',
        'PRN',
        'aux',
        'NUL',
        'COM1',
        'com9.log',
        'LPT1',
        'lpt9',
        'report.',
        'report ',
      ]) {
        expect(
          renameNameError(
            name,
            remote: false,
            platform: TargetPlatform.windows,
          ),
          RenameNameError.invalid,
          reason: '$name must reject on a local Windows pane',
        );
      }
      // Not reserved: digit suffixes past 9 and longer stems are
      // ordinary names.
      for (final name in ['COM0', 'COM10', 'LPT0', 'console', 'contract']) {
        expect(
          renameNameError(
            name,
            remote: false,
            platform: TargetPlatform.windows,
          ),
          isNull,
          reason: '$name is not a reserved device name',
        );
      }
      // A remote pane stays permissive — the server may accept names
      // the client OS would not.
      expect(
        renameNameError(
          'CON',
          remote: true,
          platform: TargetPlatform.windows,
        ),
        isNull,
      );
      // Trailing dots/spaces are legal POSIX names on non-Windows
      // locals.
      expect(
        renameNameError(
          'report.',
          remote: false,
          platform: TargetPlatform.linux,
        ),
        isNull,
      );
      expect(
        renameNameError(
          'report ',
          remote: false,
          platform: TargetPlatform.macOS,
        ),
        isNull,
      );
    });

    test('POSIX-local and remote panes keep the permissive rule', () {
      // The same NTFS-reserved characters are legal names on a POSIX
      // local filesystem and on an SFTP server — only the client OS's
      // own filesystem may refuse them.
      expect(
        renameNameError(
          'a:b?c',
          remote: false,
          platform: TargetPlatform.linux,
        ),
        isNull,
      );
      expect(
        renameNameError(
          'a:b?c',
          remote: false,
          platform: TargetPlatform.macOS,
        ),
        isNull,
      );
      // A remote pane stays POSIX-permissive even on a Windows client:
      // the server may accept names the client's OS would not.
      expect(
        renameNameError(
          'a:b?c',
          remote: true,
          platform: TargetPlatform.windows,
        ),
        isNull,
      );
      // …but the separator still rejects remotely.
      expect(
        renameNameError(
          'a/b',
          remote: true,
          platform: TargetPlatform.windows,
        ),
        RenameNameError.separator,
      );
    });
  });

  group('renameParentPrefix (02 §2.6)', () {
    String prefix(String path, String name, {String? fallback}) =>
        renameParentPrefix(path: path, name: name, fallbackDirectory: fallback);

    test("keeps the path's own separators", () {
      expect(prefix('/a/b', 'b'), '/a/');
      expect(prefix('/x', 'x'), '/');
      expect(prefix(r'C:\x\y', 'y'), r'C:\x\');
      expect(prefix(r'\\srv\share\f.txt', 'f.txt'), r'\\srv\share\');
    });

    test('a POSIX name may end in a backslash', () {
      expect(prefix(r'/d/na\', r'na\'), '/d/');
    });

    test('falls back to the directory without doubling its separator', () {
      expect(prefix('orphan', 'orphan', fallback: '/home'), '/home/');
      expect(prefix('orphan', 'orphan', fallback: '/'), '/');
      expect(prefix('orphan', 'orphan', fallback: r'C:\'), r'C:\');
    });
  });
}
