import 'dart:io' show FileSystemException;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/cadence_controller.dart';
import 'package:klabautermann_core/klabautermann_core.dart' show CadenceProfile;

/// SAF-19: the polling budget's presets and the controller that keeps
/// the chosen one.
void main() {
  test('a stored name parses to its preset; anything else is automatic', () {
    for (final preset in CadencePreset.values) {
      expect(CadencePreset.parse(preset.name), preset);
    }
    expect(CadencePreset.parse(null), CadencePreset.automatic);
    expect(CadencePreset.parse('satellite'), CadencePreset.automatic);
  });

  test('automatic picks the phone column on phones and tablets and the '
      'desktop column on computers (03 §6.4)', () {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.fuchsia,
    ]) {
      expect(CadencePreset.automatic.profileOn(platform), CadenceProfile.phone);
    }
    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    ]) {
      expect(
        CadencePreset.automatic.profileOn(platform),
        CadenceProfile.desktop,
      );
    }
  });

  test('the fixed presets pick their column on any device', () {
    for (final platform in TargetPlatform.values) {
      expect(CadencePreset.desktop.profileOn(platform), CadenceProfile.desktop);
      expect(CadencePreset.phone.profileOn(platform), CadenceProfile.phone);
      expect(
        CadencePreset.cellularSaver.profileOn(platform),
        CadenceProfile.cellularSaver,
      );
    }
  });

  test('a change notifies and is saved by name; the same preset is a '
      'no-op', () async {
    final saved = <String>[];
    final cadence = CadenceController(save: (name) async => saved.add(name));
    addTearDown(cadence.dispose);
    var notified = 0;
    cadence.addListener(() => notified++);

    await cadence.setCadence(CadencePreset.cellularSaver);
    await cadence.setCadence(CadencePreset.cellularSaver);

    expect(cadence.value, CadencePreset.cellularSaver);
    expect(notified, 1);
    expect(saved, ['cellularSaver']);
  });

  test('a change that cannot be saved still applies and says so', () async {
    final cadence = CadenceController(
      preset: CadencePreset.phone,
      save: (_) async => throw const FileSystemException('disk full'),
    );
    addTearDown(cadence.dispose);

    await expectLater(
      cadence.setCadence(CadencePreset.desktop),
      throwsA(
        isA<CadenceNotSavedException>().having(
          (error) => error.message,
          'message',
          contains('disk full'),
        ),
      ),
    );
    expect(cadence.value, CadencePreset.desktop);
  });
}
