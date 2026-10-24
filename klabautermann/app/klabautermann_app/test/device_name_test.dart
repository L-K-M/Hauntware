// The device name (M5 plan Q6): the platform by default, never the
// device's hostname; a name the user gives, applied before it is saved,
// and a blank one meaning the default again.
import 'dart:io' show FileSystemException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/device_name.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/settings_page.dart';

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

  test('review fix: the same name again retries a save that failed', () async {
    var fail = true;
    final saved = <String?>[];
    final name = DeviceNameController(
      fallback: 'Klabautermann on Linux',
      apply: (_) {},
      save: (value) async {
        if (fail) throw const FileSystemException('disk full');
        saved.add(value);
      },
    );
    addTearDown(name.dispose);

    await expectLater(
      name.setDeviceName('Laptop'),
      throwsA(isA<DeviceNameNotSavedException>()),
    );
    fail = false;
    await name.setDeviceName('Laptop');
    await name.setDeviceName('Laptop');

    expect(saved, ['Laptop']);
  });

  testWidgets('review fix: the field sets a name once per submit, and not '
      'when left unchanged', (tester) async {
    final settings = _CountingName('Desk');
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Column(
            children: [
              DeviceNameField(deviceName: settings),
              const TextField(key: Key('other')),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byType(DeviceNameField));
    await tester.pump();
    await tester.tap(find.byKey(const Key('other')));
    await tester.pumpAndSettle();
    expect(settings.calls, isEmpty);

    await tester.enterText(find.byType(DeviceNameField), 'Laptop');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(settings.calls, ['Laptop']);
  });

  testWidgets('review fix: submitting the same name again retries a save '
      'that failed', (tester) async {
    final settings = _CountingName('Desk')..failSave = true;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: DeviceNameField(deviceName: settings)),
      ),
    );

    await tester.enterText(find.byType(DeviceNameField), 'Laptop');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    settings.failSave = false;
    await tester.showKeyboard(find.byType(DeviceNameField));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(settings.calls, ['Laptop', 'Laptop']);
    expect(settings.saved, isTrue);
  });
}

/// A device name that records each set, as the window's link would send
/// it, and takes it once it arrives.
final class _CountingName extends ChangeNotifier implements DeviceNameSettings {
  _CountingName(this._value);

  String _value;
  final calls = <String>[];
  var failSave = false;

  @override
  bool saved = true;

  @override
  String get value => _value;

  @override
  Future<void> setDeviceName(String name) async {
    calls.add(name);
    await Future<void>.delayed(Duration.zero);
    _value = name.trim();
    saved = !failSave;
    notifyListeners();
    if (failSave) throw const DeviceNameNotSavedException('disk full');
  }
}
