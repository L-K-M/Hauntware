// BOOT-02 and BOOT-03's parsers: boot ends by boot ID, and the running
// kernel against the installed ones, ordered as `sort -V` orders them.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

void main() {
  test('boot ends key by boot ID and skip what they do not recognise', () {
    final a = 'a' * 32;
    final b = 'b' * 32;
    expect(
      parseBootEnds(
        '$a clean\n'
        '$b unclean\n'
        'not-an-id clean\n'
        '${'c' * 32} sideways\n'
        '\n',
      ),
      {a: BootEnd.clean, b: BootEnd.unclean},
    );
    expect(parseBootEnds(''), isEmpty);
  });

  group('kernels', () {
    String read(String running, List<String> installed) =>
        '$running\n$kKernelsMarker\n${installed.join('\n')}\n';

    test('the running kernel is current when it is the newest', () {
      final check = parseKernels(
        read('6.1.0-13-amd64', ['6.1.0-9-amd64', '6.1.0-13-amd64']),
      )!;
      expect(check.state, KernelCheckState.current);
      expect(check.installed, ['6.1.0-9-amd64', '6.1.0-13-amd64']);
      expect(check.newest, '6.1.0-13-amd64');
    });

    test('a newer installed kernel waits for a reboot', () {
      final check = parseKernels(
        read('6.1.0-9-amd64', ['6.1.0-13-amd64', '6.1.0-9-amd64']),
      )!;
      expect(check.state, KernelCheckState.newerInstalled);
      expect(check.installed, ['6.1.0-9-amd64', '6.1.0-13-amd64']);
      expect(check.newest, '6.1.0-13-amd64');
    });

    test('a kernel of another flavour is not a newer one (HST-11)', () {
      for (final (running, other) in [
        ('5.14.0-503.el9.x86_64', '5.14.0-503.el9.x86_64+debug'),
        ('5.14.0-503.el9.x86_64', '5.14.0-503.el9.x86_64+rt'),
        ('6.8.0-45-generic', '6.8.0-1012-aws'),
        ('6.8.0-45-generic', '6.8.0-45-lowlatency'),
        ('6.1.0-13-amd64', '6.1.0-13-rt-amd64'),
        ('6.1.0-13-amd64', '6.1.0-13-cloud-amd64'),
        ('6.6.31+rpt-rpi-2712', '6.6.31+rpt-rpi-v8'),
        ('6.6.1-arch1-1', '6.6.8-1-lts'),
      ]) {
        expect(
          compareVersions(other, running),
          greaterThan(0),
          reason: '$other sorts above $running',
        );
        final check = parseKernels(read(running, [running, other]))!;
        expect(check.state, KernelCheckState.current, reason: other);
        expect(check.newest, running, reason: other);
      }
    });

    test('a newer kernel of the running flavour still waits for a reboot, '
        'beside another flavour', () {
      for (final (running, newer, other) in [
        ('6.8.0-45-generic', '6.8.0-48-generic', '6.8.0-1012-aws'),
        (
          '5.14.0-427.13.1.el9_4.x86_64',
          '5.14.0-503.el9.x86_64',
          '5.14.0-503.el9.x86_64+debug',
        ),
        ('6.1.0-13-amd64', '6.5.0-0.deb12.4-amd64', '6.1.0-13-rt-amd64'),
      ]) {
        final check = parseKernels(read(running, [other, newer, running]))!;
        expect(check.state, KernelCheckState.newerInstalled, reason: newer);
        expect(check.newest, newer);
      }
    });

    test('a release names its flavour', () {
      expect(
        {
          for (final release in [
            '6.8.0-45-generic',
            '6.8.0-1012-aws',
            '6.1.0-13-rt-amd64',
            '5.14.0-503.el9.x86_64',
            '5.14.0-503.el9.x86_64+debug',
            '6.6.31+rpt-rpi-v8',
            '6.6.1-arch1-1',
            '6.6.14-0-lts',
            '6.9.3',
          ])
            release: kernelFlavour(release),
        },
        {
          '6.8.0-45-generic': 'generic',
          '6.8.0-1012-aws': 'aws',
          '6.1.0-13-rt-amd64': 'rt-amd64',
          '5.14.0-503.el9.x86_64': '',
          '5.14.0-503.el9.x86_64+debug': '+debug',
          '6.6.31+rpt-rpi-v8': '+rpt-rpi-v8',
          '6.6.1-arch1-1': '',
          '6.6.14-0-lts': 'lts',
          '6.9.3': '',
        },
      );
    });

    test('a running kernel whose modules are gone reads as removed', () {
      final check = parseKernels(
        read('5.15.0-88-generic', ['5.15.0-91-generic']),
      )!;
      expect(check.state, KernelCheckState.runningRemoved);
      expect(check.newest, '5.15.0-91-generic');
    });

    test('lines that are no kernel release are skipped', () {
      final check = parseKernels(
        read('6.1.0-13-amd64', [
          '6.1.0-13-amd64',
          'ls: cannot access',
          'zz-notes',
          'extramodules',
        ]),
      )!;
      expect(check.installed, ['6.1.0-13-amd64']);
      expect(check.state, KernelCheckState.current);
    });

    test('no module directory reads as unknown, and output without the '
        'marker is not the read', () {
      final none = parseKernels('6.18.44-fc\n$kKernelsMarker\n')!;
      expect(none.state, KernelCheckState.unknown);
      expect(none.newest, isNull);
      expect(parseKernels('6.18.44-fc\n'), isNull);
      expect(parseKernels('\n$kKernelsMarker\n6.1.0\n'), isNull);
    });
  });

  test('versions order digit runs by value', () {
    final releases = ['6.10.2', '6.1.0-13', '6.1.0-9', '5.15.0-91', '6.1.0'];
    expect(releases..sort(compareVersions), [
      '5.15.0-91',
      '6.1.0',
      '6.1.0-9',
      '6.1.0-13',
      '6.10.2',
    ]);
  });

  test('a ~ orders before anything, even the end, as sort -V orders it', () {
    final releases = ['6.1.0-13', '6.1.0-13~bpo1', '6.1.0-13a', '6.1.0-13~rc'];
    expect(releases..sort(compareVersions), [
      '6.1.0-13~bpo1',
      '6.1.0-13~rc',
      '6.1.0-13',
      '6.1.0-13a',
    ]);
    expect(compareVersions('6.1.0', '6.1.0'), 0);
    expect(
      compareVersions('1.99999999999999999999', '1.100000000000000000000'),
      lessThan(0),
    );
  });
}
