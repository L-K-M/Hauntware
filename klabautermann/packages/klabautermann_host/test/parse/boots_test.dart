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
      expect(check.state, KernelState.current);
      expect(check.installed, ['6.1.0-9-amd64', '6.1.0-13-amd64']);
      expect(check.newest, '6.1.0-13-amd64');
    });

    test('a newer installed kernel waits for a reboot', () {
      final check = parseKernels(
        read('6.1.0-9-amd64', ['6.1.0-13-amd64', '6.1.0-9-amd64']),
      )!;
      expect(check.state, KernelState.newerInstalled);
      expect(check.installed, ['6.1.0-9-amd64', '6.1.0-13-amd64']);
      expect(check.newest, '6.1.0-13-amd64');
    });

    test('a running kernel whose modules are gone reads as removed', () {
      final check = parseKernels(
        read('5.15.0-88-generic', ['5.15.0-91-generic']),
      )!;
      expect(check.state, KernelState.runningRemoved);
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
      expect(check.state, KernelState.current);
    });

    test('no module directory reads as unknown, and output without the '
        'marker is not the read', () {
      final none = parseKernels('6.18.44-fc\n$kKernelsMarker\n')!;
      expect(none.state, KernelState.unknown);
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
