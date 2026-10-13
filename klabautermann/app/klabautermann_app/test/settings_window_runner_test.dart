import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_desktop/ghost_desktop.dart'
    show GhostSettingsControlMethod;
import 'package:klabautermann_app/services/settings_window/settings_window_link.dart';

import 'support/native_sources.dart';

const _projectPath = 'macos/Runner.xcodeproj/project.pbxproj';

/// The settings window's runners (D32), copied from Séance (docs/SHARED.md).
/// Only macOS, Windows and a Linux toolchain with GTK compile them, so these
/// checks keep the wiring from silently regressing on Linux CI: every runner
/// serves the Dart side's channels and launch argument, opens the window on
/// a second engine without the app's plugins, hides it on close instead of
/// tearing that engine down, and is built into and installed by the main
/// window.
void main() {
  final runners = {
    'macos': readSource('macos/Runner/SettingsWindow.swift'),
    'linux': readSource('linux/runner/settings_window.cc'),
    'windows': readSource('windows/runner/settings_window.cpp'),
  };

  test('every runner serves the channels, argument and control methods '
      'the Dart side uses', () {
    for (final MapEntry(key: platform, value: source) in runners.entries) {
      for (final name in [
        settingsWindowControlChannel.name,
        settingsWindowLinkChannel.name,
        settingsWindowArgument,
        GhostSettingsControlMethod.open.name,
        GhostSettingsControlMethod.closed.name,
      ]) {
        expect(source, contains('"$name"'), reason: '$platform $name');
      }
    }
  });

  test('the Dart entrypoint runs the window, and nothing else, for the '
      'runners\' argument', () {
    final main = readSource('lib/main.dart');
    final branch = main.indexOf('if (args.contains(settingsWindowArgument))');
    final engine = main.indexOf('IsolateEngineClient.spawn(');
    expect(main, contains('Future<void> main(List<String> args)'));
    expect(branch, isNonNegative);
    // D18: the window's engine returns before an engine isolate exists.
    expect(engine, greaterThan(branch));
    expect(
      main.substring(branch, engine),
      contains(RegExp(r'await runSettingsWindow\(\);\s*return;')),
    );

    // The window's own files import nothing from the engine package. The
    // screens they render are shared with the main window and may, and the
    // window's isolate loads the whole program anyway, so the D18 guarantee
    // is the early return above, not the imports.
    for (final path in [
      'lib/settings_window_app.dart',
      'lib/services/settings_window/remote_settings.dart',
      'lib/services/settings_window/settings_window_link.dart',
    ]) {
      expect(readSource(path), isNot(contains('klabautermann_core')));
    }
  });

  group('macOS', () {
    final window = runners['macos']!;

    test('the window is a second engine on the compatibility controller, '
        'without plugins', () {
      expect(window, contains('let project = FlutterDartProject()'));
      expect(
        window,
        contains('project.dartEntrypointArguments = [Self.windowArgument]'),
      );
      expect(
        window,
        contains('KlabautermannFlutterViewController(project: project)'),
      );
      expect(
        window,
        isNot(contains(RegExp(r'\bFlutterViewController\('))),
        reason: 'a stock controller drops both compatibility fixes',
      );
      expect(window, isNot(contains('RegisterGeneratedPlugins')));
    });

    test('closing hides the window and tells Dart', () {
      final start = window.indexOf('func windowShouldClose(');
      final body = window.substring(start, window.indexOf('\n  }\n', start));
      expect(body, contains('sender.orderOut(nil)'));
      expect(body, contains('control.invokeMethod("closed", arguments: nil)'));
      expect(body, contains('return false'));
    });

    test('the main window installs the host and closes it with itself', () {
      final main = readSource('macos/Runner/MainFlutterWindow.swift');
      expect(
        main,
        contains(
          RegExp(
            r'settingsWindow = SettingsWindowHost\(\s*mainWindow: self,\s*'
            r'messenger: flutterViewController\.engine\.binaryMessenger\)',
          ),
        ),
      );
      expect(
        main,
        contains(
          RegExp(
            r'override func close\(\) \{\s*settingsWindow\?\.close\(\)\s*'
            r'super\.close\(\)',
          ),
        ),
      );
    });

    test('Xcode compiles SettingsWindow.swift into the Runner target', () {
      final project = readSource(_projectPath);
      const name = 'SettingsWindow.swift';
      final fileId = xcodeFileReferenceId(project, name);
      expect(fileId, isNotNull, reason: '$name has no file reference');
      expect(
        project,
        contains(
          '$fileId /* $name */ = {isa = PBXFileReference; '
          'lastKnownFileType = sourcecode.swift;',
        ),
      );
      expect(
        xcodeListEntries(project, xcodeRunnerGroupId(project), 'children'),
        contains(fileId),
      );

      final buildFiles = RegExp(
        '([0-9A-F]{24}) /\\* $name in Sources \\*/ = '
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
  });

  group('Linux', () {
    final window = runners['linux']!;

    test('the window is a second engine without plugins', () {
      expect(window, contains('fl_dart_project_new()'));
      expect(
        window,
        contains('char* arguments[] = {const_cast<char*>(kWindowArgument)'),
      );
      expect(
        window,
        contains('fl_dart_project_set_dart_entrypoint_arguments(project'),
      );
      expect(window, contains('fl_view_new(project)'));
      expect(window, isNot(contains('fl_register_plugins')));
    });

    test('its own delete-event handler hides it before the view can ask '
        'Dart to quit the app', () {
      final handler = window.indexOf(
        'g_signal_connect(window, "delete-event", G_CALLBACK(window_delete_cb)',
      );
      expect(handler, isNonNegative);
      expect(window.indexOf('fl_view_new(project)'), greaterThan(handler));

      final start = window.indexOf('gboolean window_delete_cb(');
      final body = window.substring(start, window.indexOf('\n}\n', start));
      expect(body, contains('gtk_widget_hide(widget)'));
      expect(body, contains('"closed"'));
      expect(body, contains('return TRUE;'));
    });

    test('the link reaches the window before its engine starts', () {
      final handler = window.indexOf(
        'fl_binary_messenger_set_message_handler_on_channel(\n'
        '      host->window_messenger, kLinkChannel, window_link_cb',
      );
      expect(handler, isNonNegative);
      expect(
        window.indexOf('gtk_widget_realize(GTK_WIDGET(view))'),
        greaterThan(handler),
      );
    });

    test('the main window installs the host after its plugins', () {
      final app = readSource('linux/runner/my_application.cc');
      final plugins = app.indexOf('fl_register_plugins(');
      final install = app.indexOf(
        'settings_window_install(GTK_APPLICATION(application), window, view);',
      );
      expect(plugins, isNonNegative);
      expect(install, greaterThan(plugins));
      expect(app, contains('#include "settings_window.h"'));
      expect(app, contains('window_title_apply(window, "Klabautermann")'));
    });

    test('CMake builds the window and its title code', () {
      final cmake = readSource('linux/runner/CMakeLists.txt');
      final executable = cmake.substring(
        cmake.indexOf('add_executable(\${BINARY_NAME}'),
      );
      final sources = executable.substring(0, executable.indexOf(')'));
      expect(sources, contains('"settings_window.cc"'));
      expect(sources, contains('"window_title.cc"'));
    });
  });

  group('Windows', () {
    final window = runners['windows']!;

    test('the window is a second engine without plugins', () {
      expect(
        window,
        contains('project_.set_dart_entrypoint_arguments({kWindowArgument})'),
      );
      expect(
        window,
        contains('std::make_unique<flutter::FlutterViewController>('),
      );
      expect(window, isNot(contains('RegisterPlugins(')));
    });

    test('WM_CLOSE hides the window before Flutter sees it', () {
      final close = window.indexOf('if (message == WM_CLOSE) {');
      final flutter = window.indexOf('HandleTopLevelWindowProc(');
      expect(close, isNonNegative);
      expect(flutter, greaterThan(close));
      final body = window.substring(close, flutter);
      expect(body, contains('ShowWindow(hwnd, SW_HIDE);'));
      expect(body, contains('on_hidden_();'));
      expect(body, contains('return 0;'));
      expect(window, contains('control_->InvokeMethod("closed", nullptr);'));
    });

    test('the main window installs the host after its plugins and drops it '
        'before its engine', () {
      final source = readSource('windows/runner/flutter_window.cpp');
      final plugins = source.indexOf('RegisterPlugins(');
      final install = source.indexOf(
        'settings_window_ = std::make_unique<SettingsWindowHost>(',
      );
      expect(plugins, isNonNegative);
      expect(install, greaterThan(plugins));

      final destroy = source.substring(
        source.indexOf('void FlutterWindow::OnDestroy() {'),
      );
      expect(
        destroy.indexOf('settings_window_ = nullptr;'),
        lessThan(destroy.indexOf('flutter_controller_ = nullptr;')),
      );

      // Members are destroyed in reverse order: the host goes first.
      final header = readSource('windows/runner/flutter_window.h');
      expect(
        header.indexOf('std::unique_ptr<SettingsWindowHost> settings_window_;'),
        greaterThan(
          header.indexOf(
            'std::unique_ptr<flutter::FlutterViewController> '
            'flutter_controller_;',
          ),
        ),
      );
    });

    test('CMake builds the window', () {
      final cmake = readSource('windows/runner/CMakeLists.txt');
      final executable = cmake.substring(
        cmake.indexOf('add_executable(\${BINARY_NAME} WIN32'),
      );
      final sources = executable.substring(0, executable.indexOf(')'));
      expect(sources, contains('"settings_window.cpp"'));
    });

    test('the window sources stay ASCII for MSVC', () {
      for (final path in [
        'windows/runner/settings_window.h',
        'windows/runner/settings_window.cpp',
      ]) {
        expect(
          readSource(path).codeUnits.every((unit) => unit < 0x80),
          isTrue,
          reason: path,
        );
      }
    });
  });
}
