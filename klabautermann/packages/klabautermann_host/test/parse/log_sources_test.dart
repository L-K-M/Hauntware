// Log source parser tests (03 §7.6): the journal's boot list in both
// shapes (LOG-09), the `/var/log` listing (LOG-08) and the failures their
// reads report. The samples follow journalctl's output under `TZ=UTC`.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const _a = '3a4b5c6d7e8f90a1b2c3d4e5f6a7b8c9';
const _b = 'f0e1d2c3b4a5968778695a4b3c2d1e0f';

void main() {
  group('boot list', () {
    test('JSON rows carry the offset, ID and entry times', () {
      final r = parseJournalBoots(
        '[{"index":-1,"boot_id":"$_a","first_entry":1760860801000000,'
        '"last_entry":1760911200000000},'
        '{"index":0,"boot_id":"$_b","first_entry":1760947200000000,'
        '"last_entry":1760950800123456},'
        '{"index":1,"boot_id":"short"}]',
        JournalBootsFormat.json,
      );
      expect(r.value.map((b) => b.toJson()), [
        {
          'offset': -1,
          'id': _a,
          'firstEntry': '2025-10-19T08:00:01.000Z',
          'lastEntry': '2025-10-19T22:00:00.000Z',
        },
        {
          'offset': 0,
          'id': _b,
          'firstEntry': '2025-10-20T08:00:00.000Z',
          'lastEntry': '2025-10-20T09:00:00.123456Z',
        },
      ]);
      expect(r.warnings, ['list-boots: malformed row skipped']);
    });

    test('the text table, with a header or without, and either separator', () {
      final withHeader = parseJournalBoots(
        'IDX BOOT ID                          FIRST ENTRY                 '
        'LAST ENTRY\n'
        ' -1 $_a Sun 2025-10-19 08:00:01 UTC Sun 2025-10-19 22:00:00 UTC\n'
        '  0 $_b Mon 2025-10-20 08:00:00 UTC Mon 2025-10-20 09:00:00 UTC\n',
        JournalBootsFormat.text,
      );
      final dashed = parseJournalBoots(
        '-1 $_a Sun 2025-10-19 08:00:01 UTC—Sun 2025-10-19 22:00:00 UTC\n'
        ' 0 $_b Mon 2025-10-20 08:00:00 UTC-Mon 2025-10-20 09:00:00 UTC\n',
        JournalBootsFormat.text,
      );
      for (final r in [withHeader, dashed]) {
        expect(r.warnings, isEmpty);
        expect(r.value.map((b) => (b.offset, b.id)), [(-1, _a), (0, _b)]);
        expect(r.value.first.firstEntry, DateTime.utc(2025, 10, 19, 8, 0, 1));
        expect(r.value.last.lastEntry, DateTime.utc(2025, 10, 20, 9));
      }
    });

    test('output that is not a list warns and yields no boots', () {
      final json = parseJournalBoots(
        'No journal files',
        JournalBootsFormat.json,
      );
      expect(json.value, isEmpty);
      expect(json.warnings.single, startsWith('list-boots: not JSON'));
      final text = parseJournalBoots(
        'No journal files were found.\n',
        JournalBootsFormat.text,
      );
      expect(text.value, isEmpty);
      expect(text.warnings, ['list-boots: row skipped']);
    });

    test('an oversized offset or a row without times warns, never '
        'throws', () {
      final r = parseJournalBoots(
        '99999999999999999999 $_a Sun 2025-10-19 08:00:01 UTC\n'
        '  0 $_b no times here\n',
        JournalBootsFormat.text,
      );
      expect(r.value.map((b) => (b.offset, b.id)), [(0, _b)]);
      expect(r.value.single.firstEntry, isNull);
      expect(r.warnings, [
        'list-boots: row skipped',
        'list-boots: row without entry times',
      ]);
    });
  });

  group('log files', () {
    test('rows parse, sort by path and name their compression', () {
      final r = parseLogFiles(
        '1 2048 1760947200 /var/log/syslog\n'
        '0 512 1760832000 /var/log/auth.log\n'
        '1 300 1760774400 /var/log/syslog.2.gz\n'
        '1 120 1760774400 /var/log/apt/history.log.1.xz\n'
        'not a row\n',
      );
      expect(r.value.map((f) => f.path), [
        '/var/log/apt/history.log.1.xz',
        '/var/log/auth.log',
        '/var/log/syslog',
        '/var/log/syslog.2.gz',
      ]);
      final auth = r.value[1];
      expect(auth.readable, isFalse);
      expect(auth.bytes, 512);
      expect(auth.modified, DateTime.utc(2025, 10, 19));
      expect(r.value.map((f) => f.compression), [
        LogCompression.xz,
        LogCompression.none,
        LogCompression.none,
        LogCompression.gzip,
      ]);
      expect(r.warnings, ['log files: row skipped']);
    });

    test('a name with spaces keeps them', () {
      final r = parseLogFiles('1 10 0 /var/log/my app/out log.txt\n');
      expect(r.value.single.path, '/var/log/my app/out log.txt');
    });

    test('a size or time beyond what Dart holds warns, never throws', () {
      final r = parseLogFiles(
        '1 99999999999999999999 0 /var/log/a\n'
        '1 1 99999999999999999999 /var/log/b\n'
        '1 1 9000000000000 /var/log/c\n'
        '1 1 0 /var/log/d\n',
      );
      expect(r.value.single.path, '/var/log/d');
      expect(r.warnings, hasLength(3));
    });
  });

  group('read failures', () {
    test("a rotated read reports its decompressor's status", () {
      expect(rotatedTailFailure(''), isNull);
      expect(
        rotatedTailFailure(
          'sh: 1: xzcat: not found\n$kDecompressFailedMarker 127\n',
        ),
        127,
      );
      expect(rotatedTailFailure('$kDecompressFailedMarker 1'), 1);
      expect(
        rotatedTailFailure('$kDecompressFailedMarker 99999999999999999999'),
        isNull,
      );
    });

    test('a journalctl without pattern matching is recognised', () {
      expect(
        journalGrepUnsupported('Compiled without pattern matching support'),
        isTrue,
      );
      expect(
        journalGrepUnsupported('Failed to load PCRE2 library: No such file'),
        isTrue,
      );
      expect(journalGrepUnsupported('No entries'), isFalse);
    });
  });
}
