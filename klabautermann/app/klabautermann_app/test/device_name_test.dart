// The device name (M5 plan Q6): the platform by default, never the
// device's hostname; a name the user gives, applied before it is saved,
// and a blank one meaning the default again.
import 'dart:io' show FileSystemException;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/device_name.dart';

void main() {
  test('the default names the platform', () {
    const labels = {
      TargetPlatform.android: 'Android',
      TargetPlatform.fuchsia: 'Fuchsia',
      TargetPlatform.iOS: 'iOS',
      TargetPlatform.linux: 'Linux',
      TargetPlatform.macOS: 'macOS',
      TargetPlatform.windows: 'Windows',
    };
    expect(labels.keys, containsAll(TargetPlatform.values));
    for (final MapEntry(key: platform, value: label) in labels.entries) {
      expect(defaultDeviceName(platform), 'Klabautermann on $label');
    }
  });

  test('applies at once, then each change before saving it; blank is the '
      'default, stored as none', () async {
    final applied = <String>[];
    final saved = <String?>[];
    final name = DeviceNameController(
      stored: 'Desk',
      fallback: 'Klabautermann on Linux',
      apply: applied.add,
      save: (value) async => saved.add(value),
    );
    addTearDown(name.dispose);
    expect(applied, ['Desk']);

    await name.setDeviceName('  Laptop ');
    await name.setDeviceName('Laptop');
    await name.setDeviceName('   ');

    expect(applied, ['Desk', 'Laptop', 'Klabautermann on Linux']);
    expect(saved, ['Laptop', null]);
    expect(name.value, 'Klabautermann on Linux');
  });

  test('a change it cannot save still applies and says so', () async {
    final name = DeviceNameController(
      fallback: 'Klabautermann on Linux',
      apply: (_) {},
      save: (_) async => throw const FileSystemException('disk full'),
    );
    addTearDown(name.dispose);

    await expectLater(
      name.setDeviceName('Laptop'),
      throwsA(isA<DeviceNameNotSavedException>()),
    );
    expect(name.value, 'Laptop');
  });
}
