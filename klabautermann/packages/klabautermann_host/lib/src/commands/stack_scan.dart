/// STK-08's folder scan (03 §7.16): the compose files in the folders the
/// user chose and the folders right below them, which a stack with no
/// containers is found by. One `find` over every folder, NUL-separated
/// so a name with a line break stays one name.
library;

import '../hws/collector.dart' show ArgValidators;
import 'commands.dart' show HostCommandError;

/// The names `docker compose` reads, overrides included (02 STK-08).
const List<String> kComposeFilePatterns = [
  'compose*.yml',
  'compose*.yaml',
  'docker-compose*.yml',
  'docker-compose*.yaml',
];

/// Builds and parses the folder scan.
abstract final class StackScanCommands {
  /// `find <dir>/... -maxdepth 2 -type f ( -name ... ) -print0`. Each
  /// folder is passed with a trailing slash, so a folder that is a
  /// symbolic link is searched rather than listed as the link. Throws
  /// [HostCommandError] for a path that is not absolute and normalized
  /// (03 §8.8), holds a control character, or for no folders.
  static List<String> find(List<String> directories) {
    if (directories.isEmpty) {
      throw const HostCommandError('no folders to scan');
    }
    final names = <String>[];
    for (final pattern in kComposeFilePatterns) {
      if (names.isNotEmpty) names.add('-o');
      names.addAll(['-name', pattern]);
    }
    return [
      'find',
      for (final directory in directories) _folder(directory),
      '-maxdepth',
      '2',
      '-type',
      'f',
      '(',
      ...names,
      ')',
      '-print0',
    ];
  }

  /// The compose files [find] printed for [directories], sorted and
  /// without repeats: only paths inside one of them, with a compose
  /// name, and no control character.
  static List<String> parse(String stdout, List<String> directories) {
    final folders = [for (final d in directories) _folder(d)];
    final found = <String>{};
    for (final path in stdout.split('\u0000')) {
      if (path.isEmpty || _hasControl(path)) continue;
      if (!folders.any(path.startsWith)) continue;
      if (!_composeName.hasMatch(path.substring(path.lastIndexOf('/') + 1))) {
        continue;
      }
      found.add(path);
    }
    return found.toList()..sort();
  }

  static final _composeName = RegExp(r'^(docker-)?compose[^/]*\.ya?ml$');

  static bool _hasControl(String value) =>
      value.codeUnits.any((c) => c < 0x20 || c == 0x7f);

  static String _folder(String directory) {
    final reason = ArgValidators.absolutePath(directory);
    if (reason != null) throw HostCommandError(reason, argument: directory);
    if (_hasControl(directory)) {
      throw HostCommandError(
        'path has a control character',
        argument: directory,
      );
    }
    return directory.endsWith('/') ? directory : '$directory/';
  }
}
