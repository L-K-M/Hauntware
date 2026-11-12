// Single instance with file-open forwarding on Linux and Windows
// (planchette/ANALYSIS.md I1): the second launch hands its documents to
// the running instance, which raises the window that owns them.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Linux runs one instance and forwards document arguments to it', () {
    final runner = _read('linux/runner/my_application.cc');
    expect(runner, isNot(contains('G_APPLICATION_NON_UNIQUE')));
    expect(
      runner,
      matches(
        RegExp(
          r'G_APPLICATION_HANDLES_COMMAND_LINE\s*\|\s*'
          r'G_APPLICATION_HANDLES_OPEN',
        ),
      ),
    );
    // local_command_line leaves the arguments to GApplication, which
    // forwards them to the primary instance's command-line handler.
    final localCommandLine = RegExp(
      r'my_application_local_command_line\([\s\S]*?\n}',
    ).firstMatch(runner)!.group(0)!;
    expect(localCommandLine, contains('return FALSE;'));
    // A second activation raises a visible window rather than opening a
    // new engine or re-showing a window the user closed.
    expect(runner, contains('gtk_window_present(visible);'));
    expect(runner, contains('gtk_widget_get_visible'));
    // The own launch is told from a forward by where it came from, never
    // by comparing arguments: the same file can be opened twice.
    expect(runner, contains('g_application_command_line_get_is_remote'));
    expect(runner, isNot(contains('g_strv_equal')));
    // command-line and open deliveries resolve against the sender's
    // directory and reach Dart over the documents channel.
    expect(runner, contains('my_application_command_line'));
    expect(runner, contains('my_application_open'));
    expect(runner, contains('g_application_command_line_get_cwd'));
    expect(runner, contains('planchette/documents'));

    final packaging = _read('../../scripts/package-linux.sh');
    expect(packaging, contains(r'Exec=$2 %F'));
    expect(packaging, contains('MimeType=text/plain;'));
  });

  test('Windows runs one instance and forwards document arguments to it', () {
    final instance = _read('windows/runner/single_instance.cpp');
    expect(
      instance,
      allOf([
        contains(r'L"Local\\ch.lkmc.planchette.single-instance-v1"'),
        contains(r'L"ch.lkmc.planchette.single-instance-v1"'),
        contains('ClaimOrForwardInstance'),
        contains('CreateMutexW'),
        contains('WaitForSingleObject'),
        contains('MarkPrimaryWindow'),
        contains('GetPropW'),
        contains('PresentVisibleApplicationWindow'),
        contains('WM_COPYDATA'),
        contains('kOpenDocumentsCopyDataId'),
        contains('AllowSetForegroundWindow'),
      ]),
    );
    // MSVC reads the runner sources as the system code page.
    for (final source in [
      'windows/runner/single_instance.h',
      'windows/runner/single_instance.cpp',
      'windows/runner/open_documents.h',
      'windows/runner/open_documents.cpp',
    ]) {
      expect(
        _read(source).runes.every((rune) => rune < 0x80),
        isTrue,
        reason: '$source must stay ASCII for MSVC',
      );
    }

    final main = _read('windows/runner/main.cpp');
    // A missing call has index -1, which would pass the ordering check.
    expect(main, contains('ClaimOrForwardInstance'));
    expect(
      main.indexOf('ClaimOrForwardInstance'),
      lessThan(main.indexOf('FlutterWindow window(project)')),
    );

    final window = _read('windows/runner/flutter_window.cpp');
    expect(window, contains('MarkPrimaryWindow(GetHandle())'));
    expect(window, contains('HandleWindowMessage'));

    final cmake = _read('windows/runner/CMakeLists.txt');
    expect(
      cmake,
      allOf(
        contains('"open_documents.cpp"'),
        contains('"single_instance.cpp"'),
      ),
    );
  });

  test('Windows forwarding requires a bounded delivery acknowledgement', () {
    final instance = _read('windows/runner/single_instance.cpp');
    expect(instance, contains('SendMessageTimeoutW('));
    expect(instance, isNot(contains('SendMessageW(')));
    expect(instance, contains('SMTO_ABORTIFHUNG | SMTO_BLOCK'));
    expect(instance, contains('kDocumentDeliveryTimeoutMs = 5000'));
    expect(instance, contains('delivered != 0 && accepted == TRUE'));
    expect(
      instance,
      matches(
        RegExp(
          r'return forwarded\s*\? InstanceDisposition::kForwarded\s*'
          r': InstanceDisposition::kFailed;',
        ),
      ),
    );
    expect(_read('windows/runner/main.cpp'), contains('MessageBoxW('));
  });

  test('the runners speak the channel the Dart intake listens on', () {
    expect(
      _read('lib/services/open_documents.dart'),
      contains("MethodChannel('planchette/documents')"),
    );
    for (final source in [
      'linux/runner/my_application.cc',
      'windows/runner/open_documents.cpp',
      'macos/Runner/AppDelegate.swift',
    ]) {
      expect(_read(source), contains('planchette/documents'));
    }
  });
}

String _read(String path) => File(path).readAsStringSync();
