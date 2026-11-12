import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_licenses/ghost_licenses.dart';

/// AboutLibraries' res/raw/aboutlibraries.json, reduced to what is read.
final _definitions = jsonEncode({
  'libraries': [
    {
      'uniqueId': 'androidx.core:core',
      'artifactVersion': '1.17.0',
      'licenses': ['Apache-2.0'],
    },
    {
      'uniqueId': 'com.google.crypto.tink:tink-android',
      'artifactVersion': '1.21.0',
      'licenses': ['Apache-2.0'],
    },
    {
      'uniqueId': 'org.example:no-text',
      'licenses': ['Example'],
    },
  ],
  'licenses': {
    'Apache-2.0': {
      'name': 'Apache License 2.0',
      'content': 'Apache License\nVersion 2.0, January 2004',
    },
    'Example': {'name': 'Example License', 'url': 'https://example.org/l'},
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ghost_licenses');

  setUp(LicenseRegistry.reset);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    LicenseRegistry.reset();
  });

  test('lists every library under the license it uses', () {
    final entries = libraryLicenses(_definitions);

    expect(entries.map((entry) => entry.packages.toList()), [
      [
        'androidx.core:core 1.17.0',
        'com.google.crypto.tink:tink-android 1.21.0',
      ],
      ['org.example:no-text'],
    ]);
    String text(LicenseEntry entry) =>
        entry.paragraphs.map((paragraph) => paragraph.text).join(' ');
    expect(text(entries.first), contains('Version 2.0, January 2004'));
    expect(
      text(entries.last),
      allOf(contains('Example License'), contains('https://example.org/l')),
    );
  });

  test("registers the APK's libraries on Android", () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return _definitions;
        });

    registerPlatformLicenses();
    final packages = await LicenseRegistry.licenses
        .expand((entry) => entry.packages)
        .toList();

    expect(calls, ['libraryDefinitions']);
    expect(packages, contains('androidx.core:core 1.17.0'));
  });

  test('registers nothing on other platforms', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;

    registerPlatformLicenses();

    expect(await LicenseRegistry.licenses.toList(), isEmpty);
  });

  test('skips a malformed library and keeps the rest', () {
    final definitions = jsonEncode({
      'libraries': [
        {'uniqueId': 'no-licenses'},
        {
          'uniqueId': 'bad-key',
          'licenses': [7],
        },
        'not an object',
        {
          'uniqueId': 'androidx.core:core',
          'artifactVersion': '1.17.0',
          'licenses': ['Apache-2.0'],
        },
      ],
      'licenses': {
        'Apache-2.0': {'name': 'Apache License 2.0', 'content': 'Apache'},
      },
    });

    expect(
      libraryLicenses(definitions).map((entry) => entry.packages.toList()),
      [
        ['androidx.core:core 1.17.0'],
      ],
    );
  });

  group('a failing Android source', () {
    late List<FlutterErrorDetails> reported;
    late FlutterExceptionHandler? previousOnError;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      reported = [];
      previousOnError = FlutterError.onError;
      FlutterError.onError = reported.add;
      // Flutter's own notices, which must survive the failure.
      LicenseRegistry.addLicense(
        () => Stream.value(
          const LicenseEntryWithLineBreaks(['flutter'], 'Flutter notice'),
        ),
      );
    });
    tearDown(() => FlutterError.onError = previousOnError);

    for (final (name, reply) in <(String, Future<Object?> Function())>[
      ('a missing plugin', () async => throw MissingPluginException()),
      ('a null reply', () async => null),
      ('unreadable definitions', () async => '{"libraries": 5}'),
    ]) {
      test('leaves the other notices on $name', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) => reply());

        registerPlatformLicenses();
        final entries = await LicenseRegistry.licenses.toList();

        expect(entries.expand((entry) => entry.packages), [
          'flutter',
          'Android libraries',
        ]);
        expect(
          entries.last.paragraphs.single.text,
          contains('could not be read'),
        );
        expect(reported, hasLength(1));
        expect(reported.single.library, 'ghost_licenses');
      });
    }
  });
}
