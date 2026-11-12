import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_desktop/ghost_desktop.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/app_preferences.dart';
import 'package:poltergeist_app/services/desktop_window_lifecycle.dart';
import 'package:poltergeist_app/services/settings_store.dart';

import 'support/controlled_settings_writer.dart';
import 'support/fake_window_adapters.dart';

late Directory _temporaryDirectory;
late File _settingsFile;

void main() {
  setUp(() async {
    _temporaryDirectory = await Directory.systemTemp.createTemp(
      'poltergeist_window_lifecycle_test_',
    );
    _settingsFile = File(p.join(_temporaryDirectory.path, 'settings.json'));
  });

  tearDown(() async {
    if (await _temporaryDirectory.exists()) {
      await _temporaryDirectory.delete(recursive: true);
    }
  });

  // The shared lifecycle's own behaviour (prepare/show/close sequencing,
  // calibration queueing, debounce, guarded close) is tested in
  // ghost_desktop. These cases pin what this subclass wires: the window
  // defaults and minimum content size, the macOS titlebar hook, the
  // logical-pixel `window.*` persistence and the close-guard callbacks.
  test('prepare configures the window and macOS titlebar', () async {
    final window = FakeWindowAdapter();
    final displays = FakeDisplayAdapter();
    final titlebar = FakeMacTitlebarAdapter();
    final lifecycle = _lifecycle(
      window: window,
      displays: displays,
      titlebar: titlebar,
      platform: GhostDesktopPlatform.macos,
    );

    await lifecycle.prepare();

    expect(window.ensureInitializedCalls, 1);
    expect(window.preventClose, isTrue);
    expect(window.callbacksRegistered, isTrue);
    expect(titlebar.initializeCalls, 1);
  });

  test('show restores clamped geometry before showing and focusing', () async {
    final window = FakeWindowAdapter();
    await _settingsFile.writeAsString(
      '{"window.left":3000.0,"window.top":2000.0,'
      '"window.width":900.0,"window.height":600.0}',
    );
    final lifecycle = _lifecycle(window: window);

    await lifecycle.prepare();
    await lifecycle.show();

    expect(window.readyOptions?.size, const Size(900, 600));
    expect(window.readyOptions?.placement, GhostWindowPlacement.restored);
    expect(window.bounds, const Rect.fromLTWH(510, 220, 900, 600));
    expect(window.events, ['ready', 'bounds', 'show', 'focus']);
  });

  test('calibrates outer minimum size from first-frame content size', () async {
    final window = FakeWindowAdapter()
      ..bounds = const Rect.fromLTWH(10, 20, 700, 460);
    final lifecycle = _lifecycle(window: window);

    await lifecycle.prepare();
    await lifecycle.calibrateMinimumSize(const Size(680, 420));

    expect(window.minimumSize, const Size(740, 520));
    expect(window.bounds, const Rect.fromLTWH(10, 20, 740, 520));
  });

  test('recalibrates when the settled content inset changes', () async {
    final window = FakeWindowAdapter();
    final lifecycle = _lifecycle(window: window);

    await lifecycle.prepare();
    await lifecycle.calibrateMinimumSize(const Size(1180, 760));
    await lifecycle.calibrateMinimumSize(const Size(1180, 730));

    expect(window.minimumSizes, [const Size(720, 480), const Size(720, 510)]);
  });

  test('move and resize save through the debounced path', () async {
    const saveDelay = Duration(milliseconds: 37);
    final window = FakeWindowAdapter();
    final debounce = FakeDebounceScheduler();
    final lifecycle = _lifecycle(
      window: window,
      debounce: debounce,
      saveDelay: saveDelay,
    );

    await lifecycle.prepare();
    window.emitMove();
    window.emitResize();

    expect(debounce.cancelCount, 1);
    expect(debounce.lastDelay, saveDelay);
    expect(await _settingsFile.exists(), isFalse);

    await debounce.fire();

    expect(await jsonValue(_settingsFile, 'window.left'), 80.0);
    expect(await jsonValue(_settingsFile, 'window.top'), 60.0);
    expect(await jsonValue(_settingsFile, 'window.width'), 1180.0);
    expect(await jsonValue(_settingsFile, 'window.height'), 760.0);
  });

  test(
    'close cancels the timer, awaits the final save, then destroys',
    () async {
      final window = FakeWindowAdapter();
      final writer = ControlledSettingsWriter()..blockWrites = true;
      final debounce = FakeDebounceScheduler();
      final lifecycle = _lifecycle(
        window: window,
        writer: writer,
        debounce: debounce,
      );

      await lifecycle.prepare();
      window.emitMove();
      final closing = lifecycle.close();
      await writer.firstWriteStarted.future;
      expect(debounce.cancelCount, 1);
      expect(window.events, isNot(contains('destroy')));

      writer.releaseWrites();
      await closing;
      expect(window.events.last, 'destroy');
      expect(window.callbacksRegistered, isFalse);
    },
  );

  test('save failures are reported and do not escape callbacks', () async {
    final window = FakeWindowAdapter();
    final writer = ControlledSettingsWriter()..failWrites = true;
    final errors = <Object>[];
    final debounce = FakeDebounceScheduler();
    final lifecycle = _lifecycle(
      window: window,
      writer: writer,
      debounce: debounce,
      onError: (error, _) => errors.add(error),
    );

    await lifecycle.prepare();
    window.emitMove();
    await debounce.fire();

    expect(errors, hasLength(1));

    writer.failWrites = false;
    await lifecycle.close();

    expect(window.events.last, 'destroy');
  });

  test('final geometry save failure is reported once before destroy', () async {
    final window = FakeWindowAdapter();
    final writer = ControlledSettingsWriter()..failWrites = true;
    final errors = <Object>[];
    final lifecycle = _lifecycle(
      window: window,
      writer: writer,
      onError: (error, _) => errors.add(error),
    );

    await lifecycle.prepare();
    await lifecycle.close();

    expect(errors, [isA<StateError>()]);
    expect(window.events.last, 'destroy');
  });

  test('a vetoed close keeps the window up and re-runs on retry', () async {
    final window = FakeWindowAdapter();
    var allowClose = false;
    var guardCalls = 0;
    final lifecycle = _lifecycle(
      window: window,
      confirmClose: () async {
        guardCalls++;
        return allowClose;
      },
    );

    await lifecycle.prepare();
    final vetoed = await lifecycle.close();

    expect(vetoed, isFalse);
    expect(window.events, isNot(contains('destroy')));
    expect(window.callbacksRegistered, isTrue);
    // A veto leaves the lifecycle live: show must not be gated by a
    // stale closing flag.
    await lifecycle.show();
    expect(window.events, containsAllInOrder(['ready', 'show', 'focus']));

    allowClose = true;
    final closed = await lifecycle.close();

    expect(closed, isTrue);
    expect(guardCalls, 2);
    expect(window.events.last, 'destroy');
  });

  test(
    'another window taking the close skips the whole quit path (00 D39)',
    () async {
      final window = FakeWindowAdapter();
      var guardCalls = 0;
      var instead = true;
      final lifecycle = _lifecycle(
        window: window,
        confirmClose: () async {
          guardCalls++;
          return true;
        },
        closeInstead: () async => instead,
      );

      await lifecycle.prepare();
      expect(await lifecycle.close(), isFalse);

      expect(guardCalls, 0);
      expect(window.events, isNot(contains('destroy')));
      expect(window.callbacksRegistered, isTrue);

      // The last window's close is a quit again, guard first.
      instead = false;
      expect(await lifecycle.close(), isTrue);
      expect(guardCalls, 1);
      expect(window.events.last, 'destroy');
    },
  );

  test('saveBounds writes the current bounds for a quit that skips the '
      'close path', () async {
    final window = FakeWindowAdapter();
    final lifecycle = _lifecycle(window: window);

    await lifecycle.saveBounds();
    expect(await jsonValue(_settingsFile, 'window.width'), isNull);

    await lifecycle.prepare();
    await lifecycle.saveBounds();

    expect(await jsonValue(_settingsFile, 'window.width'), 1180);
  });
}

DesktopWindowLifecycle _lifecycle({
  required FakeWindowAdapter window,
  ControlledSettingsWriter? writer,
  FakeDisplayAdapter? displays,
  FakeMacTitlebarAdapter? titlebar,
  GhostDesktopPlatform platform = GhostDesktopPlatform.linux,
  Duration saveDelay = const Duration(milliseconds: 1),
  FakeDebounceScheduler? debounce,
  Future<bool> Function()? confirmClose,
  Future<bool> Function()? closeInstead,
  void Function(Object, StackTrace)? onError,
}) {
  final store = SettingsStore(
    path: _settingsFile.path,
    atomicWriter: writer?.call,
    onError: onError,
  );
  return DesktopWindowLifecycle(
    AppPreferences(store: store),
    window: window,
    displays: displays ?? FakeDisplayAdapter(),
    titlebar: titlebar ?? FakeMacTitlebarAdapter(),
    platform: platform,
    geometrySaveDelay: saveDelay,
    scheduleDebounce: debounce?.schedule,
    confirmClose: confirmClose,
    closeInstead: closeInstead,
    onError: onError,
  );
}

Future<double?> jsonValue(File file, String key) async {
  if (!await file.exists()) return null;

  final contents = await file.readAsString();
  final value = (jsonDecode(contents) as Map<String, dynamic>)[key];
  return (value as num?)?.toDouble();
}
