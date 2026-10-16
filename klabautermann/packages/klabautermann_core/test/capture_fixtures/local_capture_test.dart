// Fixture capture against the real program in dash (03 §6.5). Tagged
// `shell`; skipped when dash is not installed. Nothing is written: a
// capture of this machine describes the build sandbox, not a server.
@Tags(['shell'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

import '../../tool/src/fixture_capture.dart';
import '../../tool/src/local_sampler.dart';
import '../../tool/src/redaction.dart';

void main() {
  final dash = findOnCapturePath('dash');

  test('captures every collector once and redacts procs argv', () async {
    final env = runEnvironment(
      home: Directory.systemTemp.path,
      user: Platform.environment['USER'] ?? 'nobody',
    );
    final capture = await captureLocal(SamplerLaunch.stdinShell(dash!), env);
    expect(capture.sections.keys, unorderedEquals(kFixtureCollectors));
    for (final c in [Collector.overview, Collector.core, Collector.procs]) {
      expect(capture.sections[c]!.status, SectionStatus.ok, reason: c.name);
    }
    expect(capture.profile.kernelSys, isNotNull);

    final files = renderFixtureFiles(
      capture,
      Redactor(const RedactionLiterals()),
      capturedAt: DateTime.now(),
    ).files;
    final procs = parseProcs(
      utf8.decode(files['procs.txt']!),
      ParseContext.standard,
    ).value;
    expect(procs.argvSource, ProcsArgvSource.cmdline);
    expect(procs.processes, isNotEmpty);
    // An argument that held newlines reads one placeholder per line.
    expect(
      procs.processes.expand((p) => p.argv?.skip(1) ?? const <String>[]),
      everyElement(
        predicate<String>(
          (a) => a.split('\n').every((l) => l.isEmpty || l == kRedacted),
        ),
      ),
    );
  }, skip: dash == null ? 'dash is not installed' : false);
}
