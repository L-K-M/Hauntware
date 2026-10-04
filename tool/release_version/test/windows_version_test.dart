import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Every suite app, relative to the repository root.
const _apps = [
  'planchette/app/planchette_app',
  'seance/app/seance_app',
  'poltergeist/app/poltergeist_app',
];

void main() {
  // The suite build code (e.g. 1.9.0+1090099) exceeds the 16 bits of a
  // Windows VERSIONINFO field, so FILEVERSION/PRODUCTVERSION must carry
  // the semantic version only: 1,9,0,0 rather than 1,9,0,1090099.
  for (final app in _apps) {
    test('$app keeps the build code out of Windows version fields', () {
      final resource = File(
        p.join(_repositoryRoot().path, app, 'windows/runner/Runner.rc'),
      ).readAsStringSync();

      expect(
        resource,
        contains(
          '#define VERSION_AS_NUMBER '
          'FLUTTER_VERSION_MAJOR,FLUTTER_VERSION_MINOR,'
          'FLUTTER_VERSION_PATCH,0',
        ),
      );
      expect(resource, isNot(contains('FLUTTER_VERSION_BUILD')));
    });
  }
}

Directory _repositoryRoot() {
  var candidate = Directory.current.absolute;
  while (true) {
    if (File(p.join(candidate.path, 'scripts/release.sh')).existsSync() &&
        File(p.join(candidate.path, 'pubspec.yaml')).existsSync()) {
      return candidate;
    }

    final parent = candidate.parent;
    if (p.equals(parent.path, candidate.path)) {
      throw StateError('repository root not found from ${Directory.current}');
    }
    candidate = parent;
  }
}
