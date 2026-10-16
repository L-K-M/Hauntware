import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/services/instance_guard.dart';
import 'package:klabautermann_app/services/window_state.dart';
import 'package:klabautermann_app/ui/already_running_app.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_window.dart';
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
          supportDirectoryAccessFor(first),
          SupportDirectoryAccess.exclusive,
        );

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

    test('lets the engine write its caches only with the directory to '
        'itself (D59)', () {
      final lock = InstanceLockUnavailable(
        const FileSystemException('no locks'),
      );
      expect(supportDirectoryAccessFor(null), SupportDirectoryAccess.exclusive);
      expect(supportDirectoryAccessFor(lock), SupportDirectoryAccess.unguarded);
      expect(
        supportDirectoryAccessFor(const InstanceLockHeld()),
        SupportDirectoryAccess.unguarded,
      );
      expect(
        readSource('lib/main.dart'),
        contains('supportDirectoryAccess: supportDirectoryAccessFor('),
      );
    });

    test('comes after the settings window\'s branch and before the '
        'titlebar, the settings store, the window state and the engine', () {
      final main = readSource('lib/main.dart');
      final branch = main.indexOf('if (args.contains(settingsWindowArgument))');
      final lock = main.indexOf('lockInstanceFor(');
      final held = main.indexOf('case InstanceLockHeld():');
      final titlebar = main.indexOf('installMacosTitlebar(');
      final settings = main.indexOf('DeviceSettingsStore.open(');
      final restore = main.indexOf('restoreMainWindow(');
      final engine = main.indexOf('IsolateEngineClient.spawn(');

      expect(branch, isNonNegative);
      expect(lock, greaterThan(branch));
      for (final later in [titlebar, settings, restore, engine]) {
        expect(later, greaterThan(lock));
      }
      // A second instance shows its window, runs the notice and returns
      // before all of them: window_state.json is the running instance's.
      expect(held, greaterThan(lock));
      final heldReturn = main.indexOf('return;', held);
      expect(heldReturn, lessThan(titlebar));
      final heldPath = main.substring(held, heldReturn);
      expect(
        heldPath,
        contains(
          RegExp(
            r'await showMainWindowUnrestored\(\s*platform: '
            r'defaultTargetPlatform,?\s*\);\s*runApp\(\s*AlreadyRunningApp\(',
          ),
        ),
      );
      for (final name in ['restoreMainWindow(', 'windowStateFileName']) {
        expect(heldPath, isNot(contains(name)), reason: name);
      }
    });
  });

  group('a second instance\'s window', () {
    test('is shown on macOS where the runner placed it, with no window '
        'state read or written', () async {
      final window = FakeWindow();
      await showMainWindowUnrestored(
        platform: TargetPlatform.macOS,
        window: window,
      );
      expect(window.calls, ['ensureInitialized', 'show', 'focus']);
      expect(window.listening, isFalse);
    });

    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      test('is left to the runner on ${platform.name}', () async {
        final window = FakeWindow();
        await showMainWindowUnrestored(platform: platform, window: window);
        expect(window.calls, isEmpty);
      });
    }

    test('stays as it is when the window plugin fails, without '
        'throwing', () async {
      final window = FakeWindow()..failEnsureInitialized = true;
      await showMainWindowUnrestored(
        platform: TargetPlatform.macOS,
        window: window,
      );
      expect(window.calls, ['ensureInitialized']);
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

    testWidgets('scrolls to its Quit button in a small window at twice the '
        'text size (A11Y-09)', (tester) async {
      tester.view.physicalSize = const Size(640, 400);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      var quits = 0;
      await tester.pumpWidget(AlreadyRunningApp(onQuit: () => quits++));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Quit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Quit'));
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
