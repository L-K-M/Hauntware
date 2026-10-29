import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_desktop/ghost_desktop.dart';
import 'package:klabautermann_app/services/window_state.dart';

import 'support/fake_window.dart';

/// The main window's state (03 §10.2): `window_state.json` beside
/// `settings.json`, and Klabautermann's choices on ghost_desktop's shared
/// lifecycle, driven through scripted window and display adapters.
void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('klab-window-state-');
    file = File('${directory.path}${Platform.pathSeparator}window_state.json');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  const display = GhostDisplay(workArea: Rect.fromLTWH(0, 0, 1920, 1080));

  Future<void> store(Map<String, Object?> json) =>
      file.writeAsString(jsonEncode(json));

  Future<void> settle() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('window_state.json', () {
    test('lives beside settings.json under its own name', () {
      expect(windowStateFileName, 'window_state.json');
    });

    test('reads nothing saved from a missing file', () async {
      expect(await WindowStateStore(file).load(), isNull);
    });

    test('round-trips a snapshot in the shape Séance established', () async {
      const snapshot = GhostWindowSnapshot(
        bounds: Rect.fromLTWH(10, 20, 1200, 800),
        isMaximized: true,
      );
      await WindowStateStore(file).save(snapshot);

      expect(jsonDecode(await file.readAsString()), {
        'x': 10,
        'y': 20,
        'width': 1200,
        'height': 800,
        'isMaximized': true,
        'isFullScreen': false,
      });
      expect(await WindowStateStore(file).load(), snapshot);
    });

    test('reads a file that is not a snapshot as nothing saved', () async {
      for (final text in ['not json', '[]', '"x"', '']) {
        await file.writeAsString(text);
        expect(await WindowStateStore(file).load(), isNull, reason: text);
      }
    });

    test('drops an unusable frame but keeps the flags', () async {
      await store({
        'x': 0,
        'y': 0,
        'width': -5,
        'height': 10,
        'isFullScreen': true,
      });

      expect(
        await WindowStateStore(file).load(),
        const GhostWindowSnapshot(isFullScreen: true),
      );
    });

    test('lands overlapping saves whole, the last one last', () async {
      final windowState = WindowStateStore(file);
      const first = GhostWindowSnapshot(bounds: Rect.fromLTWH(0, 0, 400, 300));
      const second = GhostWindowSnapshot(
        bounds: Rect.fromLTWH(50, 60, 900, 700),
      );
      await Future.wait([windowState.save(first), windowState.save(second)]);

      expect(await WindowStateStore(file).load(), second);
      expect(
        directory.listSync().map((entity) => entity.uri.pathSegments.last),
        ['window_state.json'],
        reason: 'no temp file is left behind',
      );
    });
  });

  group('saving', () {
    const first = GhostWindowSnapshot(bounds: Rect.fromLTWH(0, 0, 400, 300));
    const second = GhostWindowSnapshot(bounds: Rect.fromLTWH(50, 60, 900, 700));

    test('writes one save at a time, in the order asked', () async {
      final events = <String>[];
      final firstWrite = Completer<void>();
      var writes = 0;
      final windowState = WindowStateStore(
        file,
        writer: (target, bytes) async {
          final name = ++writes == 1 ? 'first' : 'second';
          events.add('$name started');
          if (name == 'first') await firstWrite.future;
          events.add('$name done');
        },
      );

      final saves = Future.wait([
        windowState.save(first),
        windowState.save(second),
      ]);
      await settle();
      expect(events, ['first started'], reason: 'the second save waits');

      firstWrite.complete();
      await saves;
      expect(events, [
        'first started',
        'first done',
        'second started',
        'second done',
      ]);
    });

    test('a failed save reports its error and does not hold up the next '
        'one', () async {
      final written = <String>[];
      var writes = 0;
      final windowState = WindowStateStore(
        file,
        writer: (target, bytes) async {
          if (++writes == 1) throw const FileSystemException('disk full');
          written.add(utf8.decode(bytes));
        },
      );

      final failed = windowState.save(first);
      final next = windowState.save(second);

      await expectLater(failed, throwsA(isA<FileSystemException>()));
      await next;
      expect(written.map(jsonDecode), [second.toJson()]);
    });
  });

  test('only desktops have a window to remember', () {
    expect(
      ghostDesktopPlatformFor(TargetPlatform.linux),
      GhostDesktopPlatform.linux,
    );
    expect(
      ghostDesktopPlatformFor(TargetPlatform.macOS),
      GhostDesktopPlatform.macos,
    );
    expect(
      ghostDesktopPlatformFor(TargetPlatform.windows),
      GhostDesktopPlatform.windows,
    );
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.fuchsia,
    ]) {
      expect(ghostDesktopPlatformFor(platform), isNull, reason: '$platform');
    }
  });

  group('restoring at launch', () {
    test('puts an on-screen frame back and leaves showing to the runner '
        'on Linux', () async {
      await store({'x': 200, 'y': 150, 'width': 1000, 'height': 700});
      final window = FakeWindow();

      final lifecycle = await restoreMainWindow(
        stateFile: file,
        platform: TargetPlatform.linux,
        window: window,
        displays: FakeDisplays(display),
      );

      expect(lifecycle, isNotNull);
      expect(window.boundsSet, [const Rect.fromLTWH(200, 150, 1000, 700)]);
      // The Linux and Windows runners show the window on the first frame.
      expect(window.calls, isNot(contains('show')));
      expect(window.listening, isTrue);
      // The close is intercepted (K4): the native window holds the close
      // for the quit guard, which answers through confirmClose.
      expect(window.calls, contains('setPreventClose(true)'));
    });

    test('asks confirmClose before closing; a veto leaves the window up, '
        'writes no state, and an OK destroys it', () async {
      var answer = false;
      final window = FakeWindow();
      final lifecycle = await restoreMainWindow(
        stateFile: file,
        platform: TargetPlatform.linux,
        window: window,
        displays: FakeDisplays(display),
        confirmClose: () async => answer,
      );

      // The veto saves nothing and the window survives, listener on.
      expect(await lifecycle!.close(), isFalse);
      expect(await file.exists(), isFalse);
      expect(window.calls, isNot(contains('destroy')));
      expect(window.listening, isTrue);

      // The next close re-runs the whole path, guard included.
      answer = true;
      expect(await lifecycle.close(), isTrue);
      expect(window.calls, contains('destroy'));
      expect(await file.exists(), isTrue);
    });

    test('clamps a frame from a monitor that is gone onto the primary '
        'display', () async {
      await store({'x': 2200, 'y': 100, 'width': 1200, 'height': 800});
      final window = FakeWindow();

      await restoreMainWindow(
        stateFile: file,
        platform: TargetPlatform.linux,
        window: window,
        displays: FakeDisplays(display),
      );

      // Centred on the only display, at its own size.
      expect(window.boundsSet, [const Rect.fromLTWH(360, 140, 1200, 800)]);
    });

    test('pulls a frame partly off screen fully onto its display', () async {
      await store({'x': 1500, 'y': 600, 'width': 800, 'height': 600});
      final window = FakeWindow();

      await restoreMainWindow(
        stateFile: file,
        platform: TargetPlatform.linux,
        window: window,
        displays: FakeDisplays(display),
      );

      expect(window.boundsSet, [const Rect.fromLTWH(1120, 480, 800, 600)]);
    });

    test('shrinks a frame larger than the display that remains', () async {
      await store({'x': -100, 'y': 0, 'width': 3000, 'height': 2000});
      final window = FakeWindow();

      await restoreMainWindow(
        stateFile: file,
        platform: TargetPlatform.windows,
        window: window,
        displays: FakeDisplays(display),
      );

      expect(window.boundsSet.last, const Rect.fromLTWH(0, 0, 1920, 1080));
    });

    test('keeps a frame spanning two displays where it was', () async {
      await store({'x': 1500, 'y': 100, 'width': 1000, 'height': 700});
      final window = FakeWindow();

      await restoreMainWindow(
        stateFile: file,
        platform: TargetPlatform.linux,
        window: window,
        displays: FakeDisplays(display, const [
          GhostDisplay(workArea: Rect.fromLTWH(1920, 0, 1920, 1080)),
        ]),
      );

      expect(window.boundsSet, [const Rect.fromLTWH(1500, 100, 1000, 700)]);
    });

    test('stores physical pixels on Windows and places the window in '
        'logical ones', () async {
      // A 2x display: its logical work area is 1920 by 1080, so 3840 by
      // 2160 physical pixels.
      await store({'x': 400, 'y': 200, 'width': 2000, 'height': 1200});
      final window = FakeWindow()..devicePixelRatio = 2;

      await restoreMainWindow(
        stateFile: file,
        platform: TargetPlatform.windows,
        window: window,
        displays: FakeDisplays(
          const GhostDisplay(
            workArea: Rect.fromLTWH(0, 0, 1920, 1080),
            scaleFactor: 2,
          ),
        ),
      );

      expect(window.boundsSet.last, const Rect.fromLTWH(200, 100, 1000, 600));
    });

    test(
      'on macOS places the hidden window, maximizes it, then shows it',
      () async {
        await store({
          'x': 200,
          'y': 150,
          'width': 1000,
          'height': 700,
          'isMaximized': true,
        });
        final window = FakeWindow();

        await restoreMainWindow(
          stateFile: file,
          platform: TargetPlatform.macOS,
          window: window,
          displays: FakeDisplays(display),
        );

        expect(
          window.calls.where(
            (call) =>
                const {'setBounds', 'maximize', 'show', 'focus'}.contains(call),
          ),
          ['setBounds', 'maximize', 'show', 'focus'],
        );
      },
    );

    test('on macOS shows the window even when restoring fails', () async {
      final window = FakeWindow()..failEnsureInitialized = true;

      await restoreMainWindow(
        stateFile: file,
        platform: TargetPlatform.macOS,
        window: window,
        displays: FakeDisplays(display),
      );

      expect(window.calls, containsAllInOrder(['show', 'focus']));
      expect(window.boundsSet, isEmpty);
    });

    test('opens at the runner\'s placement when nothing was saved', () async {
      final window = FakeWindow();

      await restoreMainWindow(
        stateFile: file,
        platform: TargetPlatform.linux,
        window: window,
        displays: FakeDisplays(display),
      );

      expect(window.boundsSet, isEmpty);
      expect(window.listening, isTrue);
    });

    test('leaves phones alone', () async {
      final window = FakeWindow();
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        final lifecycle = await restoreMainWindow(
          stateFile: file,
          platform: platform,
          window: window,
          displays: FakeDisplays(display),
        );
        expect(lifecycle, isNull, reason: '$platform');
      }
      expect(window.calls, isEmpty);
      expect(file.existsSync(), isFalse);
    });
  });

  group('tracking while the app runs', () {
    late FakeWindow window;
    late MemoryWindowState persistence;
    late ManualDebounce debounce;
    late GhostWindowLifecycle lifecycle;

    setUp(() async {
      window = FakeWindow();
      persistence = MemoryWindowState();
      debounce = ManualDebounce();
      lifecycle = mainWindowLifecycle(
        persistence: persistence,
        window: window,
        displays: FakeDisplays(display),
        platform: GhostDesktopPlatform.linux,
        scheduleDebounce: debounce.call,
      );
      await lifecycle.prepare();
      await lifecycle.show();
    });

    tearDown(() => lifecycle.dispose());

    test('saves the normal frame once a move settles', () async {
      window.bounds = const Rect.fromLTWH(300, 200, 1100, 750);
      window.emitMove();
      window.emitMove();
      expect(persistence.saves, isEmpty, reason: 'debounced');

      await debounce.flush();

      expect(persistence.saves, [
        const GhostWindowSnapshot(bounds: Rect.fromLTWH(300, 200, 1100, 750)),
      ]);
    });

    test('keeps the normal frame while maximized', () async {
      const normal = Rect.fromLTWH(300, 200, 1100, 750);
      window.bounds = normal;
      window.emitMove();
      await debounce.flush();

      window
        ..maximized = true
        ..bounds = const Rect.fromLTWH(0, 0, 1920, 1080);
      window.emitMaximize();
      await debounce.flush();

      expect(
        persistence.saves.last,
        const GhostWindowSnapshot(bounds: normal, isMaximized: true),
      );
    });

    test('saves on close, then lets the window go', () async {
      window.bounds = const Rect.fromLTWH(40, 30, 1000, 700);
      window.emitClose();
      await settle();

      expect(
        persistence.saves.single,
        const GhostWindowSnapshot(bounds: Rect.fromLTWH(40, 30, 1000, 700)),
      );
      // With no confirmClose wired, the intercepted close proceeds: the
      // save lands, then the window destroys itself.
      expect(window.calls, contains('destroy'));
    });
  });
}
