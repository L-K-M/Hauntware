import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart';

const _strings = GhostAppLockStrings(
  title: 'The app is locked',
  detail: 'Unlock with this device\'s passcode.',
  unlock: 'Unlock',
  failed: 'Authentication failed or was cancelled. Try again.',
  unavailable: 'This device has no passcode, PIN or biometrics to ask for.',
);
const _content = 'app content';

/// A lock the test drives: [locked] notifies, [unlock] answers
/// [nextOutcome] after [hold] lets it, and lifecycle states land on
/// [lifecycle].
final class _FakeLock extends ChangeNotifier implements GhostAppLockGateModel {
  bool _locked = false;
  int availabilityProbes = 0;
  int unlocks = 0;
  GhostAppLockUnlock nextOutcome = GhostAppLockUnlock.unlocked;
  AppLifecycleState? lifecycle;

  /// While non-null, an unlock waits for it.
  Completer<void>? hold;

  @override
  bool get locked => _locked;

  set locked(bool value) {
    if (value == _locked) return;
    _locked = value;
    notifyListeners();
  }

  @override
  Future<void> refreshAvailability() async => availabilityProbes++;

  @override
  Future<GhostAppLockUnlock> unlock() async {
    unlocks++;
    await hold?.future;
    if (nextOutcome == GhostAppLockUnlock.unlocked) locked = false;
    return nextOutcome;
  }

  @override
  void onLifecycle(AppLifecycleState state) => lifecycle = state;
}

/// SAF-20: the shared lock screen over the whole app.
void main() {
  late _FakeLock lock;
  late int taps;

  setUp(() {
    lock = _FakeLock();
    taps = 0;
  });

  Future<void> pump(WidgetTester tester, {_FakeLock? model}) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => GhostAppLockGate(
          model: model ?? lock,
          strings: _strings,
          child: child!,
        ),
        home: Scaffold(
          body: TextButton(
            onPressed: () => taps++,
            child: const Text(_content),
          ),
        ),
      ),
    );
  }

  testWidgets('unlocked, the app shows at once and never asks', (tester) async {
    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.text(_strings.title), findsNothing);
    expect(find.text(_content), findsOneWidget);
    expect(lock.unlocks, 0);
    expect(lock.availabilityProbes, 1);
  });

  testWidgets('locked, the screen asks by itself and hides the app from '
      'touch and screen readers', (tester) async {
    final semantics = tester.ensureSemantics();
    lock.hold = Completer<void>();
    lock.locked = true;
    await pump(tester);
    await tester.pump();

    expect(lock.unlocks, 1);
    expect(find.text(_strings.title), findsOneWidget);
    expect(find.bySemanticsLabel(_content), findsNothing);
    expect(find.bySemanticsLabel(_strings.title), findsOneWidget);
    // A tap on the app beneath reaches nothing.
    await tester.tap(find.text(_content), warnIfMissed: false);
    expect(taps, 0);

    lock.hold!.complete();
    await tester.pumpAndSettle();
    expect(find.text(_strings.title), findsNothing);
    expect(find.bySemanticsLabel(_content), findsOneWidget);
    expect(lock.unlocks, 1);
    semantics.dispose();
  });

  testWidgets('a rejected prompt says so and Unlock asks again', (
    tester,
  ) async {
    lock.locked = true;
    lock.nextOutcome = GhostAppLockUnlock.failed;
    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.text(_strings.failed), findsOneWidget);
    expect(lock.unlocks, 1);

    lock.nextOutcome = GhostAppLockUnlock.unlocked;
    await tester.tap(find.text(_strings.unlock));
    await tester.pumpAndSettle();
    expect(lock.unlocks, 2);
    expect(find.text(_strings.title), findsNothing);
  });

  testWidgets('a device with no authentication says what to set up', (
    tester,
  ) async {
    lock.locked = true;
    lock.nextOutcome = GhostAppLockUnlock.unavailable;
    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.text(_strings.unavailable), findsOneWidget);
    expect(lock.unlocks, 1);
  });

  testWidgets('a lock that engages while the app runs covers it and asks '
      'once', (tester) async {
    await pump(tester);
    await tester.pumpAndSettle();
    expect(lock.unlocks, 0);

    lock.locked = true;
    lock.nextOutcome = GhostAppLockUnlock.failed;
    await tester.pumpAndSettle();
    expect(find.text(_strings.title), findsOneWidget);
    expect(lock.unlocks, 1);
    // Still locked after the first ask: it does not keep asking.
    await tester.pump();
    expect(lock.unlocks, 1);
  });

  testWidgets('a new model starts its own locked spell', (tester) async {
    lock.locked = true;
    await pump(tester);
    await tester.pumpAndSettle();
    expect(lock.unlocks, 1);

    final next = _FakeLock()..locked = true;
    await pump(tester, model: next);
    await tester.pumpAndSettle();
    expect(next.unlocks, 1);
  });

  testWidgets('the app\'s lifecycle reaches the model', (tester) async {
    await pump(tester);
    await tester.pumpAndSettle();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(lock.lifecycle, AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(lock.lifecycle, AppLifecycleState.resumed);
  });
}
