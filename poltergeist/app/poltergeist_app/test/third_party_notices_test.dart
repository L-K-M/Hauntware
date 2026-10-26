import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The vendored pdfium_dart bundles a prebuilt PDFium. Its license texts,
/// and those of the libraries compiled into it, travel in pdfium_dart's
/// LICENSE (third_party/pdfium_dart/tool/pdfium_licenses.py writes them),
/// which Flutter copies into the app's NOTICES: it splits a package
/// LICENSE on lines of 80 hyphens, and each chunk opens with the names it
/// covers and a blank line.
void main() {
  const package = '../../third_party/pdfium_dart';
  final config =
      jsonDecode(File('$package/tool/pdfium_licenses.json').readAsStringSync())
          as Map<String, Object?>;

  test("pdfium_dart's LICENSE carries PDFium and its components", () {
    final chunks = File(
      '$package/LICENSE',
    ).readAsStringSync().split('\n${'-' * 80}\n');
    final byName = {
      for (final chunk in chunks)
        chunk.substring(0, chunk.indexOf('\n\n')): chunk,
    };

    expect(byName.keys, [
      'pdfium_dart',
      for (final component in config['components']! as List<Object?>)
        (component! as Map<String, Object?>)['name'],
    ]);
    expect(byName['pdfium_dart'], contains('Permission is hereby granted'));
    expect(byName['PDFium'], contains('Copyright 2014 The PDFium Authors'));
    expect(
      byName['PDFium: FreeType'],
      contains('The FreeType Project LICENSE'),
    );
  });

  test('the texts come from the release the build hook downloads', () {
    final hook = File('$package/hook/build.dart').readAsStringSync();
    final release = RegExp(
      r"const _pdfiumRelease = '([^']+)';",
    ).firstMatch(hook)?[1];

    expect(release, isNotNull);
    expect(Uri.decodeComponent(release!), config['release']);
  });
}
