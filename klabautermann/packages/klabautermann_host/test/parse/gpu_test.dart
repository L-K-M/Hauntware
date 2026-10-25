import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

/// HW-03: the `gpu` payload.
void main() {
  group('parseGpu', () {
    test('reads nvidia-smi rows, a name with a comma included, and amdgpu '
        'cards', () {
      final result = parseGpu(
        [
          '== nvidia ==',
          'rc=0',
          '0, NVIDIA GeForce RTX 3080, 12, 1024, 10240, 45, 35.20, 320.00',
          '1, Tesla T4, PG183, [N/A], 15, 0, 15360, 38, [N/A], 70.00',
          '== amdgpu ==',
          'card1|37|1073741824|8589934592|52000|41000000',
          'card2|0||||',
        ].join('\n'),
        ParseContext.standard,
      );

      expect(result.warnings, isEmpty);
      final devices = result.value.devices;
      expect(
        [for (final d in devices) d.id],
        ['nvidia0', 'nvidia1', 'card1', 'card2'],
      );
      final rtx = devices.first;
      expect(rtx.source, GpuSource.nvidia);
      expect(rtx.name, 'NVIDIA GeForce RTX 3080');
      expect(rtx.busyPercent, 12);
      expect(rtx.memoryUsedBytes, 1024 * 1024 * 1024);
      expect(rtx.memoryTotalBytes, 10 * 1024 * 1024 * 1024);
      expect(rtx.celsius, 45);
      expect(rtx.powerWatts, closeTo(35.2, 1e-9));
      expect(rtx.powerLimitWatts, 320);

      final tesla = devices[1];
      expect(tesla.name, 'Tesla T4, PG183, [N/A]');
      expect(tesla.powerWatts, isNull);

      final amd = devices[2];
      expect(amd.source, GpuSource.amdgpu);
      expect(amd.name, isNull);
      expect(amd.busyPercent, 37);
      expect(amd.memoryUsedBytes, 1073741824);
      expect(amd.memoryTotalBytes, 8589934592);
      expect(amd.celsius, 52);
      expect(amd.powerWatts, 41);
      expect(amd.powerLimitWatts, isNull);
      expect(devices.last.memoryTotalBytes, isNull);
      expect(devices.last.celsius, isNull);
    });

    test('a failed nvidia-smi keeps its message and lists no NVIDIA GPU', () {
      final result = parseGpu(
        [
          '== nvidia ==',
          'rc=9',
          'NVIDIA-SMI has failed because it couldn\'t communicate with the '
              'NVIDIA driver.',
          'Make sure that the latest NVIDIA driver is installed.',
          '== amdgpu ==',
        ].join('\n'),
        ParseContext.standard,
      );

      expect(result.warnings, isEmpty);
      expect(result.value.devices, isEmpty);
      expect(
        result.value.nvidiaFailure,
        'NVIDIA-SMI has failed because it couldn\'t communicate with the '
        'NVIDIA driver.',
      );
    });

    test('a host without GPUs reads empty; malformed rows warn', () {
      expect(
        parseGpu(
          '== nvidia ==\n== amdgpu ==\n',
          ParseContext.standard,
        ).value.devices,
        isEmpty,
      );

      final result = parseGpu(
        '== nvidia ==\nrc=0\nx, y\n== amdgpu ==\ncard0|busy||||\n',
        ParseContext.standard,
      );
      expect(result.warnings, hasLength(2));
      expect(result.value.devices, isEmpty);
    });
  });
}
