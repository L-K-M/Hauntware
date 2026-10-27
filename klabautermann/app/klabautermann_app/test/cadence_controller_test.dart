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

  test('picking the same preset after a failed save tries it again', () async {
    var fail = true;
    final saved = <String>[];
    final cadence = CadenceController(
      save: (name) async {
        if (fail) throw const FileSystemException('disk full');
        saved.add(name);
      },
    );
    addTearDown(cadence.dispose);
    var notified = 0;
    cadence.addListener(() => notified++);

    await expectLater(
      cadence.setCadence(CadencePreset.phone),
      throwsA(isA<CadenceNotSavedException>()),
    );
    fail = false;
    await cadence.setCadence(CadencePreset.phone);
    await cadence.setCadence(CadencePreset.phone);

    expect(saved, ['phone'], reason: 'retried once, then a no-op');
    expect(notified, 1, reason: 'the value changed once');
  });

  group('per-server caps', () {
    test('a stored name parses to its cap; anything else caps nothing', () {
      expect(CadenceCap.parse('phone'), CadenceCap.phone);
      expect(CadenceCap.parse('cellularSaver'), CadenceCap.cellularSaver);
      expect(CadenceCap.parse('desktop'), isNull);
      expect(CadenceCap.parse(null), isNull);
      expect(CadenceCap.cellularSaver.profile, CadenceProfile.cellularSaver);
    });

    test('a cap applies, notifies and is saved; one in force does '
        'nothing; null lifts it', () async {
      final saved = <(String, String?)>[];
      final caps = CadenceCapsController(
        caps: const {'srv-2': CadenceCap.phone},
        save: (serverId, name) async => saved.add((serverId, name)),
      );
      addTearDown(caps.dispose);
      var notified = 0;
      caps.addListener(() => notified++);

      await caps.setCap('srv-1', CadenceCap.cellularSaver);
      await caps.setCap('srv-1', CadenceCap.cellularSaver);
      await caps.setCap('srv-2', null);

      expect(caps.value, {'srv-1': CadenceCap.cellularSaver});
      expect(saved, [('srv-1', 'cellularSaver'), ('srv-2', null)]);
      expect(notified, 2);
    });

    test('a cap the store refused stays in force, says so, and is saved '
        'when picked again', () async {
      var fail = true;
      final saved = <String?>[];
      final caps = CadenceCapsController(
        save: (_, name) async {
          if (fail) throw const FileSystemException('disk full');
          saved.add(name);
        },
      );
      addTearDown(caps.dispose);

      await expectLater(
        caps.setCap('srv-1', CadenceCap.phone),
        throwsA(isA<CadenceNotSavedException>()),
      );
      expect(caps.value, {'srv-1': CadenceCap.phone});
      fail = false;
      await caps.setCap('srv-1', CadenceCap.phone);
      await caps.setCap('srv-1', CadenceCap.phone);
      expect(saved, ['phone'], reason: 'retried once, then a no-op');
    });
  });
}
