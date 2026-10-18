import 'dart:convert';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

import '../harness.dart';

Object? fixtureJson(String name) => jsonDecode(fixtureString(name));

void main() {
  group('engine info', () {
    test('parses the 1.55 shape', () {
      final r = parseEngineInfo(fixtureJson('info-1.55.json'));
      expect(r.warnings, isEmpty);
      final info = r.value;
      expect(info.containers, 4);
      expect(info.containersRunning, 3);
      expect(info.driver, 'overlay2');
      expect(info.cgroupDriver, 'systemd');
      expect(info.cgroupVersion, '2');
      expect(info.loggingDriver, 'json-file');
      expect(info.plugins['Network'], contains('bridge'));
      expect(info.nCpu, 8);
      expect(info.warnings, hasLength(1));
      expect(info.rootless, isFalse);
    });

    test('detects rootless Podman', () {
      final r = parseEngineInfo(fixtureJson('info-podman-1.44.json'));
      expect(r.warnings, isEmpty);
      expect(r.value.rootless, isTrue);
      expect(r.value.serverVersion, '5.4.1');
    });

    test('never throws on malformed daemon input', () {
      expect(parseEngineInfo(null).warnings, isNotEmpty);
      final r = parseEngineInfo({'NCPU': 'eight', 'Plugins': 5});
      expect(r.value.nCpu, isNull);
      expect(r.warnings, isNotEmpty);
    });
  });

  group('events', () {
    test('parses the 1.52 shape without legacy fields', () {
      final lines = const LineSplitter().convert(
        fixtureString('events-1.52.ndjson'),
      );
      final events = [
        for (final l in lines)
          if (l.trim().isNotEmpty) parseDockerEvent(jsonDecode(l)).value,
      ];
      expect(events, hasLength(7));
      expect(events.first.type, 'container');
      expect(events.first.action, 'create');
      expect(events.first.name, 'web-1');
      expect(events.first.isLegacy, isFalse);
      expect(events.first.timestamp!.nanos, 123456789);
      expect(events[4].type, 'volume');
      expect(events[6].type, 'daemon');
    });

    test('accepts the legacy shape below 1.52', () {
      final lines = const LineSplitter().convert(
        fixtureString('events-legacy-1.41.ndjson'),
      );
      final r = parseDockerEvent(jsonDecode(lines.first), expectEventV2: false);
      expect(r.warnings, isEmpty);
      final event = r.value;
      expect(event.isLegacy, isTrue);
      expect(event.action, 'start');
      expect(event.actorId, startsWith('9f8e'));
      expect(event.image, 'nginx:1.25');
      expect(event.legacyFrom, 'nginx:1.25');
    });

    test('warns when legacy fields appear on an event-v2 connection', () {
      final r = parseDockerEvent(
        jsonDecode(
          fixtureString('events-legacy-1.41.ndjson').split('\n').first,
        ),
      );
      expect(r.warnings, isNotEmpty);
    });

    test('never throws on malformed daemon input', () {
      expect(parseDockerEvent(null).warnings, isNotEmpty);
    });
  });

  group('stats', () {
    test('parses one sample', () {
      final r = parseContainerStats(fixtureJson('stats-1.44.json'));
      expect(r.warnings, isEmpty);
      final s = r.value;
      expect(s.cpu.totalUsage, 1500000000);
      expect(s.cpu.onlineCpus, 4);
      expect(s.memory.limit, 1073741824);
      expect(s.pids, 6);
      expect(s.networks['eth0']!.rxBytes, 3000);
      expect(s.blockIo.readBytes, 150);
      expect(s.blockIo.writeBytes, 300);
    });

    test('computes CPU and memory from two streaming samples', () {
      final lines = const LineSplitter().convert(
        fixtureString('stats-stream-1.52.ndjson'),
      );
      final first = parseContainerStats(jsonDecode(lines[0])).value;
      final second = parseContainerStats(jsonDecode(lines[1])).value;

      final delta = computeStatsDelta(second, previous: first);
      expect(delta.cpuPercent, closeTo(100.0, 1e-9));
      expect(delta.memoryUsage, 190000000);
      expect(delta.memoryLimit, 1073741824);
      expect(delta.memoryPercent, closeTo(17.695, 0.01));
      expect(delta.networkRxBytes, 2000);
      expect(delta.networkTxBytes, 3000);
      expect(delta.blockReadBytes, 50);
      expect(delta.blockWriteBytes, 100);
      expect(delta.pids, 6);
    });

    test('one-shot stats keep memory but no CPU percent', () {
      final sample = parseContainerStats(fixtureJson('stats-1.44.json')).value;
      final delta = computeStatsDelta(sample);
      expect(delta.cpuPercent, isNull);
      expect(delta.memoryUsage, 190000000);
    });

    test('memory maths accept the cgroup v1 cache counter', () {
      const m = MemoryStats(usage: 100, stats: {'cache': 40});
      expect(effectiveMemoryUsage(m), 60);
      const v1 = MemoryStats(usage: 100, stats: {'total_inactive_file': 30});
      expect(effectiveMemoryUsage(v1), 70);
      const missing = MemoryStats(usage: 100);
      expect(effectiveMemoryUsage(missing), 100);
    });

    test('CPU percent is null without a system delta', () {
      expect(
        cpuPercentDelta(const CpuStats(), const CpuStats(totalUsage: 5)),
        isNull,
      );
    });

    test('CPU percent is null when the container counter went back', () {
      expect(
        cpuPercentDelta(
          const CpuStats(totalUsage: 50, systemCpuUsage: 100),
          const CpuStats(totalUsage: 10, systemCpuUsage: 200),
        ),
        isNull,
      );
    });

    test('an idle container is 0 %, not unknown', () {
      expect(
        cpuPercentDelta(
          const CpuStats(totalUsage: 50, systemCpuUsage: 100, onlineCpus: 4),
          const CpuStats(totalUsage: 50, systemCpuUsage: 200, onlineCpus: 4),
        ),
        0,
      );
    });

    test('a missing system counter is unknown too', () {
      expect(
        cpuPercentDelta(
          const CpuStats(totalUsage: 50, onlineCpus: 4),
          const CpuStats(totalUsage: 60, systemCpuUsage: 200, onlineCpus: 4),
        ),
        isNull,
      );
      expect(
        cpuPercentDelta(
          const CpuStats(totalUsage: 50, systemCpuUsage: 100, onlineCpus: 4),
          const CpuStats(totalUsage: 60, onlineCpus: 4),
        ),
        isNull,
      );
    });

    test('a missing container counter is unknown, not idle', () {
      expect(
        cpuPercentDelta(
          const CpuStats(systemCpuUsage: 100, onlineCpus: 4),
          const CpuStats(systemCpuUsage: 200, onlineCpus: 4),
        ),
        isNull,
      );
      expect(
        cpuPercentDelta(
          const CpuStats(totalUsage: 50, systemCpuUsage: 100),
          const CpuStats(systemCpuUsage: 200),
        ),
        isNull,
      );
    });
  });
}
