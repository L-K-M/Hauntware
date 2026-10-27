import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_core/seance_core.dart';
import 'package:seance_terminal/seance_terminal.dart';

/// Runs each setup snippet from docs/SHELL_INTEGRATION.md in a real shell
/// and feeds what it prints to the engine, as a server's PTY would.
void main() {
  final guide = File('../../docs/SHELL_INTEGRATION.md').readAsStringSync();

  for (final (shell, args) in [
    ('bash', ['--norc', '--noprofile', '-i']),
    ('zsh', ['-f', '-i']),
  ]) {
    test('the $shell snippet reports its directory and prompt', () async {
      final root = Directory.systemTemp.createTempSync('seance-snippet-');
      addTearDown(() => root.deleteSync(recursive: true));
      // Sourced like a startup file: an interactive zsh would run a typed
      // comment line as a command.
      final startup = File('${root.path}/rc')
        ..writeAsStringSync(_snippet(guide, shell));
      // Characters a URL must escape, and one beyond ASCII.
      final directory = Directory('${root.path}/a b%41?#é')..createSync();

      final engine = XtermTerminalEngine();
      addTearDown(engine.dispose);
      final statuses = <int>[];
      engine.shellIntegration.addListener(() {
        final status = engine.shellIntegration.value.lastExitCode;
        if (status != null) statuses.add(status);
      });
      engine.feed(
        await _interactive(shell, args, root, [
          ". '${startup.path}'",
          "cd '${directory.path}'",
          'false',
          'exit 0',
        ]),
      );

      expect(engine.workingDirectory.value, directory.path);
      expect(engine.shellIntegration.value.shell, RemoteShellKind.posix);
      expect(statuses, [0, 0, 1], reason: 'sourcing, cd, false');
      if (shell == 'bash') {
        // An interactive bash saves, and trims, its history on exit.
        expect(
          File(_history(root)).existsSync(),
          isTrue,
          reason: "the developer's ~/.bash_history is left alone",
        );
      }
    }, skip: _missing(shell));
  }
}

/// The fenced block under the guide's heading for [shell].
String _snippet(String guide, String shell) {
  final block = RegExp(
    '^```$shell\\n(.*?)^```',
    multiLine: true,
    dotAll: true,
  ).firstMatch(guide);
  if (block == null) fail('docs/SHELL_INTEGRATION.md has no $shell snippet');
  return block.group(1)!;
}

/// Everything an interactive [shell] prints, prompts included, for [lines]
/// typed at it. Prompt hooks run for piped input too, so no PTY is needed.
/// Its history goes to [root], not the developer's.
Future<Uint8List> _interactive(
  String shell,
  List<String> args,
  Directory root,
  List<String> lines,
) async {
  final process = await Process.start(
    'sh',
    ['-c', r'exec "$0" "$@" 2>&1', shell, ...args],
    environment: {'HISTFILE': _history(root)},
  );
  process.stdin.write(lines.map((line) => '$line\n').join());
  await process.stdin.close();
  final output = BytesBuilder(copy: false);
  await process.stdout.forEach(output.add);
  await process.stderr.drain<void>();
  final exitCode = await process.exitCode;
  printOnFailure(utf8.decode(output.toBytes(), allowMalformed: true));
  expect(exitCode, 0);
  return output.takeBytes();
}

/// Where the shells under test keep their history.
String _history(Directory root) => '${root.path}/history';

/// Why [shell] cannot run here, or null when it can.
String? _missing(String shell) {
  if (!Platform.isLinux && !Platform.isMacOS) return 'POSIX shells only';
  try {
    final probe = Process.runSync(shell, ['-c', 'exit 0']);
    return probe.exitCode == 0 ? null : '$shell does not run';
  } on ProcessException {
    return '$shell is not installed';
  }
}
