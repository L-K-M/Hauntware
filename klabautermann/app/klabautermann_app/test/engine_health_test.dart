import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/engine_health.dart';
import 'package:klabautermann_app/controllers/engine_restarter.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/engine_health_notice.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// An engine that reports a fault for each [Connect] and dies of an
/// unhandled error on [Disconnect].
void _frailEngine(EngineStart start) {
  final commands = ReceivePort('frail engine');
  start.uiPort.send(commands.sendPort);
  commands.listen((message) {
    switch (message) {
      case Hello():
        start.uiPort.send(const EngineReady(kEngineProtocolVersion));
      case Connect(:final serverId):
        start.uiPort.send(EngineFault('fault for $serverId', stack: '#0'));
      case Disconnect():
        throw StateError('link table corrupt');
      case Shutdown():
        commands.close();
        Isolate.exit();
    }
  });
}

/// ENG-4 and ENG-6 in the app: what the engine caught and went on from,
/// and an engine that stopped by itself, reach the user.
void main() {
  group('EngineHealth over a real engine isolate', () {
    late Directory support;

    setUp(() => support = Directory.systemTemp.createTempSync('klab-health'));
    tearDown(() => support.deleteSync(recursive: true));

    Future<IsolateEngineClient> spawn() => IsolateEngineClient.spawn(
      supportDirectory: support.path,
      entryPoint: _frailEngine,
    );

    Future<void> changed(EngineHealth health) {
      final heard = Completer<void>();
      void onChange() {
        health.removeListener(onChange);
        heard.complete();
      }

      health.addListener(onChange);
      return heard.future.timeout(const Duration(seconds: 10));
    }

    test('counts the faults the engine reports', () async {
      final engine = await spawn();
      addTearDown(engine.shutdown);
      final health = EngineHealth()..follow(engine);
      addTearDown(health.dispose);

      final heard = changed(health);
      engine.send(const Connect('srv-1'));
      await heard;

      expect(health.faultCount, 1);
      expect(health.lastFault?.error, 'fault for srv-1');
      expect(health.stopped, isNull);
    });

    test('a restarter restarts an engine that died, says so, and ends '
        'the old run', () async {
      final health = EngineHealth();
      addTearDown(health.dispose);
      final first = _Run(await spawn());
      final restarter = EngineRestarter<_Run>(
        first: first,
        spawn: spawn,
        build: _Run.new,
        health: health,
        quitting: () => false,
        settled: () async {},
      );
      addTearDown(() async {
        await restarter.current.value.engine.shutdown();
        restarter.dispose();
      });

      final swapped = Completer<void>();
      restarter.current.addListener(swapped.complete);
      first.engine.send(const Disconnect('srv-1'));
      await swapped.future.timeout(const Duration(seconds: 10));
      await pumpEventQueue();

      final next = restarter.current.value;
      expect(next, isNot(same(first)));
      expect(health.stopped?.recovery, EngineRecovery.restarted);
      expect(health.stopped?.error, contains('link table corrupt'));
      expect(first.disposed, isTrue);
      expect(next.disposed, isFalse);

      // The new engine is followed: its faults count.
      final heard = changed(health);
      next.engine.send(const Connect('srv-2'));
      await heard;
      expect(health.lastFault?.error, 'fault for srv-2');
    });

    test('an engine that keeps stopping is left stopped after three '
        'restarts in ten minutes', () async {
      final health = EngineHealth();
      addTearDown(health.dispose);
      final restarter = EngineRestarter<_Run>(
        first: _Run(await spawn()),
        spawn: spawn,
        build: _Run.new,
        health: health,
        quitting: () => false,
        settled: () async {},
        now: () => DateTime.utc(2026, 11, 24, 12),
      );
      addTearDown(() async {
        await restarter.current.value.engine.shutdown();
        restarter.dispose();
      });

      for (var restart = 0; restart < 3; restart++) {
        final swapped = Completer<void>();
        void onSwap() {
          restarter.current.removeListener(onSwap);
          swapped.complete();
        }

        restarter.current.addListener(onSwap);
        restarter.current.value.engine.send(const Disconnect('srv-1'));
        await swapped.future.timeout(const Duration(seconds: 10));
      }
      final last = restarter.current.value;
      last.engine.send(const Disconnect('srv-1'));
      await last.engine.exited.timeout(const Duration(seconds: 10));
      await pumpEventQueue();

      expect(restarter.current.value, same(last));
      expect(health.stopped?.recovery, EngineRecovery.gaveUp);
    });

    test('an engine that does not start again is told as stopped', () async {
      final health = EngineHealth();
      addTearDown(health.dispose);
      final first = _Run(await spawn());
      final restarter = EngineRestarter<_Run>(
        first: first,
        spawn: () => Future.error(StateError('no isolate')),
        build: _Run.new,
        health: health,
        quitting: () => false,
        settled: () async {},
      );
      addTearDown(restarter.dispose);

      final heard = changed(health);
      first.engine.send(const Disconnect('srv-1'));
      await heard;
      await pumpEventQueue();

      expect(restarter.current.value, same(first));
      expect(health.stopped?.recovery, EngineRecovery.gaveUp);
      expect(health.stopped?.error, contains('link table corrupt'));
    });

    test('a run that fails to build over a restarted engine leaves the '
        'engine stopped and says so', () async {
      final health = EngineHealth();
      addTearDown(health.dispose);
      final first = _Run(await spawn());
      IsolateEngineClient? spawned;
      final restarter = EngineRestarter<_Run>(
        first: first,
        spawn: () async => spawned = await spawn(),
        build: (_) => throw StateError('no controllers'),
        health: health,
        quitting: () => false,
        settled: () async {},
      );
      addTearDown(restarter.dispose);

      first.engine.send(const Disconnect('srv-1'));
      await first.engine.exited.timeout(const Duration(seconds: 10));
      while (health.stopped?.recovery != EngineRecovery.gaveUp) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(restarter.current.value, same(first));
      expect(health.stopped?.error, contains('link table corrupt'));
      // The engine nothing was built over is shut down.
      await spawned!.exited.timeout(const Duration(seconds: 10));
    });

    test("does not report or restart after the app's own shutdown", () async {
      var quitting = false;
      final health = EngineHealth();
      addTearDown(health.dispose);
      final first = _Run(await spawn());
      var spawned = 0;
      final restarter = EngineRestarter<_Run>(
        first: first,
        spawn: () {
          spawned++;
          return spawn();
        },
        build: _Run.new,
        health: health,
        quitting: () => quitting,
        settled: () async {},
      );
      addTearDown(restarter.dispose);

      quitting = true;
      await first.engine.shutdown();
      await first.engine.exited;
      await pumpEventQueue();

      expect(health.stopped, isNull);
      expect(spawned, 0);
    });
  });

  group('EngineHealthNotice', () {
    late EngineHealth health;
    late DateTime now;

    setUp(() {
      health = EngineHealth();
      now = DateTime.utc(2026, 11, 24, 12);
    });
    tearDown(() => health.dispose());

    Future<void> pump(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: EngineHealthNotice(
          health: health,
          now: () => now,
          child: const Scaffold(body: Text('fleet')),
        ),
      ),
    );

    const told =
        'Something went wrong in the background and was stopped. '
        'Klabautermann keeps running; if what you just asked for did not '
        'happen, try it again.';

    testWidgets('tells a fault once, and a repeating one again only after '
        'a minute', (tester) async {
      await pump(tester);
      expect(find.text(told), findsNothing);

      health.reportFault(const EngineFault('boom'));
      await tester.pump();
      expect(find.text(told), findsOneWidget);

      health.reportFault(const EngineFault('boom'));
      await tester.pump();
      expect(find.text(told), findsOneWidget);
      // The first toast leaves.
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
      expect(find.text(told), findsNothing);

      now = now.add(const Duration(minutes: 2));
      health.reportFault(const EngineFault('boom'));
      await tester.pump();
      expect(find.text(told), findsOneWidget);
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
    });

    testWidgets('an engine that stopped gets a dialog with its error, once', (
      tester,
    ) async {
      await pump(tester);

      health.reportStopped(const EngineStopped(error: 'Bad state: corrupt'));
      // Gave up is the default recovery.
      await tester.pumpAndSettle();
      expect(
        find.text('Klabautermann stopped working in the background'),
        findsOneWidget,
      );
      expect(find.text('Details: Bad state: corrupt'), findsOneWidget);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      health.reportFault(const EngineFault('late'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
    });

    testWidgets('one that stopped before the app mounted is told after the '
        'first frame', (tester) async {
      health.reportStopped(const EngineStopped());
      await pump(tester);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('Details:'), findsNothing);
    });

    testWidgets('a restarted engine is told once its restart ran, and a '
        'remount does not tell it again', (tester) async {
      await pump(tester);

      health.reportStopped(
        const EngineStopped(
          error: 'Bad state: corrupt',
          recovery: EngineRecovery.restarting,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      health.reportStopped(
        const EngineStopped(
          error: 'Bad state: corrupt',
          recovery: EngineRecovery.restarted,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Klabautermann restarted its background engine'),
        findsOneWidget,
      );
      expect(find.text('Details: Bad state: corrupt'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // The restart remounts the app's tree, and this notice with it.
      await tester.pumpWidget(const SizedBox());
      await pump(tester);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}

/// An engine run with nothing built over it but a flag.
final class _Run implements EngineRun {
  _Run(this.engine);

  @override
  final IsolateEngineClient engine;
  bool disposed = false;

  @override
  void dispose() => disposed = true;
}
