import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/services/app_settings.dart';
import 'package:planchette_editor/planchette_editor.dart';

import 'memory_settings.dart';

void main() {
  group('AppSettings', () {
    test('defaults are the ones a new install wants', () {
      const settings = AppSettings();
      expect(settings.themeMode, ThemeMode.system);
      expect(settings.fontSize, AppSettings.defaultFontSize);
      expect(settings.indent.usesTabs, isFalse);
      expect(settings.indent.size, 2);
      expect(settings.fontFamily, isNull);
    });

    test('round-trips through JSON', () {
      const settings = AppSettings(
        themeMode: ThemeMode.dark,
        fontSize: 18,
        indent: EditorIndent(usesTabs: true, size: 4),
        fontFamily: 'Fira Code',
      );
      expect(AppSettings.fromJson(settings.toJson()), settings);
    });

    test('an empty or absent document yields the defaults', () {
      expect(AppSettings.fromJson(null), const AppSettings());
      expect(AppSettings.fromJson(const {}), const AppSettings());
    });

    test('an unreadable value falls back instead of failing', () {
      // A hand-edited or half-written file must not stop the app from starting.
      expect(
        AppSettings.fromJson(const {'fontSize': 'large'}),
        const AppSettings(),
      );
      expect(
        AppSettings.fromJson(const {'themeMode': 'chartreuse'}),
        const AppSettings(),
      );
      expect(AppSettings.fromJson(const {'indent': 7}), const AppSettings());
    });

    test('an out-of-range font size falls back', () {
      expect(
        AppSettings.fromJson(const {'fontSize': 0}).fontSize,
        AppSettings.defaultFontSize,
      );
      expect(
        AppSettings.fromJson(const {'fontSize': 400}).fontSize,
        AppSettings.defaultFontSize,
      );
    });

    test('a known value that is merely unusual is kept', () {
      expect(AppSettings.fromJson(const {'fontSize': 9}).fontSize, 9);
      expect(AppSettings.fromJson(const {'fontSize': 40}).fontSize, 40);
    });

    test('an unknown key is ignored rather than fatal', () {
      final settings = AppSettings.fromJson(const {
        'fontSize': 15,
        'somethingNewer': 'value',
      });
      expect(settings.fontSize, 15);
    });

    test('equality is by value so an unchanged save can be skipped', () {
      expect(const AppSettings(), const AppSettings());
      expect(const AppSettings(), isNot(const AppSettings(fontSize: 13)));
    });

    test('the JSON is readable', () {
      final json = const AppSettings(fontSize: 15).toJson();
      expect(json.keys, containsAll(['themeMode', 'fontSize', 'indent']));
      expect(
        const JsonEncoder.withIndent('  ').convert(json),
        startsWith('{\n'),
      );
    });
  });

  group('SettingsStore', () {
    test('a missing file is not an error', () async {
      final store = MemorySettings();
      expect(await store.load(), isNull);
    });

    test('a stored document comes back', () async {
      final store = MemorySettings()
        ..stored = jsonEncode(const AppSettings(fontSize: 17).toJson());
      expect((await store.load())?.fontSize, 17);
    });

    test(
      'a corrupt document is reported as absent, not as a failure',
      () async {
        final store = MemorySettings()..stored = 'not json at all';
        expect(await store.load(), isNull);
      },
    );

    test('a write is readable by the next load', () async {
      final store = MemorySettings();
      await store.save(
        const AppSettings(fontSize: 21, themeMode: ThemeMode.light),
      );
      expect((await store.load())?.fontSize, 21);
      expect((await store.load())?.themeMode, ThemeMode.light);
    });
  });

  group('SettingsController', () {
    test('starts from what was stored', () async {
      final store = MemorySettings()
        ..stored = jsonEncode(
          const AppSettings(fontSize: 19, themeMode: ThemeMode.dark).toJson(),
        );
      final settings = SettingsController(store: store);
      addTearDown(settings.dispose);
      await settings.load();
      expect(settings.value.fontSize, 19);
      expect(settings.value.themeMode, ThemeMode.dark);
    });

    test('an unreadable store leaves the defaults in place', () async {
      final settings = SettingsController(
        store: MemorySettings()..stored = 'x',
      );
      addTearDown(settings.dispose);
      await settings.load();
      expect(settings.value, const AppSettings());
    });

    test('a store that throws still lets the app start', () async {
      // `load` runs in `main()` before `runApp`. A settings file that cannot be
      // read — a permission change, a dead network mount, a directory in the
      // way — must not be the reason the application refuses to open.
      final settings = SettingsController(
        store: ThrowingSettings(const FileSystemException('denied', '/x')),
      );
      addTearDown(settings.dispose);
      await settings.load();
      expect(settings.value, const AppSettings());
    });

    test('a rejected save is not left pending for the next one', () async {
      // A failed write must not break the chain, or every later save is
      // silently skipped.
      final store = MemorySettings();
      final settings = SettingsController(store: store);
      addTearDown(settings.dispose);
      await settings.load();
      store.failSaves = true;
      await settings.update(settings.value.copyWith(fontSize: 25));
      expect(settings.error, isNotNull);

      store.failSaves = false;
      await settings.update(settings.value.copyWith(fontSize: 26));
      expect(settings.error, isNull);
      expect((await store.load())?.fontSize, 26);
    });

    test('rapid updates persist the last one, not an earlier one', () async {
      // Two updates in a row, where the first write is slow. Without
      // serialization the slow one lands last and the file holds a value the
      // user has already moved on from.
      final store = SlowSettings();
      final settings = SettingsController(store: store);
      addTearDown(settings.dispose);
      await settings.load();

      settings.update(settings.value.copyWith(fontSize: 31));
      settings.update(settings.value.copyWith(fontSize: 32));
      // The writes are chained, so they start on later turns of the event
      // loop. Let the queue turn before asking for one to finish.
      await pumpEventQueue();

      // Let the first write finish. With the writes serialized the second is
      // still waiting behind it, so the file cannot end up holding 31.
      store.finishOldest();
      await pumpEventQueue();
      expect(store.completed.map((s) => s.fontSize), [31]);

      store.finishAll();
      await settings.flush();

      expect(store.written.map((s) => s.fontSize), [31, 32]);
      expect(store.completed.map((s) => s.fontSize), [31, 32]);
      expect((await store.load())?.fontSize, 32);
    });

    test('a change is saved and announced once', () async {
      final store = MemorySettings();
      final settings = SettingsController(store: store);
      addTearDown(settings.dispose);
      await settings.load();
      var notifications = 0;
      settings.addListener(() => notifications++);

      settings.update(settings.value.copyWith(fontSize: 22));
      await settings.flush();

      expect(settings.value.fontSize, 22);
      expect((await store.load())?.fontSize, 22);
      expect(notifications, 1);
    });

    test('setting the same value again neither notifies nor writes', () async {
      final store = MemorySettings();
      final settings = SettingsController(store: store);
      addTearDown(settings.dispose);
      await settings.load();
      var notifications = 0;
      settings.addListener(() => notifications++);

      await settings.update(settings.value);

      expect(notifications, 0);
      expect(store.writes, 0);
    });

    test('a failing save is reported without losing the setting', () async {
      final settings = SettingsController(
        store: MemorySettings()..failSaves = true,
      );
      // ignore: unnecessary_underscores
      addTearDown(settings.dispose);
      await settings.load();

      await settings.update(settings.value.copyWith(fontSize: 23));
      // The write failed, and the setting the user chose still stands.
      expect(settings.value.fontSize, 23);
      expect(settings.error, contains('disk full'));
    });

    test('a rejected save does not leave an unhandled error behind', () async {
      // The dialog that calls this awaits nothing, so a throw here would be
      // reported as an unhandled asynchronous error rather than as a message.
      final settings = SettingsController(
        store: MemorySettings()..failSaves = true,
      );
      addTearDown(settings.dispose);
      await settings.load();
      unawaited(settings.update(settings.value.copyWith(fontSize: 25)));
      await settings.flush();
      expect(settings.error, isNotNull);
    });

    test('a later successful save clears the error', () async {
      final store = MemorySettings()..failSaves = true;
      final settings = SettingsController(store: store);
      addTearDown(settings.dispose);
      await settings.load();
      await settings.update(settings.value.copyWith(fontSize: 23));
      expect(settings.error, isNotNull);

      store.failSaves = false;
      await settings.update(settings.value.copyWith(fontSize: 24));
      expect(settings.error, isNull);
    });
  });

  group('LocalSettingsStore', () {
    test('writes and reads a file it was given a path for', () async {
      final directory = await Directory.systemTemp.createTemp(
        'planchette-settings-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = LocalSettingsStore(File('${directory.path}/settings.json'));

      expect(await store.load(), isNull);
      await store.save(const AppSettings(fontSize: 16));
      expect(File('${directory.path}/settings.json').existsSync(), isTrue);
      expect((await store.load())?.fontSize, 16);
    });

    test('an unwritable destination reports rather than throws', () async {
      final store = LocalSettingsStore(
        File('/definitely/not/a/directory/settings.json'),
      );
      await expectLater(
        store.save(const AppSettings()),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('a directory in the way is reported, not silently ignored', () async {
      final directory = await Directory.systemTemp.createTemp(
        'planchette-settings-dir-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = LocalSettingsStore(File('${directory.path}/settings.json'));
      await Directory('${directory.path}/settings.json').create();
      expect(await store.load(), isNull);
      await expectLater(
        store.save(const AppSettings()),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
