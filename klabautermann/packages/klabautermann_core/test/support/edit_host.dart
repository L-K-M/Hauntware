// A link that plays a host for the edit pipeline's tests (03 §8.5,
// §8.11): the read script over [EditHost.files], `crontab -l` over
// [EditHost.crontabs], the backup and manifest paths, presence checks,
// and `sha256sum` over [EditHost.blobs]; through the elevation prelude
// when the command carries it.
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:seance_core/seance_core.dart' show RemoteCommandResult;

import 'scripted_link.dart';

/// The login user's backup directory and manifest on the host.
const kHostUserBackups = '/home/deploy/.local/state/klabautermann/backups';
const kHostUserManifest = '/home/deploy/.config/klabautermann/manifest.json';

String sha256Of(String text) => sha256.convert(utf8.encode(text)).toString();

/// A file the read script serves: its owner, mode and text, and whether
/// only root may read it.
typedef HostFile = ({int uid, String mode, String text, bool rootOnly});

final class EditHost extends TestLinkBase {
  final files = <String, HostFile>{};
  final crontabs = <String, String>{};

  /// What `[ -e ] && cat` prints for a path: manifests and indexes.
  final readable = <String, String>{};

  /// Paths `sha256sum` and the presence check see, with their content.
  final blobs = <String, String>{};

  /// Directories the presence check sees.
  final directories = <String>{};

  final commands = <String>[];
  bool enforcing = false;

  /// Script names whose runs fail, as a lost elevation or a broken shell
  /// would, with no output.
  final failing = <String>{};

  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) async {
    commands.add(command);
    final elevated = command.contains(' elevate ');
    // Paths are matched as quoted words, which an elevated command line
    // carries too, inside the prelude's own.
    bool names(String path) => command.contains("'$path'");
    if (command.contains('klabautermann-read-if-present')) {
      return _ok(
        readable.entries.where((e) => names(e.key)).firstOrNull?.value ?? '',
      );
    }
    if (command.contains('klabautermann-read')) {
      return _read(files.keys.where(names).firstOrNull, elevated);
    }
    if (command.contains("'crontab' '-l'")) return _crontab(command);
    if (command.contains('XDG_CONFIG_HOME')) return _ok('$kHostUserManifest\n');
    if (command.contains('XDG_STATE_HOME')) return _ok('$kHostUserBackups\n');
    if (failing.any(command.contains)) {
      return const RemoteCommandResult(exitCode: 1);
    }
    if (command.contains('klabautermann-exists')) {
      return _ok(
        [
          for (final path in {...directories, ...readable.keys, ...blobs.keys})
            if (names(path)) '$path\n',
        ].join(),
      );
    }
    if (command.contains('klabautermann-sha256')) {
      return _ok(
        [
          for (final MapEntry(key: path, value: content) in blobs.entries)
            if (names(path)) '${sha256Of(content)}  $path\n',
        ].join(),
      );
    }
    if (command.contains('/sys/fs/selinux/enforce')) {
      return enforcing
          ? _ok('1\n')
          : const RemoteCommandResult(
              exitCode: 1,
              stderr: 'cat: /sys/fs/selinux/enforce: No such file\n',
            );
    }
    return const RemoteCommandResult(exitCode: 0);
  }

  RemoteCommandResult _read(String? path, bool elevated) {
    final file = files[path];
    if (file == null) {
      return const RemoteCommandResult(
        exitCode: 1,
        stderr: 'stat: cannot statx: No such file or directory\n',
      );
    }
    if (file.rootOnly && !elevated) {
      return const RemoteCommandResult(
        exitCode: 1,
        stderr: 'stat: Permission denied\n',
      );
    }
    final bytes = utf8.encode(file.text).length;
    return _ok(
      '$bytes ${file.uid} ${file.uid} ${file.mode} ${sha256Of(file.text)}\n'
      '${file.text}',
    );
  }

  RemoteCommandResult _crontab(String command) {
    final user =
        RegExp(r"'-u' '([a-z_][a-z0-9_-]*)'").firstMatch(command)?[1] ??
        'deploy';
    final table = crontabs[user];
    return table == null
        ? RemoteCommandResult(exitCode: 1, stderr: 'no crontab for $user\n')
        : _ok(table);
  }

  static RemoteCommandResult _ok(String stdout) =>
      RemoteCommandResult(exitCode: 0, stdout: stdout);
}
