import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// local_auth_windows fetches two NuGet packages that compile into the
/// Windows build: Microsoft's WIL and C++/WinRT. No pub package carries
/// their licenses, so they are chunks of this app's LICENSE, which Flutter
/// copies into NOTICES: it splits a package LICENSE on lines of 80 hyphens,
/// and each chunk opens with the names it covers and a blank line.
void main() {
  final chunks = File('LICENSE').readAsStringSync().split('\n${'-' * 80}\n');
  final byName = {
    for (final chunk in chunks)
      chunk.substring(0, chunk.indexOf('\n\n')): chunk,
  };

  test("LICENSE carries Séance's own license", () {
    expect(byName['seance_app'], contains('unlicense.org'));
  });

  test('LICENSE carries the NuGet packages local_auth_windows builds', () {
    final cmake = _packageFile('local_auth_windows', 'windows/CMakeLists.txt');
    String pin(String name) =>
        RegExp('set\\($name "([^"]+)"\\)').firstMatch(cmake)![1]!;

    expect(
      byName['Windows Implementation Libraries (WIL)'],
      allOf(
        contains(
          'Microsoft.Windows.ImplementationLibrary ${pin('WIL_VERSION')}',
        ),
        contains('Permission is hereby granted'),
      ),
    );
    expect(
      byName['C++/WinRT'],
      allOf(
        contains('Microsoft.Windows.CppWinRT ${pin('CPPWINRT_VERSION')}'),
        contains('Permission is hereby granted'),
      ),
    );
  });
}

/// [path] inside the resolved [package], found through the package config.
String _packageFile(String package, String path) {
  final config = File('.dart_tool/package_config.json');
  final json = jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
  final entry = (json['packages']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .singleWhere((entry) => entry['name'] == package);
  final root = entry['rootUri']! as String;
  final base = config.absolute.uri.resolve(
    root.endsWith('/') ? root : '$root/',
  );
  return File.fromUri(base.resolve(path)).readAsStringSync();
}
