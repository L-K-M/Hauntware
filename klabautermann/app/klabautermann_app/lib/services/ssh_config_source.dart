import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart' show expandHomePath;

/// The largest config the app reads. A real `~/.ssh/config` is a few KiB;
/// the cap keeps a stray huge file from being copied into the engine.
const int kSshConfigMaxBytes = 1024 * 1024;

/// Why the ssh_config text is not available.
enum SshConfigReadFailure {
  /// Nothing exists at the path: this computer has no ssh_config.
  missing,

  /// Something exists but could not be read: permissions, an I/O error, or
  /// a directory or device instead of a regular file.
  unreadable,

  /// The file is larger than [kSshConfigMaxBytes].
  tooLarge,
}

/// The outcome of reading the ssh_config: its text or why there is none.
@immutable
sealed class SshConfigRead {
  const SshConfigRead();
}

final class SshConfigText extends SshConfigRead {
  const SshConfigText(this.text);

  final String text;
}

final class SshConfigUnavailable extends SshConfigRead {
  const SshConfigUnavailable(this.failure);

  final SshConfigReadFailure failure;
}

/// Where the FL-02 import gets its config text. The app reads the file and
/// the engine only parses what it is sent (03 §4.2), so this is the one
/// place that touches the file system; widget tests substitute a fake.
abstract interface class SshConfigSource {
  /// Reads the config. Never throws for file-system problems; they come
  /// back as [SshConfigUnavailable].
  Future<SshConfigRead> read();
}

/// [SshConfigSource] over `~/.ssh/config` with `dart:io`, read-only.
final class FileSshConfigSource implements SshConfigSource {
  const FileSshConfigSource(this.path);

  /// The config file's absolute path.
  final String path;

  @override
  Future<SshConfigRead> read() async {
    try {
      final type = await FileSystemEntity.type(path);
      if (type == FileSystemEntityType.notFound) {
        return const SshConfigUnavailable(SshConfigReadFailure.missing);
      }
      // Only regular files: a FIFO at the path would block the read forever.
      if (type != FileSystemEntityType.file) {
        return const SshConfigUnavailable(SshConfigReadFailure.unreadable);
      }

      final file = File(path);
      if (await file.length() > kSshConfigMaxBytes) {
        return const SshConfigUnavailable(SshConfigReadFailure.tooLarge);
      }
      final bytes = await file.readAsBytes();
      // The file can grow between the two calls.
      if (bytes.length > kSshConfigMaxBytes) {
        return const SshConfigUnavailable(SshConfigReadFailure.tooLarge);
      }
      // ssh reads the config as bytes; a stray Latin-1 byte in a comment
      // must not make the whole file unreadable.
      return SshConfigText(utf8.decode(bytes, allowMalformed: true));
    } on FileSystemException {
      return const SshConfigUnavailable(SshConfigReadFailure.unreadable);
    }
  }
}

/// The FL-02 config source for [platform], or null where there is none:
/// phones have no ssh_config, so only desktops import one. Also null when
/// [environment] names no home directory to find `~/.ssh/config` under,
/// so the app offers no entry that could only fail.
SshConfigSource? sshConfigSourceFor(
  TargetPlatform platform,
  Map<String, String> environment,
) {
  switch (platform) {
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
      break;
    case TargetPlatform.android:
    case TargetPlatform.fuchsia:
    case TargetPlatform.iOS:
      return null;
  }

  // Win32-OpenSSH reads %USERPROFILE%\.ssh\config and ignores HOME, which
  // expandHomePath would prefer; a HOME set for Emacs or MSYS tools must
  // not point the import at another file. Windows' file APIs accept the
  // joined forward slashes.
  final homeEnvironment = platform == TargetPlatform.windows
      ? {'USERPROFILE': ?environment['USERPROFILE']}
      : environment;
  const configPath = '~/.ssh/config';
  final path = expandHomePath(
    configPath,
    environment: homeEnvironment,
    isMacOS: platform == TargetPlatform.macOS,
  );
  if (path == configPath) return null;
  return FileSshConfigSource(path);
}
