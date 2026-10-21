// The device name's default (M5 plan Q6): the platform, never the
// device's hostname.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/device_name.dart';

void main() {
  test('names the platform', () {
    expect(defaultDeviceName(TargetPlatform.macOS), 'Klabautermann on macOS');
    expect({
      for (final platform in TargetPlatform.values) defaultDeviceName(platform),
    }, hasLength(TargetPlatform.values.length));
  });
}
