// The unit-file check through the host's real `systemd-analyze` (03
// §8.5): a valid unit passes and a broken one fails. A stand-in `man`
// first on PATH fails every lookup, as on a host without the unit's
// man pages, which must not fail the check. Tagged `shell`; a host
// without systemd-analyze, or with one older than
// kVerifyAsUnitSystemd, gets no tests.
@Tags(['shell'])
library;

import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

/// The host's systemd major, or null without `systemd-analyze`.
int? _systemdVersion() {
  try {
    final result = Process.runSync('systemd-analyze', ['--version']);
    if (result.exitCode != 0) return null;
    final match = RegExp(r'^systemd (\d+)').firstMatch(result.stdout as String);
    return match == null ? null : int.parse(match.group(1)!);
  } on ProcessException {
    return null;
  }
}

void main() {
  final version = _systemdVersion();
  final skip = version == null
      ? 'systemd-analyze is not installed'
      : version < kVerifyAsUnitSystemd
      ? 'systemd $version cannot verify a file as another unit'
      : null;

  late Directory dir;
  late Map<String, String> environment;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('verify-unit-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final bin = Directory('${dir.path}/bin')..createSync();
    final man = File('${bin.path}/man')
      ..writeAsStringSync('#!/bin/sh\nexit 16\n');
    Process.runSync('chmod', ['+x', man.path]);
    environment = {'PATH': '${bin.path}:${Platform.environment['PATH']}'};
  });

  /// Runs the check on [text] as `app.service`; its exit status.
  int verify(String text) {
    final temp = '${dir.path}/.app.service.klabautermann-tmp-feedfacefeedface';
    File(temp).writeAsStringSync(text);
    final argv = EditCommands.verifyUnit(temp, 'app.service');
    final result = Process.runSync(
      argv.first,
      argv.sublist(1),
      environment: environment,
    );
    return result.exitCode;
  }

  test('a unit naming man pages the host lacks still passes', () {
    expect(
      verify(
        '[Unit]\nDocumentation=man:klabautermann-absent(8)\n'
        '[Service]\nExecStart=/bin/true\n',
      ),
      0,
    );
  }, skip: skip);

  test('a unit whose command is not executable fails', () {
    expect(
      verify('[Service]\nExecStart=/nonexistent/klabautermann\n'),
      isNot(0),
    );
  }, skip: skip);
}
