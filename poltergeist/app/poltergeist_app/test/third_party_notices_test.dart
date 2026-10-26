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

  // file_picker's iOS build resolves Swift packages that no pub package
  // carries the licenses of, so they are chunks of this app's LICENSE.
  test("LICENSE carries the Swift packages file_picker's iOS build uses", () {
    final chunks = File('LICENSE').readAsStringSync().split('\n${'-' * 80}\n');
    final byName = {
      for (final chunk in chunks)
        chunk.substring(0, chunk.indexOf('\n\n')): chunk,
    };
    final manifest = _packageFile(
      'file_picker',
      'ios/file_picker/Package.swift',
    );

    expect(byName['poltergeist_app'], contains('unlicense.org'));
    // The chunks record this dependency and what it resolves; a change
    // here needs the new packages' texts.
    expect(
      RegExp(
        r'\.package\(url: "([^"]+)"',
      ).allMatches(manifest).map((match) => match[1]),
      ['https://github.com/zhangao0086/DKImagePickerController'],
    );
    expect(manifest, contains('branch: "4.3.9"'));
    for (final name in _swiftPackageChunks) {
      expect(byName[name], contains('Permission is hereby granted'));
    }
  });
}

/// The LICENSE chunks for DKImagePickerController and the packages it
/// resolves, by the names each opens with.
const _swiftPackageChunks = [
  'DKImagePickerController\nDKCamera\nDKPhotoGallery',
  'TOCropViewController',
  'SwiftyGif',
  'SDWebImage',
];

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
