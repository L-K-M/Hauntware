// `ops` parser tests (03 §7.17): the record fixtures in `ops_records/`
// as E08's operation wrapper writes them (a running systemd record, a
// done setsid record, a done systemd record that failed, a done record
// without start ticks or times, a record whose id differs from its file
// name and one whose unit names another unit),
// truncated, unreadable and malformed records, and record text that
// tries to forge the listing's framing.
import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

/// The record fixtures, resolved for both `dart test` in the package
/// directory and `dart test packages/klabautermann_host` from the
/// workspace root.
String _recordsRoot() {
  for (final path in const [
    'test/parse/ops_records',
    'packages/klabautermann_host/test/parse/ops_records',
  ]) {
    if (Directory(path).existsSync()) return path;
  }
  throw StateError(
    'ops record fixtures not found; run the tests from the package '
    'directory or the workspace root',
  );
}

List<int> _fixture(String id) =>
    File('${_recordsRoot()}/$id.json').readAsBytesSync();

/// One framed record as the listing script prints it.
List<int> _rec(String kind, String id, List<int> body, {String st = 'ok'}) => [
  ...latin1.encode('rec $kind $id $st ${body.length}\n'),
  ...body,
  0x0a,
];

List<int> _dir(String kind, String state, int count, String path) =>
    latin1.encode('dir $kind $state $count $path\n');

/// The two listings joined as `c_ops` joins them, byte for byte.
List<int> _payload(List<int> user, List<int> root) => [...user, ...root];

const _userPath = '/home/klab/.local/state/klabautermann/ops';
const _rootPath = '/var/lib/klabautermann/ops';

List<int> _emptyRoot() => _dir('root', 'absent', 0, _rootPath);

OpsListing _parseUser(List<List<int>> records, {int? count}) {
  final r = parseOps(
    _payload([
      for (final rec in records) ...rec,
      ..._dir('user', 'ok', count ?? records.length, _userPath),
    ], _emptyRoot()),
  );
  return r.value;
}

void main() {
  group('record states', () {
    test('a running systemd record', () {
      const id = '0123456789abcdef';
      final r = parseOps(
        _payload([
          ..._rec('user', id, _fixture(id)),
          ..._dir('user', 'ok', 1, _userPath),
        ], _emptyRoot()),
      );
      expect(r.warnings, isEmpty);
      expect(r.value.rejected, isEmpty);
      expect(r.value.records.single.toJson(), {
        'directory': 'user',
        'id': id,
        'state': 'running',
        'pid': 4242,
        'startTicks': 987654,
        'unit': 'klabautermann-op-$id.service',
        'exitCode': null,
        'startedAt': '2025-10-17T11:20:00.000Z',
        'endedAt': null,
      });
    });

    test('a done setsid record, read from the root directory', () {
      const id = '1111111111111111';
      final r = parseOps(
        _payload(_dir('user', 'absent', 0, _userPath), [
          ..._rec('root', id, _fixture(id)),
          ..._dir('root', 'ok', 1, _rootPath),
        ]),
      );
      expect(r.warnings, isEmpty);
      final rec = r.value.records.single;
      expect(rec.directory, OpDirectoryKind.root);
      expect(rec.state, OpState.done);
      expect(rec.unit, isNull, reason: 'a null unit is a setsid runner');
      expect(rec.exitCode, 0);
      expect(rec.endedAt!.difference(rec.startedAt!).inSeconds, 42);
    });

    test('a done record without start ticks or times', () {
      // The wrapper writes null where /proc/<pid>/stat was unreadable and
      // where `date` has no %s.
      const id = 'abcdefabcdefabcd';
      final r = parseOps(
        _payload([
          ..._rec('user', id, _fixture(id)),
          ..._dir('user', 'ok', 1, _userPath),
        ], _emptyRoot()),
      );
      expect(r.warnings, isEmpty);
      expect(r.value.records.single.toJson(), {
        'directory': 'user',
        'id': id,
        'state': 'done',
        'pid': 9090,
        'startTicks': null,
        'unit': null,
        'exitCode': 1,
        'startedAt': null,
        'endedAt': null,
      });
    });

    test('a done systemd record that failed keeps its exit status', () {
      const id = '2222222222222222';
      final rec = _parseUser([_rec('user', id, _fixture(id))]).records.single;
      expect(rec.state, OpState.done);
      expect(rec.exitCode, 137);
      expect(rec.unit, 'klabautermann-op-$id.service');
    });

    test('directories report their path, state and count', () {
      final listing = _parseUser([]);
      expect(listing.toJson()['directories'], {
        'user': {'state': 'ok', 'path': _userPath, 'count': 0, 'listed': 0},
        'root': {'state': 'absent', 'path': _rootPath, 'count': 0, 'listed': 0},
      });
      expect(listing.records, isEmpty);
    });

    test('a path with spaces is kept whole', () {
      final r = parseOps(
        _payload(
          _dir('user', 'denied', 0, '/home/a b/.local/state/klabautermann/ops'),
          _emptyRoot(),
        ),
      );
      final user = r.value.directories[OpDirectoryKind.user]!;
      expect(user.state, OpDirectoryState.denied);
      expect(user.path, '/home/a b/.local/state/klabautermann/ops');
    });
  });

  group('forged records', () {
    test('an id other than the file name is rejected', () {
      // The file is 3333333333333333.json; the record claims another id.
      const id = '3333333333333333';
      final listing = _parseUser([_rec('user', id, _fixture(id))]);
      expect(listing.records, isEmpty);
      expect(listing.rejected.single.toJson(), {
        'directory': 'user',
        'id': id,
        'reason': 'forged',
      });
    });

    test('a unit other than its own is rejected', () {
      const id = '4444444444444444';
      final listing = _parseUser([_rec('user', id, _fixture(id))]);
      expect(listing.records, isEmpty);
      expect(listing.rejected.single.reason, OpRejection.forged);
    });

    test('record text cannot forge the framing', () {
      // A record whose text holds a well-framed record and a dir line is
      // one malformed record: the byte count frames it.
      const inner = '5555555555555555';
      final forgedRecord = utf8.encode(
        '{"v":1}\n'
        'rec user $inner ok 3\n'
        '{}\n'
        'dir root ok 9 /tmp/evil\n',
      );
      final r = parseOps(
        _payload([
          ..._rec('user', '6666666666666666', forgedRecord),
          ..._rec('user', '0123456789abcdef', _fixture('0123456789abcdef')),
          ..._dir('user', 'ok', 2, _userPath),
        ], _emptyRoot()),
      );
      expect(r.value.rejected.single.id, '6666666666666666');
      expect(r.value.rejected.single.reason, OpRejection.malformed);
      expect(r.value.records.single.id, '0123456789abcdef');
      expect(r.value.directories[OpDirectoryKind.root]!.path, _rootPath);
      expect(r.warnings, isEmpty);
    });
  });

  group('rejected records', () {
    test('a truncated record is not parsed', () {
      final listing = _parseUser([
        _rec(
          'user',
          '7777777777777777',
          List.filled(kOpsRecordBytes, 0x20),
          st: 'truncated',
        ),
      ]);
      expect(listing.records, isEmpty);
      expect(listing.rejected.single.reason, OpRejection.truncated);
    });

    test('unreadable records carry no bytes', () {
      final listing = _parseUser([
        _rec('user', '8888888888888888', const [], st: 'denied'),
        _rec('user', '9999999999999999', const [], st: 'error'),
      ]);
      expect(listing.rejected.map((r) => r.reason), [
        OpRejection.denied,
        OpRejection.unreadable,
      ]);
      expect(listing.directories[OpDirectoryKind.user]!.listed, 2);
    });

    final running = jsonDecode(utf8.decode(_fixture('0123456789abcdef')));
    Map<String, Object?> runningWith(Map<String, Object?> change) =>
        {...running as Map<String, Object?>, ...change}
          ..removeWhere((_, v) => v == #remove);
    final malformed = <String, List<int>>{
      'empty': const [],
      'not JSON': utf8.encode('{"v":1,'),
      'not UTF-8': [0x7b, 0xff, 0x7d],
      'an array': utf8.encode('[1]'),
      'no version': utf8.encode(jsonEncode(runningWith({'v': #remove}))),
      'no id': utf8.encode(jsonEncode(runningWith({'id': #remove}))),
      'an unknown state': utf8.encode(
        jsonEncode(runningWith({'state': 'paused'})),
      ),
      'pid 1': utf8.encode(jsonEncode(runningWith({'pid': 1}))),
      'a pid past the kernel limit': utf8.encode(
        jsonEncode(runningWith({'pid': 1 << 22 | 1})),
      ),
      'a fractional pid': utf8.encode(jsonEncode(runningWith({'pid': 2.5}))),
      'a pid as text': utf8.encode(jsonEncode(runningWith({'pid': '42'}))),
      'negative start ticks': utf8.encode(
        jsonEncode(runningWith({'startTicks': -1})),
      ),
      'no startedAt key': utf8.encode(
        jsonEncode(runningWith({'startedAt': #remove})),
      ),
      'no exit key': utf8.encode(jsonEncode(runningWith({'exit': #remove}))),
      'no endedAt key': utf8.encode(
        jsonEncode(runningWith({'endedAt': #remove})),
      ),
      'start ticks as text': utf8.encode(
        jsonEncode(runningWith({'startTicks': '5'})),
      ),
      'a start time past DateTime': utf8.encode(
        jsonEncode(runningWith({'startedAt': 8640000000001})),
      ),
      'a unit of the wrong type': utf8.encode(
        jsonEncode(runningWith({'unit': 7})),
      ),
      'running with an exit status': utf8.encode(
        jsonEncode(runningWith({'exit': 0})),
      ),
      'running with an end time': utf8.encode(
        jsonEncode(runningWith({'endedAt': 1760700001})),
      ),
      'done without an exit status': utf8.encode(
        jsonEncode(runningWith({'state': 'done', 'endedAt': 1760700001})),
      ),
      'an exit status past 255': utf8.encode(
        jsonEncode(
          runningWith({'state': 'done', 'exit': 256, 'endedAt': 1760700001}),
        ),
      ),
    };
    for (final MapEntry(key: name, value: body) in malformed.entries) {
      test('malformed: $name', () {
        final listing = _parseUser([_rec('user', '0123456789abcdef', body)]);
        expect(listing.records, isEmpty);
        expect(listing.rejected.single.reason, OpRejection.malformed);
      });
    }

    test('another format version', () {
      final body = utf8.encode(jsonEncode(runningWith({'v': 2})));
      final listing = _parseUser([_rec('user', '0123456789abcdef', body)]);
      expect(listing.rejected.single.reason, OpRejection.unsupportedVersion);
      final r = parseOps(
        _payload([
          ..._rec('user', '0123456789abcdef', body),
          ..._dir('user', 'ok', 1, _userPath),
        ], _emptyRoot()),
      );
      expect(r.warnings.single, contains('unknown format version'));
    });

    test('unknown keys are ignored', () {
      final body = utf8.encode(jsonEncode(runningWith({'extra': true})));
      final rec = _parseUser([
        _rec('user', '0123456789abcdef', body),
      ]).records.single;
      expect(rec.state, OpState.running);
    });

    test('an empty unit is not its own unit; the wrapper writes null', () {
      final body = utf8.encode(jsonEncode(runningWith({'unit': ''})));
      final listing = _parseUser([_rec('user', '0123456789abcdef', body)]);
      expect(listing.rejected.single.reason, OpRejection.forged);
    });
  });

  group('listing', () {
    test('a capped directory says so', () {
      final listing = _parseUser([
        _rec('user', '0123456789abcdef', _fixture('0123456789abcdef')),
      ], count: 60);
      final user = listing.directories[OpDirectoryKind.user]!;
      expect((user.count, user.listed, user.capped), (60, 1, true));
      expect(listing.directories[OpDirectoryKind.root]!.capped, isFalse);
    });

    test('the timeout-absent marker is skipped', () {
      final r = parseOps(
        _payload(
          [
            ...latin1.encode('$kTimeoutAbsentMarker\n'),
            ..._dir('user', 'ok', 0, _userPath),
          ],
          [...latin1.encode('$kTimeoutAbsentMarker\n'), ..._emptyRoot()],
        ),
      );
      expect(r.warnings, isEmpty);
      expect(
        r.value.directories[OpDirectoryKind.user]!.state,
        OpDirectoryState.ok,
      );
    });

    test('a listing without its dir line is incomplete', () {
      // The root listing's timeout cut it before its dir line.
      final r = parseOps(
        _payload(_dir('user', 'ok', 0, _userPath), [
          ..._rec('root', '1111111111111111', _fixture('1111111111111111')),
        ]),
      );
      final root = r.value.directories[OpDirectoryKind.root]!;
      expect(root.state, OpDirectoryState.incomplete);
      expect((root.path, root.count, root.listed), (null, null, 1));
      expect(r.value.records.single.id, '1111111111111111');
      expect(r.warnings.single, contains('root listing has no dir line'));
    });

    test('a byte count past the payload ends the parse', () {
      final r = parseOps(
        latin1.encode('rec user 0123456789abcdef ok 400\n{"v":1}\n'),
      );
      expect(r.value.records, isEmpty);
      expect(r.value.rejected, isEmpty);
      expect(r.warnings.first, contains('not framed'));
      expect(
        r.value.directories.values.map((d) => d.state),
        everyElement(OpDirectoryState.incomplete),
      );
    });

    for (final line in [
      'rec user 0123456789abcdef ok ${kOpsRecordBytes + 1}',
      'rec user 0123456789ABCDEF ok 2',
      'rec user 0123456789abcde ok 2',
      'rec other 0123456789abcdef ok 2',
      'rec user 0123456789abcdef fine 2',
      'rec user 0123456789abcdef ok',
    ]) {
      test('a malformed rec line ends the parse: "$line"', () {
        final r = parseOps(
          _payload([
            ...latin1.encode('$line\n{}\n'),
            ..._dir('user', 'ok', 1, _userPath),
          ], _emptyRoot()),
        );
        expect(r.value.records, isEmpty);
        expect(r.value.rejected, isEmpty);
        expect(r.warnings.first, contains('malformed rec line'));
        // The parse ended, so the dir line after it was never applied.
        expect(
          r.value.directories[OpDirectoryKind.user]!.state,
          OpDirectoryState.incomplete,
        );
      });
    }

    test('stray lines and malformed dir lines warn and are skipped', () {
      final r = parseOps(
        _payload([
          ...latin1.encode('timeout: failed to run command\n'),
          ...latin1.encode('dir user ok x $_userPath\n'),
          ..._dir('user', 'ok', 0, _userPath),
        ], _emptyRoot()),
      );
      expect(r.warnings, hasLength(2));
      expect(r.value.directories[OpDirectoryKind.user]!.count, 0);
    });

    test('random bytes never throw', () {
      final random = List.generate(4096, (i) => (i * 7919 + 13) % 256);
      for (var cut = 0; cut < random.length; cut += 97) {
        expect(() => parseOps(random.sublist(0, cut)), returnsNormally);
      }
    });
  });
}
