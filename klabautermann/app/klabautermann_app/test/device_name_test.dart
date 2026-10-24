// The device name's default (M5 plan Q6): the platform, never the
// device's hostname.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/device_name.dart';

void main() {
  test('names the platform', () {
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
}
