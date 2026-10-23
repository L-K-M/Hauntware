import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

/// `dart test` runs the workspace's suites concurrently as isolates of one
/// process, and they share its working directory. A suite that moves it
/// moves it for every other suite, and two that each save and restore it
/// can interleave and leave it on a deleted directory. A test that needs
/// another working directory runs its subject in a child process instead.
void main() {
  test('no suite moves the shared working directory', () {
    final library = Isolate.resolvePackageUriSync(
      Uri.parse('package:poltergeist_core/poltergeist_core.dart'),
    )!;
    // CI runs every package under poltergeist/packages in one `dart test`;
    // a layout change that moved one out of here fails below rather than
    // silently narrowing the scan.
    final packages = Directory.fromUri(library.resolve('../../'));
    final separator = Platform.pathSeparator;
    final tests = {
      for (final package in packages.listSync().whereType<Directory>())
        package.uri.pathSegments.lastWhere((segment) => segment.isNotEmpty):
            Directory('${package.path}${separator}test'),
    }..removeWhere((_, test) => !test.existsSync());
    expect(tests.keys, containsAll(['poltergeist_core', 'poltergeist_sync']));

    final assignment = RegExp(r'Directory\.current\s*=(?!=)');
    final offenders = [
      for (final test in tests.values)
        for (final entity in test.listSync(recursive: true, followLinks: false))
          if (entity is File &&
              entity.path.endsWith('.dart') &&
              !entity.path.endsWith('working_directory_guard_test.dart') &&
              assignment.hasMatch(entity.readAsStringSync()))
            entity.path,
    ];
    expect(offenders, isEmpty);
  });
}
