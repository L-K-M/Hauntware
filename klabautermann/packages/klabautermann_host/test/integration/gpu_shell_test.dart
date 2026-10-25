// The `gpu` fragment through a real shell (HW-03): a stand-in
// `nvidia-smi` on PATH, and the fragment's `/sys/class/` paths pointed
// at a stand-in tree. Tagged `shell`; a shell that is not installed gets
// no tests.
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

/// Runs `c_gpu` under [shell] with its sysfs classes under [root] and,
/// when [nvidiaSmi] is set, a stand-in `nvidia-smi` running it.
Future<String> _gpu(String shell, Directory root, {String? nvidiaSmi}) async {
  final bin = Directory('${root.path}/bin')..createSync();
  if (nvidiaSmi != null) {
    final tool = File('${bin.path}/nvidia-smi')
      ..writeAsStringSync('#!/bin/sh\n$nvidiaSmi\n');
    await Process.run('chmod', ['0755', tool.path]);
  }
  final fragment = collectorFragments[Collector.gpu]!.replaceAll(
    '/sys/class/',
    '${root.path}/',
  );
  final result = await Process.run(
    shell,
    [
      '-c',
      "NL='\n'\n_HW_T=\nhw_qrun() { \"\$@\"; }\n$fragment\nc_gpu\n"
          "printf '%s:%s' \"\$st\" \"\$o\"",
    ],
    // A PATH without the host's own nvidia-smi.
    environment: {'PATH': '${bin.path}:/usr/bin:/bin'},
    includeParentEnvironment: false,
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  expect(result.stderr, isEmpty);
  return result.stdout as String;
}

void main() {
  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    test('$name: gpu asks nvidia-smi and reads each amdgpu card, skipping '
        'connectors and other drivers\' cards', () async {
      final root = await Directory.systemTemp.createTemp('klab-gpu-');
      addTearDown(() => root.delete(recursive: true));
      await _write(root, 'drm/card1/device/gpu_busy_percent', '37\n');
      await _write(root, 'drm/card1/device/mem_info_vram_used', '1024\n');
      await _write(root, 'drm/card1/device/mem_info_vram_total', '8192\n');
      await _write(
        root,
        'drm/card1/device/hwmon/hwmon3/temp1_input',
        '52000\n',
      );
      await _write(
        root,
        'drm/card1/device/hwmon/hwmon3/power1_average',
        '41000000\n',
      );
      // A connector, and an Intel card without gpu_busy_percent.
      await _write(root, 'drm/card1-DP-1/status', 'connected\n');
      await _write(root, 'drm/card0/device/vendor', '0x8086\n');

      final out = await _gpu(
        shell,
        root,
        nvidiaSmi: r'''
case "$*" in
  *--query-gpu=index,name,*--format=csv,noheader,nounits*)
    echo '0, NVIDIA GeForce RTX 3080, 12, 1024, 10240, 45, 35.20, 320.00' ;;
  *) exit 2 ;;
esac''',
      );
      expect(out.split('\n'), [
        'ok:== nvidia ==',
        'rc=0',
        '0, NVIDIA GeForce RTX 3080, 12, 1024, 10240, 45, 35.20, 320.00',
        '== amdgpu ==',
        'card1|37|1024|8192|52000|41000000',
      ]);
      final parsed = parseGpu(out.substring(3), ParseContext.standard);
      expect(parsed.warnings, isEmpty);
      expect(parsed.value.devices, hasLength(2));
    });

    test('$name: without nvidia-smi or cards both blocks are empty', () async {
      final root = await Directory.systemTemp.createTemp('klab-gpu-');
      addTearDown(() => root.delete(recursive: true));

      expect(await _gpu(shell, root), 'ok:== nvidia ==\n== amdgpu ==');
    });

    test('$name: a failing nvidia-smi sends its status and message', () async {
      final root = await Directory.systemTemp.createTemp('klab-gpu-');
      addTearDown(() => root.delete(recursive: true));

      final out = await _gpu(
        shell,
        root,
        nvidiaSmi: "echo 'NVIDIA-SMI has failed'; exit 9",
      );
      expect(out, 'ok:== nvidia ==\nrc=9\nNVIDIA-SMI has failed\n== amdgpu ==');
    });
  }
}
