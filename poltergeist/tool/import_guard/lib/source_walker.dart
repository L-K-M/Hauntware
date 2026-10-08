// The scan walk shared by the import guard and tool/protocol_guard. It
// lives in import_guard's folder because that guard's CLI fixture copies
// the folder whole; the protocol guard imports it by relative path.
import 'dart:io';

import 'package:path/path.dart' as p;

const _generatedDirectories = {
  '.dart_tool',
  '.git',
  '.symlinks',
  'build',
  'ephemeral',
};
const _nativePlatforms = {'android', 'ios', 'linux', 'macos', 'windows'};

/// The Dart sources under [directory], skipping build outputs relative to
/// the scan [root]. A link anywhere in the walk throws: a scan input must
/// not reach outside the tree it claims to check.
Stream<File> dartSources(Directory directory, String root) async* {
  await for (final entity in directory.list(followLinks: false)) {
    if (_isGenerated(entity.path, root)) continue;
    if (entity is Link) {
      throw FileSystemException('Linked scan input', entity.path);
    }
    if (entity is Directory) {
      yield* dartSources(entity, root);
      continue;
    }
    if (entity is File && p.extension(entity.path) == '.dart') yield entity;
  }
}

/// [path] relative to [root] with `/` separators, as the guards report it.
String relativeSourcePath(String path, String root) =>
    p.posix.joinAll(p.split(p.relative(path, from: root)));

// Exclude build outputs only at package/platform boundaries, never under
// lib/: lib/build and lib/.dart_tool are source paths, while Flutter and
// CocoaPods generate links inside platform projects.
bool _isGenerated(String path, String root) => switch (p.split(
  p.relative(path, from: root),
)) {
  ['packages' || 'app', _, final name] => _generatedDirectories.contains(name),
  ['app', _, 'ios' || 'macos', 'Pods' || '.symlinks'] => true,
  ['app', _, final platform, 'build'] => _nativePlatforms.contains(platform),
  ['app', _, 'android', 'app', 'build'] => true,
  ['app', _, 'ios' || 'macos', 'Flutter', 'ephemeral'] => true,
  ['app', _, 'linux' || 'windows', 'flutter', 'ephemeral'] => true,
  _ => false,
};
