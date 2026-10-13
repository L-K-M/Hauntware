// This executable and its tests stay under tool/ so the gate never ships.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import '../lib/license_gate.dart';

// The gate guards consumers of Séance code; the `SEANCE_LICENSE_GATE_V1`
// release marker lives on Poltergeist's client leg, so the pubspec scan
// stays scoped to that product's tree while the tool runs from the
// repository root.
const _scanRoot = 'poltergeist';

Future<void> main(List<String> arguments) async {
  final mode = switch (arguments) {
    [] => LicenseGateMode.release,
    ['--marker-only'] => LicenseGateMode.markerOnly,
    _ => null,
  };
  if (mode == null) {
    stderr.writeln(
      'usage: dart run tool/license_gate/bin/check.dart '
      '[--marker-only]',
    );
    exitCode = 64;
    return;
  }

  try {
    final report = await verifySeanceLicenseGate(
      repositoryRoot: Directory(_scanRoot),
      mode: mode,
    );
    stdout.writeln(
      'Séance license gate passed: ${report.declarationCount} declarations, '
      '${report.lockedSourceCount} locked path sources'
      '${report.matchedLicenseIds.isEmpty ? '' : ', licenses '
                '${report.matchedLicenseIds.join(', ')}'}',
    );
  } on LicenseGateException catch (error) {
    stderr.writeln('Séance license gate failed: $error');
    exitCode = 1;
  }
}
