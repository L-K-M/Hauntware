import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/native_sources.dart';

const _controller = 'KlabautermannFlutterViewController';
const _bridgingHeader = 'Runner-Bridging-Header.h';
const _runnerDir = 'macos/Runner';
const _projectPath = 'macos/Runner.xcodeproj/project.pbxproj';
const _lifecycleTestPath = 'macos/RunnerTests/AccessibilityLifecycleTest.mm';
const _scriptsDir = '../../scripts';
const _executableBits = 0x49; // 0o111

/// The macOS runner's keyboard and accessibility compatibility controller,
/// copied from Séance (docs/SHARED.md). Only a Mac can compile it or run
/// the native fixtures (scripts/test-macos-{keyboard,accessibility}.sh), so
/// these checks keep the wiring from silently regressing on Linux CI: the
/// main window must use the controller, Xcode must compile it into the
/// Runner target, Swift must see it through the bridging header, and both
/// fixtures must exercise this same source.
void main() {
  test('the main window hosts the compatibility controller', () {
    final window = readSource('$_runnerDir/MainFlutterWindow.swift');

    expect(window, contains('let flutterViewController = $_controller()'));
    expect(
      window,
      isNot(contains(RegExp(r'\bFlutterViewController\('))),
      reason: 'a stock controller drops both compatibility fixes',
    );
    expect(window, contains('contentViewController = flutterViewController'));
    expect(
      window,
      contains('RegisterGeneratedPlugins(registry: flutterViewController)'),
    );
  });

  test('the controller keeps both compatibility fixes', () {
    final header = readSource('$_runnerDir/$_controller.h');
    final source = readSource('$_runnerDir/$_controller.m');

    expect(header, contains('@interface $_controller : FlutterViewController'));
    expect(source, contains('@implementation $_controller'));
    // The injected-Command normalization runs on both key edges.
    expect(source, contains('NX_DEVICELCMDKEYMASK'));
    expect(source, contains('- (void)keyDown:'));
    expect(source, contains('- (void)keyUp:'));
    // The accessibility guard runs before semantics teardown and on
    // controller destruction.
    expect(source, contains('- (void)notifySemanticsEnabledChanged'));
    expect(source, contains('- (void)dealloc'));
    expect(source, contains('[field setPlatformNode:NULL]'));
  });

  test('Swift sees the controller through the bridging header', () {
    expect(
      readSource('$_runnerDir/$_bridgingHeader'),
      contains('#import "$_controller.h"'),
    );
    expect(
      readSource('$_runnerDir/Configs/AppInfo.xcconfig'),
      contains('SWIFT_OBJC_BRIDGING_HEADER = Runner/$_bridgingHeader'),
    );
  });

  group('the Xcode project', () {
    final project = readSource(_projectPath);

    test('references the controller files and the bridging header', () {
      for (final (name, type) in const [
        ('$_controller.m', 'sourcecode.c.objc'),
        ('$_controller.h', 'sourcecode.c.h'),
        (_bridgingHeader, 'sourcecode.c.h'),
      ]) {
        final id = xcodeFileReferenceId(project, name);
        expect(id, isNotNull, reason: '$name has no file reference');
        expect(
          project,
          contains(
            RegExp(
              '$id /\\* ${RegExp.escape(name)} \\*/ = \\{isa = '
              'PBXFileReference; lastKnownFileType = $type;',
            ),
          ),
          reason: name,
        );
        expect(
          xcodeListEntries(project, xcodeRunnerGroupId(project), 'children'),
          contains(id),
          reason: '$name is not in the Runner group',
        );
      }
    });

    test('compiles the controller into the Runner target only', () {
      final fileId = xcodeFileReferenceId(project, '$_controller.m')!;
      final buildFiles = RegExp(
        '([0-9A-F]{24}) /\\* $_controller\\.m in Sources \\*/ = '
        '\\{isa = PBXBuildFile; fileRef = $fileId ',
      ).allMatches(project).map((match) => match[1]!).toList();
      expect(buildFiles, hasLength(1));

      expect(
        xcodeTargetSources(project, 'Runner'),
        contains(buildFiles.single),
      );
      expect(
        xcodeTargetSources(project, 'RunnerTests'),
        isNot(contains(buildFiles.single)),
      );
    });

    test('defines every object id once', () {
      final definitions = RegExp(
        r'^\t\t([0-9A-F]{24}) (?:/\*.*?\*/ )?= \{',
        multiLine: true,
      ).allMatches(project).map((match) => match[1]!).toList();
      expect(definitions.toSet(), hasLength(definitions.length));

      final referenced = RegExp(
        r'\b[0-9A-F]{24}\b',
      ).allMatches(project).map((match) => match[0]!).toSet();
      expect(referenced.difference(definitions.toSet()), isEmpty);
    });
  });

  group('the native fixtures', () {
    test('the keyboard fixture compiles this controller into the shared '
        'checks', () {
      final script = readSource('$_scriptsDir/test-macos-keyboard.sh');
      final fixture = readSource('$_scriptsDir/test-macos-keyboard.mm');

      expect(
        script,
        contains('runner_dir="\$repo_root/app/klabautermann_app/$_runnerDir"'),
      );
      expect(script, contains('"\$runner_dir/$_controller.m"'));
      expect(script, contains('KLABAUTERMANN_USE_CONTROLLER=1'));
      expect(script, contains('KLABAUTERMANN_USE_CONTROLLER=0'));
      expect(fixture, contains('#if KLABAUTERMANN_USE_CONTROLLER'));
      expect(fixture, contains('#define FixtureController $_controller'));

      const include = '../../scripts/macos-keyboard-fixture.mm';
      expect(fixture, contains('#include "$include"'));
      expect(File('$_scriptsDir/$include').existsSync(), isTrue);
    });

    test('the accessibility fixture compiles this controller into the '
        'lifecycle test', () {
      final script = readSource('$_scriptsDir/test-macos-accessibility.sh');
      final lifecycle = readSource(_lifecycleTestPath);

      expect(script, contains('"\$runner_dir/$_controller.m"'));
      expect(
        script,
        contains('"\$repo_root/app/klabautermann_app/$_lifecycleTestPath"'),
      );
      expect(script, contains('KLABAUTERMANN_USE_GUARD=1'));
      expect(script, contains('KLABAUTERMANN_USE_GUARD=0'));
      expect(lifecycle, contains('#if KLABAUTERMANN_USE_GUARD'));
      expect(lifecycle, contains('#define FixtureBaseController $_controller'));
    });

    test('both fixture scripts are executable', () {
      for (final name in const [
        'test-macos-keyboard.sh',
        'test-macos-accessibility.sh',
      ]) {
        final mode = File('$_scriptsDir/$name').statSync().mode;
        expect(mode & _executableBits, _executableBits, reason: name);
      }
    }, skip: Platform.isWindows ? 'Windows has no POSIX file modes' : false);
  });
}
