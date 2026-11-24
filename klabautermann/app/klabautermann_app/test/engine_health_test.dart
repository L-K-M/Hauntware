import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/engine_health.dart';
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
      final health = EngineHealth()..follow(engine, expected: () => false);
      addTearDown(health.dispose);

      final heard = changed(health);
      engine.send(const Connect('srv-1'));
      await heard;

      expect(health.faultCount, 1);
      expect(health.lastFault?.error, 'fault for srv-1');
      expect(health.stopped, isNull);
    });

    test('says what an engine that died stopped on', () async {
      final engine = await spawn();
      addTearDown(engine.shutdown);
      final health = EngineHealth()..follow(engine, expected: () => false);
      addTearDown(health.dispose);

      final heard = changed(health);
      engine.send(const Disconnect('srv-1'));
      await heard;

      expect(health.stopped?.error, contains('link table corrupt'));
    });

    test("does not report the app's own shutdown as a stop", () async {
      final engine = await spawn();
      var quitting = false;
      final health = EngineHealth()..follow(engine, expected: () => quitting);
      addTearDown(health.dispose);

      quitting = true;
      await engine.shutdown();
      await engine.exited;
      await pumpEventQueue();

      expect(health.stopped, isNull);
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
  });
}
