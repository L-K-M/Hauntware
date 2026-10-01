import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _ciKeyStorePath = 'android/app/ci-release.jks';
const _ciPropertiesPath = 'android/key.properties';
const _ciCertificatePath = 'android/ci-signing-certificate.sha256';
const _publicKeyWarning =
    '# Public debug-grade CI key; never place a production secret in this file.';
const _jksMagic = <int>[0xfe, 0xed, 0xfe, 0xed];
const _propertyNames = <String>{
  'storeFile',
  'storePassword',
  'keyAlias',
  'keyPassword',
};

void main() {
  test('release APK uses the committed public CI identity', () {
    final propertiesFile = File(_ciPropertiesPath);
    final keyStore = File(_ciKeyStorePath);
    final certificate = File(_ciCertificatePath);

    expect(propertiesFile.existsSync(), isTrue);
    expect(keyStore.existsSync(), isTrue);
    expect(certificate.existsSync(), isTrue);

    final propertiesText = propertiesFile.readAsStringSync();
    expect(propertiesText.split('\n').first, _publicKeyWarning);

    final properties = _parseProperties(propertiesText);
    expect(properties.keys, _propertyNames);
    expect(properties['storeFile'], 'ci-release.jks');
    for (final name in _propertyNames) {
      expect(properties[name], isNotEmpty, reason: '$name must be public');
    }

    final keyStoreBytes = keyStore.readAsBytesSync();
    expect(keyStoreBytes, hasLength(greaterThan(_jksMagic.length)));
    expect(keyStoreBytes.take(_jksMagic.length), _jksMagic);

    final certificateSha256 = certificate.readAsStringSync().trim();
    expect(certificateSha256, matches(RegExp(r'^[0-9A-F]{64}$')));

    final gradle = _read('android/app/build.gradle.kts');
    expect(
      gradle,
      allOf(<Matcher>[
        contains('rootProject.file(ciSigningPropertiesPath)'),
        contains('check(ciSigningPropertiesFile.isFile)'),
        contains('rootProject.file(ciSigningCertificatePath)'),
        contains('ciSigningCertificateFile.readText().trim().uppercase()'),
        contains('check(actualCiCertificateSha256 == '),
        contains('create(ciSigningConfigName)'),
        contains(
          'signingConfig = signingConfigs.getByName(ciSigningConfigName)',
        ),
        isNot(contains('signingConfigs.getByName("debug")')),
      ]),
    );
  });

  test('public signing files are narrowly allowlisted', () {
    final androidIgnore = _read('android/.gitignore');
    expect(androidIgnore, contains('!key.properties'));
    expect(androidIgnore, contains('!app/ci-release.jks'));

    final gitleaks = _read('../../.gitleaks.toml');
    expect(
      gitleaks,
      allOf(
        contains(r'''^app/poltergeist_app/android/app/ci-release\.jks$'''),
        contains(r'''^app/poltergeist_app/android/key\.properties$'''),
      ),
    );
  });
}

Map<String, String> _parseProperties(String contents) {
  final properties = <String, String>{};
  for (final line in contents.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

    final separator = trimmed.indexOf('=');
    expect(separator, greaterThan(0), reason: 'Invalid property: $line');
    properties[trimmed.substring(0, separator)] = trimmed.substring(
      separator + 1,
    );
  }

  return properties;
}

String _read(String path) => File(path).readAsStringSync();
