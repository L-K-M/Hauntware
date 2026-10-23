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
    final packages = Directory.fromUri(library.resolve('../../'));
    final separator = Platform.pathSeparator;
    final assignment = RegExp(r'Directory\.current\s*=(?!=)');
    final offenders = [
      for (final entity in packages.listSync(recursive: true))
        if (entity is File &&
            entity.path.endsWith('.dart') &&
            entity.path.contains('${separator}test$separator') &&
            !entity.path.endsWith('working_directory_guard_test.dart') &&
            assignment.hasMatch(entity.readAsStringSync()))
          entity.path,
    ];
    expect(offenders, isEmpty);
  });
}
