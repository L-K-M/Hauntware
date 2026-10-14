import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/services/instance_guard.dart';
import 'package:klabautermann_app/ui/already_running_app.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/harness.dart';
import 'support/native_sources.dart';

const _title = 'Klabautermann is already running';
const _unguarded =
    'Klabautermann could not check whether it is already running. If you '
    'open it twice, the two copies can overwrite each other\'s settings and '
    'imported servers.';

/// One desktop instance (03 §4.10). The lock itself, a second process
/// included, is covered by `klabautermann_core`'s instance lock tests.
void main() {
  group('the instance lock', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('klab-app-instance-');
    });

    tearDown(() => directory.deleteSync(recursive: true));

    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    ]) {
      test('is taken once on ${platform.name}', () async {
        final first = await lockInstanceFor(platform, directory);
        expect(first, isA<InstanceLockAcquired>());
        addTearDown((first! as InstanceLockAcquired).lock.release);

        expect(
          await lockInstanceFor(platform, directory),
          isA<InstanceLockHeld>(),
        );
      });
    }

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      test('is not taken on ${platform.name}', () async {
        expect(await lockInstanceFor(platform, directory), isNull);
        expect(directory.listSync(), isEmpty);
      });
    }

    test('comes after the settings window\'s branch and before the settings '
        'store and the engine', () {
      final main = readSource('lib/main.dart');
      final branch = main.indexOf('if (args.contains(settingsWindowArgument))');
      final lock = main.indexOf('lockInstanceFor(');
      final held = main.indexOf('case InstanceLockHeld():');
      final settings = main.indexOf('DeviceSettingsStore.open(');
      final engine = main.indexOf('IsolateEngineClient.spawn(');

      expect(branch, isNonNegative);
      expect(lock, greaterThan(branch));
      expect(settings, greaterThan(lock));
      expect(engine, greaterThan(lock));
      // A second instance runs the notice and returns before either.
      expect(held, greaterThan(lock));
      expect(
        main.substring(held, settings),
        contains(RegExp(r'runApp\(\s*AlreadyRunningApp\([^]*?\);\s*return;')),
      );
    });
  });

  group('a second instance', () {
    testWidgets('says so and quits from its button', (tester) async {
      var quits = 0;
      await tester.pumpWidget(AlreadyRunningApp(onQuit: () => quits++));
      await tester.pumpAndSettle();

      expect(find.text(_title), findsOneWidget);
      expect(
        find.textContaining('Switch to the Klabautermann window'),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(find.text(_title)).flagsCollection.isHeader,
        isTrue,
      );

      await tester.tap(find.text('Quit'));
      expect(quits, 1);
    });

    testWidgets('quits from the keyboard', (tester) async {
      var quits = 0;
      await tester.pumpWidget(AlreadyRunningApp(onQuit: () => quits++));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(quits, 1);
    });
  });

  testWidgets('an instance without the lock says so once at startup', (
    tester,
  ) async {
    await pumpApp(
      tester,
      instanceLockIssue: const InstanceLockUnavailable(
        FileSystemException('lock failed', '/support/instance.lock'),
      ),
    );

    expect(find.text(_unguarded), findsOneWidget);
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();
    expect(find.text(_unguarded), findsNothing);
  });
}
