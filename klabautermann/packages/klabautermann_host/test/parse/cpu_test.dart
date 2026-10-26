// CPU-07's parser: `lscpu -J` in its flat and hierarchic shapes and its
// older field order, and `/proc/cpuinfo` for a host without `lscpu`.
import 'dart:convert';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

String _read({
  String nproc = '4',
  List<Object?>? lscpu,
  List<String> cpuinfo = const [],
}) =>
    '$kCpuNprocMarker\n$nproc\n'
    '$kCpuLscpuMarker\n${lscpu == null ? '' : jsonEncode({'lscpu': lscpu})}\n'
    '$kCpuInfoMarker\n${cpuinfo.join('\n')}\n';

Map<String, Object?> _f(String name, String data, [List<Object?>? children]) =>
    {'field': '$name:', 'data': data, 'children': ?children};

void main() {
  test('util-linux 2.39 lists the topology after the model', () {
    final cpu = parseCpuTopology(
      _read(
        lscpu: [
          _f('Architecture', 'x86_64'),
          _f('CPU(s)', '16'),
          _f('Vendor ID', 'AuthenticAMD'),
          _f('Model name', 'AMD EPYC 7763 64-Core Processor'),
          _f('Thread(s) per core', '2'),
          _f('Core(s) per socket', '4'),
          _f('Socket(s)', '2'),
          _f('Flags', 'fpu vme de'),
        ],
      ),
    )!;
    expect(cpu.models, ['AMD EPYC 7763 64-Core Processor']);
    expect(cpu.vendor, 'AuthenticAMD');
    expect(cpu.logicalCpus, 16);
    expect(cpu.usableCpus, 4);
    expect(cpu.sockets, 2);
    expect(cpu.cores, 8);
    expect(cpu.threadsPerCore, 2);
  });

  test('older lscpu lists the topology before the model', () {
    final cpu = parseCpuTopology(
      _read(
        lscpu: [
          _f('CPU(s)', '8'),
          _f('Thread(s) per core', '2'),
          _f('Core(s) per socket', '4'),
          _f('Socket(s)', '1'),
          _f('Vendor ID', 'GenuineIntel'),
          _f('Model name', 'Intel(R) Core(TM) i7-4770 CPU @ 3.40GHz'),
        ],
      ),
    )!;
    expect(cpu.models, ['Intel(R) Core(TM) i7-4770 CPU @ 3.40GHz']);
    expect((cpu.sockets, cpu.cores, cpu.threadsPerCore), (1, 4, 2));
  });

  test('a big.LITTLE board adds each cluster and has no sockets', () {
    final cpu = parseCpuTopology(
      _read(
        nproc: '6',
        lscpu: [
          _f('CPU(s)', '6'),
          _f('Vendor ID', 'ARM'),
          _f('Model name', 'Cortex-A53'),
          _f('Thread(s) per core', '1'),
          _f('Core(s) per cluster', '4'),
          _f('Socket(s)', '-'),
          _f('Cluster(s)', '1'),
          _f('Model name', 'Cortex-A72'),
          _f('Thread(s) per core', '1'),
          _f('Core(s) per cluster', '2'),
          _f('Socket(s)', '-'),
          _f('Cluster(s)', '1'),
        ],
      ),
    )!;
    expect(cpu.models, ['Cortex-A53', 'Cortex-A72']);
    expect(cpu.sockets, isNull);
    expect(cpu.cores, 6);
    expect(cpu.threadsPerCore, 1);
  });

  test('hierarchic output is read through its children', () {
    final cpu = parseCpuTopology(
      _read(
        lscpu: [
          _f('CPU(s)', '4'),
          _f('Vendor ID', 'GenuineIntel', [
            _f('Model name', 'Intel(R) Xeon(R) Processor @ 2.10GHz', [
              _f('Thread(s) per core', '1'),
              _f('Core(s) per socket', '4'),
              _f('Socket(s)', '1'),
            ]),
          ]),
        ],
      ),
    )!;
    expect(cpu.models, ['Intel(R) Xeon(R) Processor @ 2.10GHz']);
    expect((cpu.sockets, cpu.cores, cpu.threadsPerCore), (1, 4, 1));
  });

  test('an unknown core count is unknown, not an undercount', () {
    final cpu = parseCpuTopology(
      _read(
        lscpu: [
          _f('Model name', 'Cortex-A53'),
          _f('Core(s) per cluster', '4'),
          _f('Cluster(s)', '1'),
          _f('Model name', 'Cortex-A72'),
          _f('Socket(s)', '-'),
        ],
      ),
    )!;
    expect(cpu.cores, isNull);
    expect(cpu.threadsPerCore, isNull);
  });

  test('without lscpu, /proc/cpuinfo places each CPU', () {
    final cpu = parseCpuTopology(
      _read(
        nproc: '',
        cpuinfo: [
          for (final (n, socket, core) in [
            (0, 0, 0),
            (1, 0, 1),
            (2, 0, 0),
            (3, 0, 1),
          ]) ...[
            'processor\t: $n',
            'model name\t: Intel(R) Celeron(R) J4125 CPU @ 2.00GHz',
            'physical id\t: $socket',
            'core id\t\t: $core',
          ],
        ],
      ),
    )!;
    expect(cpu.models, ['Intel(R) Celeron(R) J4125 CPU @ 2.00GHz']);
    expect(cpu.vendor, isNull);
    expect(cpu.usableCpus, isNull);
    expect(cpu.logicalCpus, 4);
    expect((cpu.sockets, cpu.cores, cpu.threadsPerCore), (1, 2, 2));
  });

  test('a figure lscpu leaves out falls back to /proc/cpuinfo', () {
    final cpu = parseCpuTopology(
      _read(
        lscpu: [_f('CPU(s)', '2'), _f('Model name', 'QEMU Virtual CPU')],
        cpuinfo: [
          for (final n in [0, 1]) ...[
            'processor\t: $n',
            'physical id\t: 0',
            'core id\t\t: $n',
          ],
        ],
      ),
    )!;
    expect(cpu.models, ['QEMU Virtual CPU']);
    expect((cpu.sockets, cpu.cores, cpu.threadsPerCore), (1, 2, 1));
  });

  test('a usable CPU count that is not one positive number is unknown', () {
    for (final nproc in ['0', '2\n3', 'x']) {
      expect(parseCpuTopology(_read(nproc: nproc))!.usableCpus, isNull);
    }
  });

  test('arm64 /proc/cpuinfo names no model and places no CPU', () {
    final cpu = parseCpuTopology(
      _read(cpuinfo: ['processor\t: 0', 'processor\t: 1']),
    )!;
    expect(cpu.models, isEmpty);
    expect(cpu.logicalCpus, 2);
    expect(cpu.sockets, isNull);
    expect(cpu.cores, isNull);
    expect(cpu.threadsPerCore, isNull);
  });

  test('lscpu that printed no JSON falls back to /proc/cpuinfo', () {
    final raw = _read(
      cpuinfo: ['processor\t: 0', 'cpu\t\t: POWER9 (raw), altivec supported'],
    ).replaceFirst('$kCpuLscpuMarker\n', '$kCpuLscpuMarker\nlscpu: oops\n');
    final cpu = parseCpuTopology(raw)!;
    expect(cpu.models, ['POWER9 (raw), altivec supported']);
    expect(cpu.logicalCpus, 1);
  });

  test('other output is not the read', () {
    expect(parseCpuTopology(''), isNull);
    expect(parseCpuTopology('4\n$kCpuLscpuMarker\n$kCpuInfoMarker\n'), isNull);
    expect(parseCpuTopology('$kCpuNprocMarker\n4\n$kCpuInfoMarker\n'), isNull);
  });
}
