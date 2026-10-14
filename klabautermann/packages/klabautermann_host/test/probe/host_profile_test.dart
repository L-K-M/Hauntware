// HostProfile rules (03 §6.1; D50): the LXC host figures rule.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

void main() {
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
}
