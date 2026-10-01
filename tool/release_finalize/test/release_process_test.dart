// Release tooling stays outside the shipped application.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../lib/release_process.dart';

void main() {
  late Directory sandbox;
  const runner = IoReleaseProcessRunner();

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync(
      'poltergeist-release-process-test-',
    );
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('captures text command output', () async {
    final script = _writeScript(sandbox, "stdout.write('ready');");

    final result = await runner.run(Platform.resolvedExecutable, [script.path]);

    expect(result.exitCode, 0);
    expect(result.standardOutput, 'ready');
  });

  test('streams binary command output to a file', () async {
    final script = _writeScript(
      sandbox,
      'stdout.add(const <int>[0, 255, 10]);',
    );
    final output = File(p.join(sandbox.path, 'output.bin'));

    final result = await runner.runToFile(Platform.resolvedExecutable, [
      script.path,
    ], output: output);

    expect(result.exitCode, 0);
    expect(output.readAsBytesSync(), [0, 255, 10]);
  });

  test('distinguishes an early exit from a running GUI process', () async {
    final exits = _writeScript(sandbox, 'exitCode = 3;');
    final waits = _writeScript(
      sandbox,
      'await Future<void>.delayed(const Duration(seconds: 30));',
      name: 'waits.dart',
    );

    final early = await runner.observeLaunch(Platform.resolvedExecutable, [
      exits.path,
    ], observation: const Duration(seconds: 2));
    final running = await runner.observeLaunch(Platform.resolvedExecutable, [
      waits.path,
    ], observation: const Duration(milliseconds: 100));

    expect(early.status, ReleaseLaunchStatus.exited);
    expect(early.exitCode, 3);
    expect(running.status, ReleaseLaunchStatus.remainedRunning);
  });
}

File _writeScript(
  Directory directory,
  String body, {
  String name = 'script.dart',
}) {
  return File(p.join(directory.path, name))..writeAsStringSync(
    "import 'dart:io';\nFuture<void> main() async {$body}\n",
  );
}
