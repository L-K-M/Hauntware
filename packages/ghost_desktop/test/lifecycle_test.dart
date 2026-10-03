import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_desktop/ghost_desktop.dart';

import 'fakes.dart';

void main() {
  group('prepare', () {
    test('configures the window and runs the macOS prepare hook', () async {
      final window = FakeWindowAdapter();
      final displays = FakeDisplayAdapter();
      var macosPrepareCalls = 0;
      final lifecycle = _lifecycle(
        window: window,
        displays: displays,
        platform: GhostDesktopPlatform.macos,
        onMacosPrepare: () async => macosPrepareCalls++,
      );

      await lifecycle.prepare();

      expect(window.ensureInitializedCalls, 1);
      expect(window.preventClose, isTrue);
      expect(window.listenerRegistered, isTrue);
      expect(macosPrepareCalls, 1);
    });

    test('does not run the macOS prepare hook off macOS', () async {
      final window = FakeWindowAdapter();
      var macosPrepareCalls = 0;
      final lifecycle = _lifecycle(
        window: window,
        platform: GhostDesktopPlatform.linux,
        onMacosPrepare: () async => macosPrepareCalls++,
      );

      await lifecycle.prepare();

      expect(macosPrepareCalls, 0);
    });

    test('returns platform initialization failures', () async {
      final window = FakeWindowAdapter()..failEnsureInitialized = true;
      final lifecycle = _lifecycle(window: window);

      await expectLater(lifecycle.prepare(), throwsA(isA<StateError>()));
    });

    test('concurrent prepare calls share platform initialization', () async {
      final window = FakeWindowAdapter()..blockEnsureInitialized = true;
      final lifecycle = _lifecycle(window: window);

      final first = lifecycle.prepare();
      await window.ensureInitializedStarted.future;
      final second = lifecycle.prepare();
      await pumpEventQueue();
      final initializationCalls = window.ensureInitializedCalls;

      window.releaseEnsureInitialized();
      await Future.wait([first, second]);

      expect(initializationCalls, 1);
    });

    test('prepare retries after platform initialization fails', () async {
      final window = FakeWindowAdapter()..failEnsureInitialized = true;
      final lifecycle = _lifecycle(window: window);

      await expectLater(lifecycle.prepare(), throwsA(isA<StateError>()));

      window.failEnsureInitialized = false;
      await lifecycle.prepare();

      expect(window.listenerRegistered, isTrue);
    });

    test('close waits for in-flight prepare before destroying', () async {
      final window = FakeWindowAdapter()..blockEnsureInitialized = true;
      final lifecycle = _lifecycle(window: window);

      lifecycle.prepare().ignore();
      await window.ensureInitializedStarted.future;
      final closing = lifecycle.close();
      await pumpEventQueue();

      expect(window.events, isNot(contains('destroy')));

      window.releaseEnsureInitialized();
      expect(await closing, isTrue);
      expect(window.events.last, 'destroy');
    });

    test('close tears down after in-flight prepare fails', () async {
      final window = FakeWindowAdapter()
        ..blockEnsureInitialized = true
        ..failEnsureInitialized = true;
      final lifecycle = _lifecycle(window: window);

      lifecycle.prepare().ignore();
      await window.ensureInitializedStarted.future;
      final closing = lifecycle.close();
      await pumpEventQueue();
      window.releaseEnsureInitialized();

      expect(await closing, isTrue);
      expect(window.events.last, 'destroy');
    });

    test('prepare stays idle after close has started', () async {
      final window = FakeWindowAdapter();
      final lifecycle = _lifecycle(window: window);

      await lifecycle.prepare();
      await lifecycle.close();
      await lifecycle.prepare();

      expect(window.callsAfterDestroy, isEmpty);
    });
  });

  group('show', () {
    test('restores clamped geometry before showing and focusing', () async {
      final window = FakeWindowAdapter();
      final lifecycle = _lifecycle(
        window: window,
        persistence: MemoryPersistence(
          const GhostWindowSnapshot(
            bounds: Rect.fromLTWH(3000, 2000, 900, 600),
          ),
        ),
      );

      await lifecycle.prepare();
      await lifecycle.show();

      expect(window.readyOptions?.size, const Size(900, 600));
      expect(window.readyOptions?.placement, GhostWindowPlacement.restored);
      expect(window.bounds, const Rect.fromLTWH(510, 220, 900, 600));
      expect(window.events, ['ready', 'bounds', 'show', 'focus']);
    });

    test('windowReady resolves only once waitUntilReadyToShow has', () async {
      final window = FakeWindowAdapter()..blockReadyToShow = true;
      final lifecycle = _lifecycle(window: window);
      var ready = false;
      unawaited(lifecycle.windowReady.then((_) => ready = true));

      await lifecycle.prepare();
      final showing = lifecycle.show();
      await window.readyToShowStarted.future;
      await pumpEventQueue();
      expect(ready, isFalse);

      window.releaseReadyToShow();
      await showing;
      expect(ready, isTrue);
    });

    test('windowReady stays unresolved when prepare failed', () async {
      final window = FakeWindowAdapter()..failEnsureInitialized = true;
      final lifecycle = _lifecycle(window: window);
      var ready = false;
      unawaited(lifecycle.windowReady.then((_) => ready = true));

      await expectLater(lifecycle.prepare(), throwsA(isA<StateError>()));
      await lifecycle.show();
      await pumpEventQueue();

      expect(window.events, isNot(contains('ready')));
      expect(ready, isFalse);
    });

    test('show returns window presentation failures', () async {
      final window = FakeWindowAdapter()..failShow = true;
      final lifecycle = _lifecycle(window: window);

      await lifecycle.prepare();
      await expectLater(lifecycle.show(), throwsA(isA<StateError>()));
    });

    test(
      'a failed macOS show sequence still tries to reveal the hidden window',
      () async {
        final window = FakeWindowAdapter()..failSetBounds = true;
        final lifecycle = _lifecycle(
          window: window,
          platform: GhostDesktopPlatform.macos,
          persistence: MemoryPersistence(
            const GhostWindowSnapshot(bounds: Rect.fromLTWH(10, 10, 800, 600)),
          ),
        );

        await lifecycle.prepare();
        await expectLater(lifecycle.show(), throwsA(isA<StateError>()));

        expect(window.events.last, 'focus');
        expect(window.events, containsAllInOrder(['show', 'focus']));
      },
    );

    test('a macOS show without a prepared lifecycle still reveals', () async {
      final window = FakeWindowAdapter()..failEnsureInitialized = true;
      final lifecycle = _lifecycle(
        window: window,
        platform: GhostDesktopPlatform.macos,
      );

      await expectLater(lifecycle.prepare(), throwsA(isA<StateError>()));
      await lifecycle.show();

      expect(window.events, containsAllInOrder(['show', 'focus']));
    });

    test('a repeated show does not replay the launch restore', () async {
      final window = FakeWindowAdapter();
      final lifecycle = _lifecycle(
        window: window,
        platform: GhostDesktopPlatform.macos,
      );

      await lifecycle.prepare();
      await lifecycle.show();
      window.events.clear();

      // A host calling show() as a generic "bring to front" must not
      // re-assert the launch frame or re-run the native show sequence.
      await lifecycle.show();
      expect(window.events, isEmpty);
    });

    test(
      'macOS applies the saved frame hidden, then shows and full-screens',
      () async {
        final window = FakeWindowAdapter();
        final lifecycle = _lifecycle(
          window: window,
          platform: GhostDesktopPlatform.macos,
          persistence: MemoryPersistence(
            const GhostWindowSnapshot(
              bounds: Rect.fromLTWH(100, 100, 900, 700),
              isFullScreen: true,
            ),
          ),
        );

        await lifecycle.prepare();
        await lifecycle.show();

        expect(
          window.events,
          containsAllInOrder([
            'ready',
            'bounds',
            'show',
            'focus',
            'fullScreen',
          ]),
        );
        expect(window.fullScreen, isTrue);
        // Maximize is never applied for a full-screen restore.
        expect(window.events, isNot(contains('maximize')));
      },
    );

    test(
      'linux applies bounds and presentation flags before showing',
      () async {
        final window = FakeWindowAdapter();
        final lifecycle = _lifecycle(
          window: window,
          platform: GhostDesktopPlatform.linux,
          persistence: MemoryPersistence(
            const GhostWindowSnapshot(
              bounds: Rect.fromLTWH(50, 50, 1000, 700),
              isMaximized: true,
            ),
          ),
        );

        await lifecycle.prepare();
        await lifecycle.show();

        expect(
          window.events,
          containsAllInOrder(['ready', 'bounds', 'maximize', 'show', 'focus']),
        );
      },
    );

    test('windows restores position first, then the full frame, and defers '
        'maximize until the runner shows the window', () async {
      final window = FakeWindowAdapter();
      final debounce = FakeDebounceScheduler();
      final lifecycle = _lifecycle(
        window: window,
        platform: GhostDesktopPlatform.windows,
        debounce: debounce,
        persistence: MemoryPersistence(
          const GhostWindowSnapshot(
            bounds: Rect.fromLTWH(200, 150, 1100, 800),
            isMaximized: true,
          ),
        ),
      );

      await lifecycle.prepare();
      await lifecycle.show();

      expect(
        window.events,
        containsAllInOrder(['ready', 'position', 'bounds']),
      );
      expect(window.events, isNot(contains('maximize')));

      window.emitShow();
      await pumpEventQueue();

      expect(window.events, contains('maximize'));
      expect(window.maximized, isTrue);
    });

    test('the flags backstop queues behind an in-flight operation', () async {
      final window = FakeWindowAdapter();
      final debounce = FakeDebounceScheduler();
      final persistence = MemoryPersistence(
        const GhostWindowSnapshot(isFullScreen: true),
      )..blockWrites = true;
      final lifecycle = _lifecycle(
        window: window,
        platform: GhostDesktopPlatform.windows,
        debounce: debounce,
        persistence: persistence,
      );

      await lifecycle.prepare();
      await lifecycle.show();

      final saving = lifecycle.saveBounds();
      await persistence.writeStarted.future;

      // The backstop fires while a capture is still blocked on its write;
      // the flag apply must queue behind it, not write concurrently.
      unawaited(debounce.fire());
      await pumpEventQueue();
      expect(window.events, isNot(contains('fullScreen')));

      persistence.releaseWrites();
      await saving;
      await pumpEventQueue();
      expect(window.fullScreen, isTrue);
    });

    test('windows deferred flags also fire on the backstop', () async {
      final window = FakeWindowAdapter();
      final debounce = FakeDebounceScheduler();
      final lifecycle = _lifecycle(
        window: window,
        platform: GhostDesktopPlatform.windows,
        debounce: debounce,
        persistence: MemoryPersistence(
          const GhostWindowSnapshot(isFullScreen: true),
        ),
      );

      await lifecycle.prepare();
      await lifecycle.show();
      await debounce.fire();

      expect(window.fullScreen, isTrue);
    });

    test(
      'runner show trigger leaves show+focus to the native runner',
      () async {
        final window = FakeWindowAdapter();
        final lifecycle = _lifecycle(
          window: window,
          platform: GhostDesktopPlatform.windows,
          showTrigger: GhostShowTrigger.runner,
          persistence: MemoryPersistence(
            const GhostWindowSnapshot(bounds: Rect.fromLTWH(1, 2, 800, 600)),
          ),
        );

        await lifecycle.prepare();
        await lifecycle.show();

        expect(window.events, isNot(contains('show')));
        expect(window.events, isNot(contains('focus')));
      },
    );

    test(
      'windows physical space converts stored pixels through the ratio',
      () async {
        final window = FakeWindowAdapter()..devicePixelRatio = 2;
        final lifecycle = _lifecycle(
          window: window,
          platform: GhostDesktopPlatform.windows,
          coordinates: GhostCoordinateSpace.physicalOnWindows,
          showTrigger: GhostShowTrigger.runner,
          persistence: MemoryPersistence(
            const GhostWindowSnapshot(
              bounds: Rect.fromLTWH(300, 200, 1600, 1200),
            ),
          ),
          displays: FakeDisplayAdapter(
            all: [
              const GhostDisplay(
                workArea: Rect.fromLTWH(0, 0, 1920, 1040),
                scaleFactor: 2,
              ),
            ],
          ),
        );

        await lifecycle.prepare();
        await lifecycle.show();

        // Stored 1600x1200 physical at ratio 2 → 800x600 logical.
        expect(window.bounds, const Rect.fromLTWH(150, 100, 800, 600));
      },
    );
  });

  group('calibrateMinimumSize', () {
    test(
      'calibrates outer minimum size from first-frame content size',
      () async {
        final window = FakeWindowAdapter();
        final lifecycle = _lifecycle(window: window);

        await lifecycle.prepare();
        await lifecycle.show();
        await lifecycle.calibrateMinimumSize(const Size(1000, 600));

        // Frame is 1180-1000 x 760-600; the 720x480 content floor plus the
        // frame chrome is the outer minimum.
        expect(window.minimumSize, const Size(900, 640));
      },
    );

    test('recalibrates when the settled content inset changes', () async {
      final window = FakeWindowAdapter();
      final lifecycle = _lifecycle(window: window);

      await lifecycle.prepare();
      await lifecycle.show();
      await lifecycle.calibrateMinimumSize(const Size(1000, 600));
      await lifecycle.calibrateMinimumSize(const Size(1100, 650));

      expect(window.minimumSizes, [const Size(900, 640), const Size(800, 590)]);
    });

    test('calibration waits for presentation to settle', () async {
      final window = FakeWindowAdapter()..blockReadyToShow = true;
      final lifecycle = _lifecycle(window: window);

      await lifecycle.prepare();
      lifecycle.show().ignore();
      await window.readyToShowStarted.future;
      final calibrating = lifecycle.calibrateMinimumSize(const Size(1000, 600));
      await pumpEventQueue();

      expect(window.getBoundsStarted.isCompleted, isFalse);

      window.releaseReadyToShow();
      await calibrating;
      expect(window.minimumSize, const Size(900, 640));
    });

    test(
      'an in-flight calibration yields to the latest content size',
      () async {
        final window = FakeWindowAdapter()..blockGetBounds = true;
        final lifecycle = _lifecycle(window: window);

        await lifecycle.prepare();
        await lifecycle.show();
        final stale = lifecycle.calibrateMinimumSize(const Size(1000, 600));
        await window.getBoundsStarted.future;
        final current = lifecycle.calibrateMinimumSize(const Size(1100, 650));
        window.releaseGetBounds();
        await stale;
        await current;

        expect(window.minimumSizes, [const Size(800, 590)]);
      },
    );

    test(
      'close drops queued calibration and runs after presentation',
      () async {
        final window = FakeWindowAdapter()..blockReadyToShow = true;
        final lifecycle = _lifecycle(window: window);

        await lifecycle.prepare();
        lifecycle.show().ignore();
        await window.readyToShowStarted.future;
        lifecycle.calibrateMinimumSize(const Size(1000, 600)).ignore();
        final closing = lifecycle.close();
        window.releaseReadyToShow();
        await closing;

        expect(window.events.last, 'destroy');
        expect(window.minimumSizes, isEmpty);
      },
    );

    test('close waits for an active calibration before destroying', () async {
      final window = FakeWindowAdapter()..blockGetBounds = true;
      final lifecycle = _lifecycle(window: window);

      await lifecycle.prepare();
      await lifecycle.show();
      lifecycle.calibrateMinimumSize(const Size(1000, 600)).ignore();
      await window.getBoundsStarted.future;
      final closing = lifecycle.close();
      await pumpEventQueue();
      expect(window.events, isNot(contains('destroy')));

      window.releaseGetBounds();
      await closing;
      expect(window.events.last, 'destroy');
    });

    test('calibration failures are reported without escaping', () async {
      final window = FakeWindowAdapter()..failSetMinimumSize = true;
      final errors = <Object>[];
      final lifecycle = _lifecycle(
        window: window,
        onError: (error, _) => errors.add(error),
      );

      await lifecycle.prepare();
      await lifecycle.show();
      await lifecycle.calibrateMinimumSize(const Size(1000, 600));

      expect(errors, contains(isA<StateError>()));
    });
  });

  group('geometry tracking', () {
    test('move and resize save through the debounced path', () async {
      const saveDelay = Duration(milliseconds: 37);
      final window = FakeWindowAdapter();
      final persistence = MemoryPersistence();
      final debounce = FakeDebounceScheduler();
      final lifecycle = _lifecycle(
        window: window,
        persistence: persistence,
        debounce: debounce,
        saveDelay: saveDelay,
      );

      await lifecycle.prepare();
      window.emitMove();
      window.emitResize();

      expect(debounce.cancelCount, 1);
      expect(debounce.lastDelay, saveDelay);
      expect(persistence.writes, isEmpty);

      await debounce.fire();

      expect(persistence.writes, hasLength(1));
      expect(
        persistence.writes.single.bounds,
        const Rect.fromLTWH(80, 60, 1180, 760),
      );
    });

    test('a minimized window is never captured', () async {
      final window = FakeWindowAdapter()..minimized = true;
      final persistence = MemoryPersistence();
      final debounce = FakeDebounceScheduler();
      final lifecycle = _lifecycle(
        window: window,
        persistence: persistence,
        debounce: debounce,
      );

      await lifecycle.prepare();
      window.emitMove();
      await debounce.fire();

      expect(persistence.writes, isEmpty);
    });

    test(
      'a maximized window keeps its normal frame and stores the flag',
      () async {
        final window = FakeWindowAdapter()..maximized = true;
        final persistence = MemoryPersistence(
          const GhostWindowSnapshot(bounds: Rect.fromLTWH(40, 40, 900, 600)),
        );
        final debounce = FakeDebounceScheduler();
        final lifecycle = _lifecycle(
          window: window,
          persistence: persistence,
          debounce: debounce,
        );

        await lifecycle.prepare();
        window.emitMaximize();
        await debounce.fire();

        expect(persistence.writes, hasLength(1));
        expect(
          persistence.writes.single.bounds,
          const Rect.fromLTWH(40, 40, 900, 600),
        );
        expect(persistence.writes.single.isMaximized, isTrue);
      },
    );

    test(
      'windows capture converts logical bounds into physical pixels',
      () async {
        final window = FakeWindowAdapter()..devicePixelRatio = 1.5;
        final persistence = MemoryPersistence();
        final debounce = FakeDebounceScheduler();
        final lifecycle = _lifecycle(
          window: window,
          platform: GhostDesktopPlatform.windows,
          coordinates: GhostCoordinateSpace.physicalOnWindows,
          persistence: persistence,
          debounce: debounce,
        );

        await lifecycle.prepare();
        window.emitMove();
        await debounce.fire();

        expect(persistence.writes, hasLength(1));
        expect(
          persistence.writes.single.bounds,
          const Rect.fromLTWH(120, 90, 1770, 1140),
        );
      },
    );

    test('save failures are reported and do not escape callbacks', () async {
      final window = FakeWindowAdapter();
      final persistence = MemoryPersistence()..failWrites = true;
      final errors = <Object>[];
      final debounce = FakeDebounceScheduler();
      final lifecycle = _lifecycle(
        window: window,
        persistence: persistence,
        debounce: debounce,
        onError: (error, _) => errors.add(error),
      );

      await lifecycle.prepare();
      window.emitMove();
      await debounce.fire();

      expect(errors, hasLength(1));

      persistence.failWrites = false;
      await lifecycle.close();

      expect(window.events.last, 'destroy');
    });
  });

  group('close', () {
    test('cancels the timer, awaits the final save, then destroys', () async {
      final window = FakeWindowAdapter();
      final persistence = MemoryPersistence()..blockWrites = true;
      final debounce = FakeDebounceScheduler();
      final lifecycle = _lifecycle(
        window: window,
        persistence: persistence,
        debounce: debounce,
      );

      await lifecycle.prepare();
      window.emitMove();
      final closing = lifecycle.close();
      await persistence.writeStarted.future;
      expect(debounce.cancelCount, 1);
      expect(window.events, isNot(contains('destroy')));

      persistence.releaseWrites();
      await closing;
      expect(window.events.last, 'destroy');
      expect(window.listenerRegistered, isFalse);
    });

    test(
      'final geometry save failure is reported once before destroy',
      () async {
        final window = FakeWindowAdapter();
        final persistence = MemoryPersistence()..failWrites = true;
        final errors = <Object>[];
        final lifecycle = _lifecycle(
          window: window,
          persistence: persistence,
          onError: (error, _) => errors.add(error),
        );

        await lifecycle.prepare();
        await lifecycle.close();

        expect(errors, [isA<StateError>()]);
        expect(window.events.last, 'destroy');
      },
    );

    test('the close flush is awaited, bounded, before destroy', () async {
      final window = FakeWindowAdapter();
      final flushed = Completer<void>();
      final lifecycle = _lifecycle(
        window: window,
        onCloseFlush: () => flushed.future,
      );

      await lifecycle.prepare();
      final closing = lifecycle.close();
      await pumpEventQueue();
      expect(window.events, isNot(contains('destroy')));

      flushed.complete();
      expect(await closing, isTrue);
      expect(window.events.last, 'destroy');
    });

    test('a wedged close flush still lets the window destroy', () async {
      final window = FakeWindowAdapter();
      final errors = <Object>[];
      final lifecycle = _lifecycle(
        window: window,
        onCloseFlush: () => Completer<void>().future,
        onError: (error, _) => errors.add(error),
      );

      await lifecycle.prepare();
      expect(await lifecycle.close(), isTrue);
      expect(window.events.last, 'destroy');
      expect(errors, contains(isA<TimeoutException>()));
    }, timeout: const Timeout(Duration(seconds: 5)));

    test(
      'close callback reports destroy failures without an unhandled error',
      () async {
        final window = FakeWindowAdapter()..failDestroy = true;
        final errors = <Object>[];
        final errorReported = Completer<void>();
        final lifecycle = _lifecycle(
          window: window,
          onError: (error, _) {
            errors.add(error);
            if (!errorReported.isCompleted) errorReported.complete();
          },
        );

        await lifecycle.prepare();
        window.emitClose();
        await errorReported.future;

        expect(errors, contains(isA<StateError>()));
      },
    );

    test('close retries after window destruction fails', () async {
      final window = FakeWindowAdapter()..failDestroy = true;
      final lifecycle = _lifecycle(window: window);

      await lifecycle.prepare();
      await expectLater(lifecycle.close(), throwsA(isA<StateError>()));

      expect(window.listenerRegistered, isTrue);

      await lifecycle.show();
      expect(window.events, containsAllInOrder(['ready', 'show', 'focus']));

      window.failDestroy = false;
      await lifecycle.close();
      expect(window.events.last, 'destroy');
    });

    test('close stays idempotent after window destruction succeeds', () async {
      final window = FakeWindowAdapter();
      final lifecycle = _lifecycle(window: window);

      await lifecycle.prepare();
      await lifecycle.close();
      await lifecycle.close();

      expect(window.events.where((e) => e == 'destroy'), hasLength(1));
      expect(window.callsAfterDestroy, isEmpty);
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
      expect(window.listenerRegistered, isTrue);
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

    test('a guard error fails the close and leaves the window up', () async {
      final window = FakeWindowAdapter();
      final errors = <Object>[];
      final lifecycle = _lifecycle(
        window: window,
        confirmClose: () async => throw StateError('guard failed'),
        onError: (error, _) => errors.add(error),
      );

      await lifecycle.prepare();
      await expectLater(lifecycle.close(), throwsA(isA<StateError>()));

      expect(window.events, isNot(contains('destroy')));
      expect(window.listenerRegistered, isTrue);

      // The callback route surfaces the same failure through onError.
      window.emitClose();
      await pumpEventQueue();

      expect(errors, contains(isA<StateError>()));
    });

    test('a guard error does not wedge the close operation queue', () async {
      final window = FakeWindowAdapter();
      var failGuard = true;
      final lifecycle = _lifecycle(
        window: window,
        confirmClose: () async {
          if (failGuard) throw StateError('guard failed');
          return true;
        },
      );

      await lifecycle.prepare();
      await expectLater(lifecycle.close(), throwsA(isA<StateError>()));
      expect(window.events, isNot(contains('destroy')));

      // The queue must have released its slot: a fixed guard retires the
      // window on the next close.
      failGuard = false;
      expect(await lifecycle.close(), isTrue);
      expect(window.events.last, 'destroy');
    });

    test('another window taking the close skips the whole quit path', () async {
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
      expect(window.listenerRegistered, isTrue);

      // The last window's close is a quit again, guard first.
      instead = false;
      expect(await lifecycle.close(), isTrue);
      expect(guardCalls, 1);
      expect(window.events.last, 'destroy');
    });

    test('saveBounds writes the current bounds only once prepared', () async {
      final window = FakeWindowAdapter();
      final persistence = MemoryPersistence();
      final lifecycle = _lifecycle(window: window, persistence: persistence);

      await lifecycle.saveBounds();
      expect(persistence.writes, isEmpty);

      await lifecycle.prepare();
      await lifecycle.saveBounds();

      expect(persistence.writes, hasLength(1));
      expect(
        persistence.writes.single.bounds,
        const Rect.fromLTWH(80, 60, 1180, 760),
      );
    });

    test('saveBounds reports a write failure instead of throwing', () async {
      final window = FakeWindowAdapter();
      final persistence = MemoryPersistence()..failWrites = true;
      Object? reported;
      final lifecycle = _lifecycle(
        window: window,
        persistence: persistence,
        onError: (error, _) => reported = error,
      );

      await lifecycle.prepare();
      // A confirmed quit awaits this call; a throw there would strand the
      // exit. Failures surface through onError instead.
      await lifecycle.saveBounds();

      expect(persistence.writes, hasLength(1));
      expect(reported, isA<StateError>());
    });
  });

  group('observe close policy', () {
    test(
      'no prevent-close; the close event triggers a last-chance save',
      () async {
        final window = FakeWindowAdapter();
        final persistence = MemoryPersistence();
        final lifecycle = _lifecycle(
          window: window,
          persistence: persistence,
          closePolicy: GhostClosePolicy.observe,
        );

        await lifecycle.prepare();

        expect(window.preventClose, isFalse);

        window.emitClose();
        await pumpEventQueue();

        expect(persistence.writes, hasLength(1));
        expect(window.events, isNot(contains('destroy')));
      },
    );
  });

  group('missing-monitor policy', () {
    test(
      'rejectAndKeep falls back to default placement, frame retained',
      () async {
        final window = FakeWindowAdapter();
        final persistence = MemoryPersistence(
          const GhostWindowSnapshot(
            bounds: Rect.fromLTWH(5000, 5000, 900, 600),
          ),
        );
        final debounce = FakeDebounceScheduler();
        final lifecycle = _lifecycle(
          window: window,
          persistence: persistence,
          missingMonitor: MissingMonitorPolicy.rejectAndKeep,
          debounce: debounce,
        );

        await lifecycle.prepare();
        await lifecycle.show();

        // No setBounds: the saved monitor is gone, default placement wins.
        expect(window.events, isNot(contains('bounds')));
        expect(window.readyOptions?.placement, GhostWindowPlacement.centered);

        // Prepare and show never write: the retained frame must not be
        // overwritten before a real capture happens.
        expect(persistence.writes, isEmpty);

        // "Keep" holds only through restore; the first real capture
        // legitimately records where the window actually lives now.
        window.emitMove();
        await debounce.fire();
        expect(persistence.writes.single.bounds, window.bounds);
      },
    );

    test(
      'clampToNearest relocates the frame onto the primary work area',
      () async {
        final window = FakeWindowAdapter();
        final persistence = MemoryPersistence(
          const GhostWindowSnapshot(
            bounds: Rect.fromLTWH(5000, 5000, 900, 600),
          ),
        );
        final lifecycle = _lifecycle(window: window, persistence: persistence);

        await lifecycle.prepare();
        await lifecycle.show();

        expect(window.bounds, const Rect.fromLTWH(510, 220, 900, 600));
      },
    );
  });
}

GhostWindowLifecycle _lifecycle({
  required FakeWindowAdapter window,
  GhostDisplayAdapter? displays,
  GhostWindowPersistence? persistence,
  GhostDesktopPlatform platform = GhostDesktopPlatform.linux,
  GhostCoordinateSpace coordinates = GhostCoordinateSpace.logical,
  GhostShowTrigger showTrigger = GhostShowTrigger.service,
  MissingMonitorPolicy missingMonitor = MissingMonitorPolicy.clampToNearest,
  GhostClosePolicy closePolicy = GhostClosePolicy.intercept,
  Duration saveDelay = const Duration(milliseconds: 1),
  FakeDebounceScheduler? debounce,
  Future<void> Function()? onMacosPrepare,
  Future<void> Function()? onCloseFlush,
  Future<bool> Function()? confirmClose,
  Future<bool> Function()? closeInstead,
  void Function(Object, StackTrace)? onError,
}) {
  return GhostWindowLifecycle(
    persistence: persistence ?? MemoryPersistence(),
    window: window,
    displays: displays ?? FakeDisplayAdapter(),
    platform: platform,
    coordinates: coordinates,
    showTrigger: showTrigger,
    missingMonitor: missingMonitor,
    closePolicy: closePolicy,
    windowDefaults: const GhostWindowOptions(
      size: Size(1180, 760),
      minimumSize: Size(720, 480),
    ),
    minimumContentSize: const Size(720, 480),
    geometrySaveDelay: saveDelay,
    scheduleDebounce: debounce?.schedule,
    onMacosPrepare: onMacosPrepare,
    onCloseFlush: onCloseFlush,
    confirmClose: confirmClose,
    closeInstead: closeInstead,
    onError: onError,
  );
}
