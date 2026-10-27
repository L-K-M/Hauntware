import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

void main() {
  group('HostCommands.diskUsage', () {
    test('runs the script with the folder as its one argument', () {
      final argv = HostCommands.diskUsage('/var/log');
      expect(argv.first, 'sh');
      expect(argv.last, '/var/log');
      expect(argv[2], contains('du -x -k -a -d 1 -- "\$1"'));
      expect(argv[2], contains('head -n ${kDiskUsageEntries + 1}'));
    });

    test('refuses a relative or unnormalized path', () {
      for (final path in [
        'var',
        '/var/',
        '/var//log',
        '/var/../etc',
        '/var/./log',
        '/a\u0000b',
      ]) {
        expect(
          () => HostCommands.diskUsage(path),
          throwsA(isA<HostCommandError>()),
          reason: path,
        );
      }
      expect(HostCommands.diskUsage('/').last, '/');
    });
  });

  group('parseDiskUsage', () {
    test('reads the total and the entries, largest first, in bytes', () {
      final parse = parseDiskUsage(
        'd\t324\t/srv\n'
            'd\t308\t/srv/a\n'
            'f\t12\t/srv/notes\ttxt\n'
            'f\t4\t/srv/f\n'
            'f\t0\t/srv/link\n'
            '$kDiskUsageErrorsMarker\n'
            '\n',
        '/srv',
      );
      final listing = parse.listing!;
      expect(listing.totalBytes, 324 * 1024);
      expect(listing.entries, [
        const DiskUsageEntry(name: 'a', bytes: 308 * 1024, isFolder: true),
        const DiskUsageEntry(
          name: 'notes\ttxt',
          bytes: 12 * 1024,
          isFolder: false,
        ),
        const DiskUsageEntry(name: 'f', bytes: 4 * 1024, isFolder: false),
        const DiskUsageEntry(name: 'link', bytes: 0, isFolder: false),
      ]);
      expect(listing.incomplete, isFalse);
      expect(listing.truncated, isFalse);
    });

    test('names under the root folder', () {
      final listing = parseDiskUsage(
        'd\t100\t/\nd\t60\t/usr\nd\t40\t/var\n$kDiskUsageErrorsMarker\n',
        '/',
      ).listing!;
      expect(listing.entries.map((entry) => entry.name), ['usr', 'var']);
    });

    test('drops lines it cannot read and names outside the folder', () {
      final listing = parseDiskUsage(
        'd\t100\t/srv\n'
            'junk\n'
            'f\tx\t/srv/bad\n'
            'f\t5\t/srv/name\n'
            'with a newline\n'
            'f\t3\t/elsewhere\n'
            'f\t2\t/srv/deep/er\n'
            '$kDiskUsageErrorsMarker\n',
        '/srv',
      ).listing!;
      expect(listing.entries.map((entry) => entry.name), ['name']);
    });

    test('is incomplete when du said it could not read something', () {
      final listing = parseDiskUsage(
        'd\t8\t/srv\n'
            'd\t4\t/srv/locked\n'
            '$kDiskUsageErrorsMarker\n'
            "du: cannot read directory '/srv/locked': Permission denied\n",
        '/srv',
      ).listing!;
      expect(listing.incomplete, isTrue);
      expect(listing.entries.single.name, 'locked');
    });

    test('marks a full list as cut short', () {
      final out = StringBuffer('d\t${kDiskUsageEntries * 2}\t/srv\n');
      for (var i = 0; i < kDiskUsageEntries; i++) {
        out.writeln('f\t1\t/srv/f$i');
      }
      out.writeln(kDiskUsageErrorsMarker);
      expect(parseDiskUsage('$out', '/srv').listing!.truncated, isTrue);
    });

    test('without a total says why du read nothing', () {
      DiskUsageProblem? problem(String errors) =>
          parseDiskUsage('$kDiskUsageErrorsMarker\n$errors\n', '/srv').problem;
      expect(
        problem("du: cannot access '/srv': No such file or directory"),
        DiskUsageProblem.notFound,
      );
      expect(
        problem("du: cannot read directory '/srv': Permission denied"),
        DiskUsageProblem.denied,
      );
      expect(problem('sh: du: not found'), DiskUsageProblem.unreadable);
      expect(parseDiskUsage('', '/srv').problem, DiskUsageProblem.unreadable);
    });
  });
}
