// The footprint manifest and the backup index (SAF-14, 03 §8.11): what
// the edit builders write and these parsers read back, and the rows they
// skip rather than throw on.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

final _a = 'a' * 64, _b = 'b' * 64;

void main() {
  group('manifest', () {
    test('round trips, and lists a backup directory with its index', () {
      final rows = backupFootprint(kRootBackupsDir);
      expect(rows, [
        const FootprintRow(kRootBackupsDir, FootprintKind.backupDirectory),
        const FootprintRow('$kRootBackupsDir/index', FootprintKind.backupIndex),
      ]);
      final parsed = parseFootprintManifest(encodeFootprintManifest(rows));
      expect(parsed.value, rows);
      expect(parsed.warnings, isEmpty);
    });

    test('an empty text is no manifest; a bad one warns, never throws', () {
      expect(parseFootprintManifest('').value, isEmpty);
      expect(parseFootprintManifest('').warnings, isEmpty);
      expect(
        parseFootprintManifest('{').warnings.single,
        startsWith('manifest: not JSON'),
      );
      expect(parseFootprintManifest('{"v":2,"rows":[]}').warnings, [
        'manifest: not version 1',
      ]);
      final mixed = parseFootprintManifest(
        '{"v":1,"rows":[{"path":"/x","kind":"backupIndex"},'
        '{"path":"rel","kind":"backupIndex"},{"path":"/y","kind":"nope"},7]}',
      );
      expect(mixed.value, [
        const FootprintRow('/x', FootprintKind.backupIndex),
      ]);
      expect(mixed.warnings, hasLength(3));
    });
  });

  group('backup index', () {
    test('round trips, oldest first, and names each backup', () {
      final entries = [
        BackupEntry(
          savedAt: DateTime.utc(2026, 10, 20, 12),
          sha256: _a,
          source: '/etc/app.conf',
        ),
        BackupEntry(
          savedAt: DateTime.utc(2026, 10, 20, 13),
          sha256: _b,
          source: 'crontab:deploy',
        ),
      ];
      final text = encodeBackupIndex(entries);
      expect(
        text,
        '1792497600\t$_a\t/etc/app.conf\n1792501200\t$_b\tcrontab:deploy\n',
      );
      expect(parseBackupIndex(text).value, entries);
      expect(entries.first.name, '$_a-1792497600');
    });

    test('a malformed line warns and is skipped', () {
      final parsed = parseBackupIndex(
        '1\t$_a\t/a\nnot a line\n99999999999999\t$_a\t/b\n2\txyz\t/c\n',
      );
      expect(parsed.value.single.source, '/a');
      expect(parsed.warnings, hasLength(3));
    });
  });
}
