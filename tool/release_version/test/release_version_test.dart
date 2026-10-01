// Release tooling stays outside the shipped application.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:test/test.dart';

import '../lib/release_version.dart';

void main() {
  group('ReleaseVersion', () {
    const validVersions = {
      '0.1.0': 10099,
      '1.1.0-beta1': 1010001,
      '1.1.0-beta49': 1010049,
      '1.1.0-rc1': 1010050,
      '1.1.0-rc49': 1010098,
      '1.1.0': 1010099,
      '1.1.1-beta1': 1010101,
      '2099.99.99': 2099999999,
    };

    for (final entry in validVersions.entries) {
      test('maps ${entry.key} to ${entry.value}', () {
        final version = ReleaseVersion.parse(entry.key);

        expect(version.semantic, entry.key);
        expect(version.androidVersionCode, entry.value);
        expect(version.appVersion, '${entry.key}+${entry.value}');
      });
    }

    const invalidVersions = [
      '',
      'v1.0.0',
      '1.0',
      '1.0.0.0',
      '01.0.0',
      '1.00.0',
      '1.0.00',
      '1.0.0+1',
      '1.0.0-alpha1',
      '1.0.0-beta',
      '1.0.0-beta0',
      '1.0.0-beta50',
      '1.0.0-rc',
      '1.0.0-rc0',
      '1.0.0-rc50',
      '1.0.0-rc.1',
      '1.0.0-RC1',
      '1.100.0',
      '1.0.100',
      '2100.0.0',
      '2147.0.0',
      ' 1.0.0',
      '1.0.0 ',
      '-1.0.0',
    ];

    for (final version in invalidVersions) {
      test('rejects ${version.isEmpty ? 'an empty version' : version}', () {
        expect(
          () => ReleaseVersion.parse(version),
          throwsA(isA<ReleaseVersionFormatException>()),
        );
      });
    }

    test('wraps an arbitrarily long component as a format failure', () {
      final major = List.filled(10000, '9').join();

      expect(
        () => ReleaseVersion.parse('$major.0.0'),
        throwsA(isA<ReleaseVersionFormatException>()),
      );
    });

    test('orders beta, RC, final, then the next patch', () {
      final codes = [
        '1.1.0-beta1',
        '1.1.0-beta49',
        '1.1.0-rc1',
        '1.1.0-rc49',
        '1.1.0',
        '1.1.1-beta1',
      ].map((version) => ReleaseVersion.parse(version).androidVersionCode);

      expect(codes, orderedEquals(codes.toList()..sort()));
    });

    test('maps prereleases below the final Debian version', () {
      final beta = ReleaseVersion.parse('0.2.0-beta1');
      final candidate = ReleaseVersion.parse('0.2.0-rc2');
      final stable = ReleaseVersion.parse('0.2.0');

      expect(beta.debianPackageVersion, '0.2.0~beta1-1');
      expect(candidate.debianPackageVersion, '0.2.0~rc2-1');
      expect(stable.debianPackageVersion, '0.2.0-1');
    });

    test(
      'dpkg orders beta and RC before the final',
      () {
        final beta = ReleaseVersion.parse('0.2.0-beta1');
        final candidate = ReleaseVersion.parse('0.2.0-rc2');
        final stable = ReleaseVersion.parse('0.2.0');

        expect(_dpkgLessThan(beta, candidate), isTrue);
        expect(_dpkgLessThan(candidate, stable), isTrue);
      },
      skip: !File(_dpkgPath).existsSync() ? 'dpkg is unavailable' : false,
    );
  });
}

const String _dpkgPath = '/usr/bin/dpkg';

bool _dpkgLessThan(ReleaseVersion left, ReleaseVersion right) {
  final result = Process.runSync(_dpkgPath, [
    '--compare-versions',
    left.debianPackageVersion,
    'lt',
    right.debianPackageVersion,
  ]);

  return result.exitCode == 0;
}
