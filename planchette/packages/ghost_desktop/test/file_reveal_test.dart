// Moved from Poltergeist's file_manager_reveal_test.dart with the
// revealer; the timeout and Finder-detail cases come from Seance's
// local_reveal.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_desktop/ghost_desktop.dart';

void main() {
  late List<(String, List<String>, Duration?)> calls;

  /// Exits with [exitCodes] (0 by default); a [missing] tool cannot
  /// start; a [silent] one gives no answer within its timeout.
  GhostRevealProcessRunner runner(
    Map<String, int> exitCodes, {
    Set<String> missing = const {},
    Set<String> silent = const {},
    String stderr = '',
  }) => (executable, arguments, {timeout}) async {
    calls.add((executable, arguments, timeout));
    if (missing.contains(executable)) {
      throw ProcessException(executable, arguments, 'not found', 2);
    }
    if (silent.contains(executable)) return null;
    return (exitCode: exitCodes[executable] ?? 0, stderr: stderr);
  };

  List<String> executables() => [for (final (exe, _, _) in calls) exe];

  setUp(() => calls = []);

  test('macOS reveals through Finder with open -R', () async {
    final revealer = GhostFileRevealer(
      run: runner({}),
      operatingSystem: 'macos',
    );
    final result = await revealer.reveal('/Users/me/notes.txt');
    expect(result.outcome, GhostRevealOutcome.shown);
    expect(calls.single.$1, '/usr/bin/open');
    expect(calls.single.$2, ['-R', '/Users/me/notes.txt']);
  });

  test('a failed Finder reveal carries what open said', () async {
    final revealer = GhostFileRevealer(
      run: runner({'/usr/bin/open': 1}, stderr: ' no such file \n'),
      operatingSystem: 'macos',
    );
    final result = await revealer.reveal('/Users/me/gone.txt');
    expect(result.outcome, GhostRevealOutcome.failed);
    expect(result.detail, 'no such file');
  });

  test('Linux asks FileManager1.ShowItems with the file URI', () async {
    final revealer = GhostFileRevealer(
      run: runner({}),
      operatingSystem: 'linux',
    );
    expect((await revealer.reveal('/home/me/a b.txt')).shown, isTrue);
    final (exe, args, timeout) = calls.single;
    expect(exe, 'dbus-send');
    expect(args, contains('org.freedesktop.FileManager1.ShowItems'));
    expect(args, contains('array:string:file:///home/me/a%20b.txt'));
    // A bus that never answers must not hang the action.
    expect(timeout, GhostFileRevealer.busTimeout);
  });

  test('Linux falls back to opening the parent folder', () async {
    final revealer = GhostFileRevealer(
      run: runner({'dbus-send': 1}),
      operatingSystem: 'linux',
    );
    expect((await revealer.reveal('/home/me/docs/report.pdf')).shown, isTrue);
    expect(calls.last.$1, 'xdg-open');
    expect(calls.last.$2, ['/home/me/docs']);
  });

  test('Linux keeps a comma inside the one ShowItems item', () async {
    // dbus-send splits `array:string:` values on commas with no escape,
    // so a bare comma would ask for two items that do not exist.
    final revealer = GhostFileRevealer(
      run: runner({}),
      operatingSystem: 'linux',
    );
    expect((await revealer.reveal('/home/me/a,b.txt')).shown, isTrue);
    final (_, args, _) = calls.single;
    expect(args, contains('array:string:file:///home/me/a%2Cb.txt'));
  });

  test('Linux falls back to xdg-open when dbus-send is missing', () async {
    final revealer = GhostFileRevealer(
      run: runner({}, missing: {'dbus-send'}),
      operatingSystem: 'linux',
    );
    expect((await revealer.reveal('/home/me/docs/report.pdf')).shown, isTrue);
    expect(calls.last.$1, 'xdg-open');
    expect(calls.last.$2, ['/home/me/docs']);
  });

  test('Linux falls back to gio when xdg-open cannot open it either', () async {
    final revealer = GhostFileRevealer(
      run: runner({'dbus-send': 1}, missing: {'xdg-open'}),
      operatingSystem: 'linux',
    );
    expect((await revealer.reveal('/home/me/docs/report.pdf')).shown, isTrue);
    expect(calls.last.$1, 'gio');
    expect(calls.last.$2, ['open', '/home/me/docs']);
  });

  test('Linux opens no folder when the bus stays silent', () async {
    // The call may still be answered; opening the folder as well could
    // show it twice.
    final revealer = GhostFileRevealer(
      run: runner({}, silent: {'dbus-send'}),
      operatingSystem: 'linux',
    );
    final result = await revealer.reveal('/home/me/docs/report.pdf');
    expect(result.outcome, GhostRevealOutcome.unanswered);
    expect(executables(), ['dbus-send']);
  });

  test('Linux reports failure when nothing opens the folder', () async {
    final revealer = GhostFileRevealer(
      run: runner({'dbus-send': 1, 'xdg-open': 3}, missing: {'gio'}),
      operatingSystem: 'linux',
    );
    final result = await revealer.reveal('/home/me/docs/report.pdf');
    expect(result.outcome, GhostRevealOutcome.failed);
    expect(executables(), ['dbus-send', 'xdg-open', 'gio']);
  });

  test('Windows quotes the path so a comma cannot split it', () async {
    // Explorer parses its own command line and splits /select's target
    // on commas unless it is quoted; Dart would escape a quote inside an
    // argument (\"), so the whole line rides in the executable slot,
    // which Dart hands to CreateProcessW verbatim once it holds a quote.
    final revealer = GhostFileRevealer(
      run: runner({}),
      operatingSystem: 'windows',
    );
    expect((await revealer.reveal(r'C:\dir\a,b.txt')).shown, isTrue);
    expect(calls.single.$1, r'explorer.exe /select,"C:\dir\a,b.txt"');
    expect(calls.single.$2, isEmpty);
  });

  test('Windows reports failure when Explorer cannot start', () async {
    final revealer = GhostFileRevealer(
      run: runner({}, missing: {r'explorer.exe /select,"C:\x.txt"'}),
      operatingSystem: 'windows',
    );
    expect((await revealer.reveal(r'C:\x.txt')).shown, isFalse);
  });

  test('Windows selects the item in Explorer whatever its exit code', () async {
    final revealer = GhostFileRevealer(
      run: runner({r'explorer.exe /select,"C:\Users\me\file.txt"': 1}),
      operatingSystem: 'windows',
    );
    expect((await revealer.reveal(r'C:\Users\me\file.txt')).shown, isTrue);
    expect(calls.single.$1, startsWith('explorer.exe '));
  });

  test('other platforms are unsupported and never spawn anything', () async {
    final revealer = GhostFileRevealer(
      run: runner({}),
      operatingSystem: 'android',
    );
    expect(revealer.supported, isFalse);
    expect((await revealer.reveal('/sdcard/x')).shown, isFalse);
    expect(calls, isEmpty);
  });

  group('the default runner', () {
    final posix = Platform.isLinux || Platform.isMacOS;

    test('kills a process still running at its timeout', () async {
      final result = await runGhostRevealProcess('sleep', [
        '5',
      ], timeout: const Duration(milliseconds: 100));
      expect(result, isNull);
    }, skip: posix ? false : 'needs a POSIX sleep');

    test('reports the exit code and stderr within its timeout', () async {
      final result = await runGhostRevealProcess('sh', [
        '-c',
        'echo oops >&2; exit 3',
      ], timeout: const Duration(seconds: 5));
      expect(result?.exitCode, 3);
      expect(result?.stderr.trim(), 'oops');
    }, skip: posix ? false : 'needs a POSIX shell');
  });
}
