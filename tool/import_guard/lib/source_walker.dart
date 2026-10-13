// The scan walk shared by the root import and protocol guards. It lives
// in import_guard's folder because that guard's CLI fixture copies the
// folder whole; the protocol guard imports it by relative path.
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
/// not reach outside the tree it claims to check. [scanAreas] names the
/// product's configured scan roots so generated-tree exclusions match
/// whichever areas the product declares.
Stream<File> dartSources(
  Directory directory,
  String root,
  Set<String> scanAreas,
) async* {
  await for (final entity in directory.list(followLinks: false)) {
    if (_isGenerated(entity.path, root, scanAreas)) continue;
    if (entity is Link) {
      throw FileSystemException('Linked scan input', entity.path);
    }
    if (entity is Directory) {
      yield* dartSources(entity, root, scanAreas);
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
bool _isGenerated(String path, String root, Set<String> scanAreas) {
  final segments = p.split(p.relative(path, from: root));
  if (segments.isEmpty || !scanAreas.contains(segments.first)) return false;
  return switch (segments.sublist(1)) {
    [_, final name] => _generatedDirectories.contains(name),
    [_, 'ios' || 'macos', 'Pods' || '.symlinks'] => true,
    [_, final platform, 'build'] => _nativePlatforms.contains(platform),
    [_, 'android', 'app', 'build'] => true,
    [_, 'ios' || 'macos', 'Flutter', 'ephemeral'] => true,
    [_, 'linux' || 'windows', 'flutter', 'ephemeral'] => true,
    _ => false,
  };
}
