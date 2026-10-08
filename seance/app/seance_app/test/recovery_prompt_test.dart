import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/ui/recovery_prompt.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// CRED-05's enrolment prompt: after a credential is saved on a device
/// without a recovery code, the code is offered once; "Not now" is
/// remembered.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Directory? directory;
  AppServices? services;
  AppState? state;

  tearDown(() async {
    state?.dispose();
    state = null;
    await services?.probe.dispose();
    services = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    try {
      await directory?.delete(recursive: true);
    } on FileSystemException {
      // Deliberately ignored: the OS reaps system temp dirs.
    }
    directory = null;
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('seance-prompt-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pathChannel, (_) async => directory!.path);
      FlutterSecureStorage.setMockInitialValues({});
      services = await AppServices.initialize();
      state = AppState(services!);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => offerRecoveryCode(context, state!),
              child: const Text('saved a credential'),
            ),
          ),
        ),
      ),
    );
  }

  /// Taps [finder] and lets the vault reads and writes it starts finish:
  /// each file and crypto step needs a slice of real time. Waits until
  /// [shows] appears, or [hides] is gone, within a bound generous enough for
  /// a loaded machine.
  Future<void> tapAndSettle(
    WidgetTester tester,
    Finder finder, {
    Finder? shows,
    Finder? hides,
  }) async {
    await tester.tap(finder);
    bool done() =>
        (shows == null || shows.evaluate().isNotEmpty) &&
        (hides == null || hides.evaluate().isEmpty);
    for (var i = 0; i < 250; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      if ((shows != null || hides != null) && done()) return;
      if (shows == null && hides == null && i >= 30) return;
    }
  }

  testWidgets('"Not now" is remembered and the offer is not made again', (
    tester,
  ) async {
    await pump(tester);

    await tapAndSettle(
      tester,
      find.text('saved a credential'),
      shows: find.text('Set up a recovery code?'),
    );
    expect(find.text('Set up a recovery code?'), findsOneWidget);
    await tapAndSettle(
      tester,
      find.byKey(const ValueKey('recovery.prompt.notNow')),
    );
    expect(services!.settings.recoveryPromptDeclined, isTrue);

    await tapAndSettle(tester, find.text('saved a credential'));
    expect(find.text('Set up a recovery code?'), findsNothing);
  });

  testWidgets('setting up shows the code and keeps it once confirmed', (
    tester,
  ) async {
    await pump(tester);

    await tapAndSettle(
      tester,
      find.text('saved a credential'),
      shows: find.text('Set up a recovery code?'),
    );
    await tapAndSettle(
      tester,
      find.byKey(const ValueKey('recovery.prompt.setUp')),
      shows: find.byKey(const ValueKey('recovery.code')),
    );
    final code = tester
        .widget<SelectableText>(find.byKey(const ValueKey('recovery.code')))
        .data!;
    await tester.enterText(
      find.byKey(const ValueKey('recovery.code.confirm')),
      code.split('-').first,
    );
    await tester.pump();
    await tapAndSettle(
      tester,
      find.byKey(const ValueKey('recovery.code.done')),
      hides: find.byKey(const ValueKey('recovery.code')),
    );

    expect(find.byKey(const ValueKey('recovery.code')), findsNothing);
    expect(await tester.runAsync(() => state!.recoveryConfigured()), isTrue);

    // With a code, saving another credential offers nothing.
    await tapAndSettle(tester, find.text('saved a credential'));
    expect(find.text('Set up a recovery code?'), findsNothing);
  });

  testWidgets('dismissing without an answer asks again next time', (
    tester,
  ) async {
    await pump(tester);

    await tapAndSettle(
      tester,
      find.text('saved a credential'),
      shows: find.text('Set up a recovery code?'),
    );
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.text('Set up a recovery code?'), findsNothing);
    expect(services!.settings.recoveryPromptDeclined, isFalse);

    await tapAndSettle(
      tester,
      find.text('saved a credential'),
      shows: find.text('Set up a recovery code?'),
    );
    expect(find.text('Set up a recovery code?'), findsOneWidget);
  });
}
