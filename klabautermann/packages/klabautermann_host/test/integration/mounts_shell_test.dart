// DSK-05 and DSK-14's read through real shells (03 §7.3), on this host:
// with findmnt on PATH where it is installed, and with a PATH that holds
// only `cat`, so the read falls back to /proc/self/mounts. Tagged
// `shell`; a shell that is not installed gets no tests.
@Tags(['shell'])
@TestOn('linux')
library;

import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

final _shells = {
  for (final name in ['dash', 'bash'])
    for (final dir in ['/bin', '/usr/bin'])
      if (File('$dir/$name').existsSync()) name: '$dir/$name',
};

Future<(String, MountsRead?)> _read(String shell, {String? path}) async {
  final argv = HostCommands.mounts();
  final r = await Process.run(
    shell,
    argv.sublist(1),
    environment: {'PATH': ?path},
  );
  expect(r.exitCode, 0, reason: '${r.stderr}');
  final stdout = r.stdout as String;
  return (stdout, parseMounts(stdout));
}

void main() {
  late Directory bin;

  setUp(() async {
    // A PATH with `cat` alone: no findmnt.
    bin = await Directory.systemTemp.createTemp('klab-mounts-');
    final cat = [
      '/usr/bin/cat',
      '/bin/cat',
    ].firstWhere((path) => File(path).existsSync());
    Link('${bin.path}/cat').createSync(cat);
  });

  tearDown(() => bin.delete(recursive: true));

  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    test('$name: the mounts include the root, as findmnt lists them where '
        'installed', () async {
      final (stdout, read) = await _read(shell);
      expect(read, isNotNull, reason: stdout);
      expect(read!.mountAt('/'), isNotNull);
      final hasFindmnt = [
        '/usr/bin/findmnt',
        '/bin/findmnt',
      ].any((path) => File(path).existsSync());
      expect(
        stdout.startsWith(
          hasFindmnt ? kMountsFindmntMarker : kMountsProcMarker,
        ),
        isTrue,
      );
    });

    test('$name: without findmnt the mounts come from /proc', () async {
      final (stdout, read) = await _read(shell, path: bin.path);
      expect(stdout.startsWith(kMountsProcMarker), isTrue, reason: stdout);
      expect(read!.mountAt('/'), isNotNull);
      expect(read.mountAt('/')!.options, isNotEmpty);
    });
  }
}
