// HostProfile rules (03 §6.1, §7.7; D50): the server zone from the
// probe's clock facts, the counter width from `uname -m`, the LXC host
// figures rule, and the JSON round trip of the device cache.
import 'dart:convert';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

void main() {
  group('serverZone', () {
    test('parses the probe offset in both directions', () {
      expect(
        HostProfile(zoneOffset: '+0200').serverZone?.offset,
        const Duration(hours: 2),
      );
      expect(
        HostProfile(zoneOffset: '-0930').serverZone?.offset,
        -const Duration(hours: 9, minutes: 30),
      );
      expect(
        HostProfile(zoneOffset: '+0545').serverZone?.offset,
        const Duration(hours: 5, minutes: 45),
      );
      expect(
        HostProfile(zoneOffset: '+0000').serverZone?.offset,
        Duration.zero,
      );
    });

    test('accepts the extreme offsets in use and nothing beyond', () {
      expect(
        HostProfile(zoneOffset: '+1400').serverZone?.offset,
        const Duration(hours: 14),
      );
      expect(
        HostProfile(zoneOffset: '-1200').serverZone?.offset,
        -const Duration(hours: 12),
      );
      for (final bad in ['+1401', '-1201', '+0260', '+9999']) {
        expect(HostProfile(zoneOffset: bad).serverZone, isNull, reason: bad);
      }
    });

    test('an absent or malformed offset leaves the zone unknown', () {
      for (final bad in [null, '', 'UTC', '+02:00', '0200', '+200', ' +0200']) {
        expect(
          HostProfile(zoneOffset: bad, timezone: 'Europe/Berlin').serverZone,
          isNull,
          reason: '$bad',
        );
      }
    });

    test('the zone name prefers timedatectl, then /etc/localtime', () {
      expect(
        HostProfile(
          zoneOffset: '+0100',
          timezone: 'Europe/Berlin',
          localtimeTarget: '/usr/share/zoneinfo/Europe/Paris',
          etcTimezone: 'Europe/Rome',
        ).serverZone?.ianaName,
        'Europe/Berlin',
      );
      expect(
        HostProfile(
          zoneOffset: '+0100',
          localtimeTarget: '../usr/share/zoneinfo/Europe/Paris',
          etcTimezone: 'Europe/Rome',
        ).serverZone?.ianaName,
        'Europe/Paris',
      );
      expect(
        HostProfile(
          zoneOffset: '+0100',
          localtimeTarget: '/usr/share/zoneinfo/posix/Europe/Paris',
        ).serverZone?.ianaName,
        'Europe/Paris',
      );
      expect(
        HostProfile(
          zoneOffset: '+0100',
          localtimeTarget: '/etc/custom-zone',
          etcTimezone: 'Europe/Rome',
        ).serverZone?.ianaName,
        'Europe/Rome',
      );
    });

    test('a name outside the IANA grammar is skipped', () {
      final zone = HostProfile(
        zoneOffset: '-0500',
        timezone: 'America/New York',
        etcTimezone: 'Etc/GMT+5',
      ).serverZone;
      expect(zone?.ianaName, 'Etc/GMT+5');
      expect(
        HostProfile(zoneOffset: '+0000', timezone: '../etc').serverZone,
        isA<ServerZone>().having((z) => z.ianaName, 'ianaName', isNull),
      );
    });

    test('evaluates at the fixed offset until the engine adds rules', () {
      final zone = HostProfile(zoneOffset: '+0200').serverZone!;
      expect(zone.offsetAt, isNull);
      expect(
        zone.offsetFor(DateTime.utc(2026, 1, 1)),
        const Duration(hours: 2),
      );
    });
  });

  group('counterWidth', () {
    test('32-bit kernels wrap at 32 bits', () {
      for (final arch in [
        'i386',
        'i686',
        'armv6l',
        'armv7l',
        'armv5tel',
        'mips',
        'ppc',
        's390',
        'riscv32',
      ]) {
        expect(
          HostProfile(kernelArch: arch).counterWidth,
          CounterWidth.bits32,
          reason: arch,
        );
      }
    });

    test('64-bit and unknown kernels count in 64 bits', () {
      for (final arch in [
        'x86_64',
        'aarch64',
        'armv8l',
        'ppc64le',
        's390x',
        'mips64',
        'riscv64',
        'loongarch64',
        'something-new',
        null,
      ]) {
        expect(
          HostProfile(kernelArch: arch).counterWidth,
          CounterWidth.bits64,
          reason: '$arch',
        );
      }
    });
  });

  group('showsHostFigures (D50)', () {
    const lxcfs = ['/proc/cpuinfo', '/proc/meminfo', '/proc/stat'];

    test('outside a container every file is the system own', () {
      final p = HostProfile(container: 'none', lxcfsMounts: const []);
      for (final f in SystemWideProcFile.values) {
        expect(p.showsHostFigures(f), isFalse, reason: f.path);
      }
    });

    test('a container without lxcfs shows the host figures', () {
      final p = HostProfile(container: 'lxc', lxcfsMounts: const []);
      for (final f in SystemWideProcFile.values) {
        expect(p.showsHostFigures(f), isTrue, reason: f.path);
      }
    });

    test('lxcfs serves only the files it mounts', () {
      final p = HostProfile(container: 'lxc', lxcfsMounts: lxcfs);
      expect(p.showsHostFigures(SystemWideProcFile.meminfo), isFalse);
      expect(p.showsHostFigures(SystemWideProcFile.stat), isFalse);
      expect(p.showsHostFigures(SystemWideProcFile.loadavg), isTrue);
      expect(p.showsHostFigures(SystemWideProcFile.pressureCpu), isTrue);
    });

    test('an lxcfs mount tells a container when detect-virt is absent', () {
      final p = HostProfile(lxcfsMounts: lxcfs);
      expect(p.showsHostFigures(SystemWideProcFile.meminfo), isFalse);
      expect(p.showsHostFigures(SystemWideProcFile.diskstats), isTrue);
    });

    test('without either answer the files stay unknown', () {
      expect(
        HostProfile(
          lxcfsMounts: const [],
        ).showsHostFigures(SystemWideProcFile.meminfo),
        isNull,
      );
      expect(
        HostProfile().showsHostFigures(SystemWideProcFile.meminfo),
        isNull,
      );
    });
  });

  group('fromJson', () {
    final full = HostProfile(
      kernelSys: 'Linux',
      kernelRelease: '6.8.12-4-pve',
      kernelArch: 'x86_64',
      distroId: 'debian',
      systemdDir: true,
      systemdVersion: 252,
      virtualization: 'lxc',
      container: 'lxc',
      lxcfsMounts: const ['/proc/meminfo'],
      uid: 0,
      user: 'root',
      groups: const ['root'],
      sudoKind: SudoKind.sudoRs,
      tools: const {'tail': '/usr/bin/tail', 'dmesg': null},
      engineSockets: const [
        EngineSocket(
          path: '/var/run/docker.sock',
          exists: true,
          writable: false,
        ),
      ],
      epochSeconds: 1750000000,
      zoneOffset: '+0200',
      areaStatuses: const {
        'kernel': SectionStatus.ok,
        'virt': SectionStatus.missing,
      },
    );

    test('round-trips through encoded JSON', () {
      final decoded =
          jsonDecode(jsonEncode(full.toJson())) as Map<String, Object?>;
      expect(HostProfile.fromJson(decoded).toJson(), full.toJson());
    });

    test('an empty object is a profile with every fact unknown', () {
      final p = HostProfile.fromJson(const {});
      expect(p.toJson(), HostProfile().toJson());
      expect(p.lxcfsMounts, isNull);
      expect(p.groups, isEmpty);
    });

    test('unknown keys are ignored, absent ones stay unknown', () {
      final json = full.toJson()
        ..remove('lxcfsMounts')
        ..['addedLater'] = {'x': 1};
      final p = HostProfile.fromJson(json);
      expect(p.lxcfsMounts, isNull);
      expect(p.container, 'lxc');
    });

    test('a value of the wrong type is a FormatException', () {
      for (final (key, value) in <(String, Object)>[
        ('uid', '0'),
        ('systemdDir', 'yes'),
        ('groups', 'root'),
        ('lxcfsMounts', [1]),
        ('tools', {'tail': 1}),
        ('sudoKind', 'doas'),
        ('areaStatuses', {'kernel': 'great'}),
        ('engineSockets', ['x']),
        (
          'engineSockets',
          [
            {'path': '/s', 'exists': true},
          ],
        ),
      ]) {
        final json = full.toJson()..[key] = value;
        expect(
          () => HostProfile.fromJson(json),
          throwsFormatException,
          reason: key,
        );
      }
    });
  });
}
