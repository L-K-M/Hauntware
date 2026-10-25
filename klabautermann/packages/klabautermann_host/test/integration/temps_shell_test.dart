// The `temps` fragment through a real shell (HW-01), over a stand-in
// sysfs tree: the fragment's `/sys/class/` paths point at a temporary
// directory. Tagged `shell`; a shell that is not installed gets no tests.
@Tags(['shell'])
library;

import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

final _shells = {
  for (final name in ['dash', 'bash'])
    for (final dir in ['/bin', '/usr/bin'])
      if (File('$dir/$name').existsSync()) name: '$dir/$name',
};

Future<void> _write(Directory root, String path, String text) async {
  final file = File('${root.path}/$path');
  await file.parent.create(recursive: true);
  await file.writeAsString(text);
}

/// Runs `c_temps` under [shell] with its sysfs classes under [root].
Future<String> _temps(String shell, Directory root) async {
  final fragment = collectorFragments[Collector.temps]!.replaceAll(
    '/sys/class/',
    '${root.path}/',
  );
  final result = await Process.run(shell, [
    '-c',
    "NL='\n'\n$fragment\nc_temps\nprintf '%s:%s' \"\$st\" \"\$o\"",
  ]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  expect(result.stderr, isEmpty);
  return result.stdout as String;
}

void main() {
  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    test('$name: temps reads each hwmon input with its limits and label, '
        'skips one it cannot read, and lists the thermal zones', () async {
      final root = await Directory.systemTemp.createTemp('klab-temps-');
      addTearDown(() => root.delete(recursive: true));
      await _write(root, 'hwmon/hwmon2/name', 'coretemp\n');
      await _write(root, 'hwmon/hwmon2/temp1_input', '48000\n');
      await _write(root, 'hwmon/hwmon2/temp1_max', '84000\n');
      await _write(root, 'hwmon/hwmon2/temp1_crit', '100000\n');
      await _write(root, 'hwmon/hwmon2/temp1_label', 'Package id 0\n');
      // An unwired input: reading it fails, as EIO would.
      await Directory('${root.path}/hwmon/hwmon2/temp2_input').create();
      await _write(root, 'hwmon/hwmon3/name', 'nvme\n');
      await _write(root, 'hwmon/hwmon3/temp1_input', '38850\n');
      // A chip without temperature inputs adds nothing.
      await _write(root, 'hwmon/hwmon4/name', 'BAT0\n');
      await _write(root, 'thermal/thermal_zone0/temp', '27800\n');
      await _write(root, 'thermal/thermal_zone0/type', 'acpitz\n');

      final out = await _temps(shell, root);
      expect(out.split('\n'), [
        'ok:== hwmon ==',
        'hwmon2|coretemp|temp1|48000|84000|100000|Package id 0',
        'hwmon3|nvme|temp1|38850|||',
        '== thermal ==',
        'thermal_zone0|27800|acpitz',
      ]);

      final parsed = parseTemps(out.substring(3), ParseContext.standard);
      expect(parsed.warnings, isEmpty);
      expect(parsed.value.sensors, hasLength(2));
    });

    test('$name: a host without either class sends empty blocks', () async {
      final root = await Directory.systemTemp.createTemp('klab-temps-');
      addTearDown(() => root.delete(recursive: true));

      expect(await _temps(shell, root), 'ok:== hwmon ==\n== thermal ==');
    });
  }
}
