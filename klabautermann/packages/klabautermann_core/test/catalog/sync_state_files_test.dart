import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart'
    show SupportDirectoryAccess, writeFileAtomically;
import 'package:klabautermann_core/src/catalog/sync_enrollment_file.dart';
import 'package:klabautermann_core/src/catalog/sync_state_file.dart';
import 'package:klabautermann_core/src/catalog/sync_verdict_files.dart';
import 'package:seance_core/catalog.dart' show SyncAccount, SyncAccountMode;
import 'package:test/test.dart';

const _exclusive = SupportDirectoryAccess.exclusive;
const _unguarded = SupportDirectoryAccess.unguarded;
const _deviceId = '6b1f0c52-8e4a-4d1b-9f3e-2a7c5d9e0b14';
final _time = DateTime.utc(2026, 10, 16, 9, 30, 5);

void main() {
  late Directory support;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('klab-sync-state-');
  });

  tearDown(() async {
    await support.delete(recursive: true);
  });

  File fileIn(String name) => File('${support.path}/$name');

  Future<FilePinVerdictStore> openVerdicts({
    SupportDirectoryAccess access = _exclusive,
    SyncStateWriter writer = writeFileAtomically,
  }) => FilePinVerdictStore.open(
    support,
    access: access,
    writer: writer,
    now: () => _time,
  );

  Future<FileSyncTripwireStore> openTripwires({
    SupportDirectoryAccess access = _exclusive,
  }) => FileSyncTripwireStore.open(support, access: access, now: () => _time);

  Future<FileSyncEnrollmentState> openEnrollment({
    SupportDirectoryAccess access = _exclusive,
  }) => FileSyncEnrollmentState.open(
    support,
    deviceId: _deviceId,
    access: access,
    now: () => _time,
  );

  /// Every name in the support directory, sorted.
  List<String> names() => [
    for (final entity in support.listSync())
      entity.path.substring(support.path.length + 1),
  ]..sort();

  test('file names match 03 section 4.10', () {
    expect(pinVerdictsFileName, 'pin_verdicts.json');
    expect(syncTripwiresFileName, 'sync_tripwires.json');
    expect(syncEnrollmentFileName, 'sync_enrollment.json');
    expect(syncStateSchemaVersion, 1);
  });

  group('FilePinVerdictStore', () {
    test(
      'negative pins and kept verdicts round-trip through the file',
      () async {
        final store = await openVerdicts();
        expect(store.issue, isNull);
        expect(names(), isEmpty, reason: 'opening writes nothing');

        await store.addNegativePin('b.example:22');
        await store.addNegativePin('a.example:2222');
        await store.addNegativePin('b.example:22');
        await store.recordKeptVerdict('c.example:22', 'SHA256:rejected');
        await store.recordKeptVerdict('a.example:22', 'SHA256:other');

        expect(
          await fileIn(pinVerdictsFileName).readAsString(),
          '{"version":1,'
          '"negativePins":["a.example:2222","b.example:22"],'
          '"keptVerdicts":{"a.example:22":"SHA256:other",'
          '"c.example:22":"SHA256:rejected"}}',
        );

        final reopened = await openVerdicts();
        expect(reopened.issue, isNull);
        expect(await reopened.negativePins(), {
          'a.example:2222',
          'b.example:22',
        });
        expect(
          await reopened.rejectedFingerprintFor('c.example:22'),
          'SHA256:rejected',
        );
        expect(await reopened.rejectedFingerprintFor('d.example:22'), isNull);

        await reopened.removeNegativePin('b.example:22');
        await reopened.recordKeptVerdict('c.example:22', 'SHA256:newer');
        final third = await openVerdicts();
        expect(await third.negativePins(), {'a.example:2222'});
        expect(
          await third.rejectedFingerprintFor('c.example:22'),
          'SHA256:newer',
        );
      },
    );

    test('forgetting a host drops its kept verdict durably', () async {
      final store = await openVerdicts();
      await store.recordKeptVerdict('a.example:22', 'SHA256:rejected');
      await store.addNegativePin('a.example:22');
      expect(await store.rejectedFingerprintFor('a.example:22'), isNull);

      final reopened = await openVerdicts();
      expect(await reopened.rejectedFingerprintFor('a.example:22'), isNull);
      expect(await reopened.negativePins(), {'a.example:22'});
    });

    test('a change that changes nothing writes nothing', () async {
      var writes = 0;
      Future<void> counting(File target, List<int> bytes) {
        writes++;
        return writeFileAtomically(target, bytes);
      }

      final store = await openVerdicts(writer: counting);
      await store.removeNegativePin('a.example:22');
      await store.addNegativePin('a.example:22');
      await store.addNegativePin('a.example:22');
      await store.recordKeptVerdict('b.example:22', 'SHA256:x');
      await store.recordKeptVerdict('b.example:22', 'SHA256:x');
      expect(writes, 2);
    });

    test('overlapping changes all reach the file, in order', () async {
      final store = await openVerdicts();
      await Future.wait([
        store.addNegativePin('one:22'),
        store.addNegativePin('two:22'),
        store.recordKeptVerdict('three:22', 'SHA256:x'),
        store.removeNegativePin('one:22'),
      ]);

      final reopened = await openVerdicts();
      expect(await reopened.negativePins(), {'two:22'});
      expect(await reopened.rejectedFingerprintFor('three:22'), 'SHA256:x');
    });

    test('a failed write throws, keeps the change in memory, and the next '
        'write carries it', () async {
      var fail = true;
      Future<void> flaky(File target, List<int> bytes) => fail
          ? Future.error(const FileSystemException('disk full'))
          : writeFileAtomically(target, bytes);

      final store = await openVerdicts(writer: flaky);
      await expectLater(
        store.addNegativePin('a.example:22'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await store.negativePins(), {'a.example:22'});
      expect(names(), isEmpty);

      fail = false;
      await store.addNegativePin('b.example:22');
      final reopened = await openVerdicts();
      expect(await reopened.negativePins(), {'a.example:22', 'b.example:22'});
    });

    test('retrying a failed change writes it', () async {
      var fail = true;
      Future<void> flaky(File target, List<int> bytes) => fail
          ? Future.error(const FileSystemException('disk full'))
          : writeFileAtomically(target, bytes);

      final store = await openVerdicts(writer: flaky);
      await expectLater(
        store.addNegativePin('a.example:22'),
        throwsA(isA<FileSystemException>()),
      );

      fail = false;
      await store.addNegativePin('a.example:22');
      expect(await (await openVerdicts()).negativePins(), {'a.example:22'});
    });
  });

  group('FileSyncTripwireStore', () {
    test('tripped ids round-trip through the file', () async {
      final store = await openTripwires();
      await store.trip('hostkey:b.example:22');
      await store.trip('a1b2');
      await store.trip('a1b2');
      expect(
        await fileIn(syncTripwiresFileName).readAsString(),
        '{"version":1,"trippedIds":["a1b2","hostkey:b.example:22"]}',
      );

      final reopened = await openTripwires();
      expect(await reopened.trippedIds(), {'a1b2', 'hostkey:b.example:22'});
      await reopened.clear('a1b2');
      await reopened.clear('never-tripped');
      expect(await (await openTripwires()).trippedIds(), {
        'hostkey:b.example:22',
      });
    });
  });

  group('FileSyncEnrollmentState', () {
    test(
      'hands out the device id from settings.json and never writes it',
      () async {
        final state = await openEnrollment();
        expect(await state.deviceId(), _deviceId);
        await state.setPassphraseUnverified(true);
        expect(
          await fileIn(syncEnrollmentFileName).readAsString(),
          isNot(contains(_deviceId)),
        );
        expect(
          () => FileSyncEnrollmentState.open(
            support,
            deviceId: '',
            access: _exclusive,
          ),
          throwsArgumentError,
        );
      },
    );

    test('the hold, notices and account round-trip through the file', () async {
      final state = await openEnrollment();
      expect(await state.passphraseUnverified(), isFalse);
      expect(await state.notices(), isEmpty);
      expect(await state.account(), isNull);

      await state.setAccount(
        const SyncAccount(
          baseUrl: 'https://sync.example',
          username: 'ada',
          mode: SyncAccountMode.shared,
        ),
      );
      await state.setPassphraseUnverified(true);
      await state.setNotice('passphraseCheckFailed', true);
      await state.setNotice('accountAuthFailed', true);
      await state.setNotice('accountAuthFailed', false);
      await state.setNotice('zNotice', true);

      expect(
        await fileIn(syncEnrollmentFileName).readAsString(),
        '{"version":1,"passphraseUnverified":true,'
        '"notices":["passphraseCheckFailed","zNotice"],'
        '"account":{"baseUrl":"https://sync.example","username":"ada",'
        '"mode":"shared"}}',
      );

      final reopened = await openEnrollment();
      expect(reopened.issue, isNull);
      expect(await reopened.passphraseUnverified(), isTrue);
      expect(await reopened.notices(), {'passphraseCheckFailed', 'zNotice'});
      final account = (await reopened.account())!;
      expect(account.baseUrl, 'https://sync.example');
      expect(account.username, 'ada');
      expect(account.mode, SyncAccountMode.shared);

      await reopened.setAccount(null);
      expect(
        await fileIn(syncEnrollmentFileName).readAsString(),
        '{"version":1,"passphraseUnverified":true,'
        '"notices":["passphraseCheckFailed","zNotice"]}',
      );
      expect(await (await openEnrollment()).account(), isNull);
    });

    test('the pin publication assertion round-trips, and a withdrawal '
        'drops it from the file', () async {
      final state = await openEnrollment();
      expect(state.pinPublicationAssertion, isNull);

      await state.setPinPublicationAssertion('2026.11.0');
      expect(
        await fileIn(syncEnrollmentFileName).readAsString(),
        '{"version":1,"passphraseUnverified":false,"notices":[],'
        '"seance56Asserted":"2026.11.0"}',
      );
      expect((await openEnrollment()).pinPublicationAssertion, '2026.11.0');

      await state.setPinPublicationAssertion(null);
      expect(
        await fileIn(syncEnrollmentFileName).readAsString(),
        '{"version":1,"passphraseUnverified":false,"notices":[]}',
      );
      expect((await openEnrollment()).pinPublicationAssertion, isNull);
    });

    test('an assertion that names no release is a damaged file', () async {
      for (final value in ['""', 'true', '["2026.11.0"]']) {
        await fileIn(
          syncEnrollmentFileName,
        ).writeAsString('{"version":1,"seance56Asserted":$value}');
        final state = await openEnrollment();
        expect(state.issue?.kind, SyncStateIssueKind.recovered, reason: value);
        expect(state.pinPublicationAssertion, isNull, reason: value);
      }
    });

    test('an unknown account mode is a damaged file, never a guess', () async {
      await fileIn(syncEnrollmentFileName).writeAsString(
        '{"version":1,"account":{"baseUrl":"https://s","username":"u",'
        '"mode":"design-c"}}',
      );
      final state = await openEnrollment();
      expect(state.issue?.kind, SyncStateIssueKind.recovered);
      expect(await state.account(), isNull);
    });
  });

  group('damaged files', () {
    final opens = <String, Future<Object> Function(SupportDirectoryAccess)>{
      pinVerdictsFileName: (access) => openVerdicts(access: access),
      syncTripwiresFileName: (access) => openTripwires(access: access),
      syncEnrollmentFileName: (access) => openEnrollment(access: access),
    };

    SyncStateIssue? issueOf(Object store) => switch (store) {
      final FilePinVerdictStore s => s.issue,
      final FileSyncTripwireStore s => s.issue,
      final FileSyncEnrollmentState s => s.issue,
      _ => throw StateError('$store'),
    };

    Future<void> change(Object store) => switch (store) {
      final FilePinVerdictStore s => s.addNegativePin('fresh:22'),
      final FileSyncTripwireStore s => s.trip('fresh'),
      final FileSyncEnrollmentState s => s.setNotice('fresh', true),
      _ => throw StateError('$store'),
    };

    Future<bool> hasChange(Object store) async => switch (store) {
      final FilePinVerdictStore s => (await s.negativePins()).contains(
        'fresh:22',
      ),
      final FileSyncTripwireStore s => (await s.trippedIds()).contains('fresh'),
      final FileSyncEnrollmentState s => (await s.notices()).contains('fresh'),
      _ => throw StateError('$store'),
    };

    const damaged = {
      'not JSON': '{"version":1,',
      'not an object': '[1]',
      'no version': '{"negativePins":[],"trippedIds":[],"notices":[]}',
      'a version of 0': '{"version":0}',
      'a string version': '{"version":"1"}',
      'a wrong field type':
          '{"version":1,"negativePins":[3],"trippedIds":[""],'
          '"notices":{},"passphraseUnverified":"yes"}',
    };

    for (final MapEntry(key: name, value: open) in opens.entries) {
      for (final MapEntry(key: label, value: text) in damaged.entries) {
        test('$name with $label is renamed aside, the store starts empty and '
            'the next change writes a new file', () async {
          await fileIn(name).writeAsString(text);

          final store = await open(_exclusive);
          final issue = issueOf(store)!;
          expect(issue.kind, SyncStateIssueKind.recovered);
          expect(
            issue.preservedAs,
            '${fileIn(name).path}.corrupt-20261016T093005000Z',
          );
          expect(await File(issue.preservedAs!).readAsString(), text);
          expect(await fileIn(name).exists(), isFalse);

          await change(store);
          final reopened = await open(_exclusive);
          expect(issueOf(reopened), isNull);
          expect(await hasChange(reopened), isTrue);
          expect(names(), [name, '$name.corrupt-20261016T093005000Z']);
        });
      }

      test('$name damaged again is kept beside the earlier copy', () async {
        await fileIn(name).writeAsString('garbage');
        await open(_exclusive);
        await fileIn(name).writeAsString('more garbage');
        final store = await open(_exclusive);
        expect(
          issueOf(store)!.preservedAs,
          endsWith('$name.corrupt-20261016T093005000Z-2'),
        );
        expect(names(), hasLength(2));
      });

      test('$name that cannot be read is left as it is and no change is '
          'saved', () async {
        await Directory(fileIn(name).path).create();

        final store = await open(_exclusive);
        expect(issueOf(store)!.kind, SyncStateIssueKind.leftAsIs);
        await expectLater(
          change(store),
          throwsA(isA<SyncStateReadOnlyException>()),
        );
        expect(await hasChange(store), isTrue, reason: 'kept in memory');
        expect(names(), [name]);
      });

      test('$name from a newer build is read, left as it is, and no change is '
          'saved', () async {
        const text =
            '{"version":2,"negativePins":["old:22"],'
            '"trippedIds":["old"],"notices":["old"],"future":true}';
        await fileIn(name).writeAsString(text);

        final store = await open(_exclusive);
        expect(issueOf(store)!.kind, SyncStateIssueKind.newerVersion);
        await expectLater(
          change(store),
          throwsA(isA<SyncStateReadOnlyException>()),
        );
        expect(await fileIn(name).readAsString(), text);
      });
    }

    test(
      'what a newer build wrote is read when this build understands it',
      () async {
        await fileIn(
          pinVerdictsFileName,
        ).writeAsString('{"version":2,"negativePins":["old:22"],"pinsV2":{}}');
        final store = await openVerdicts();
        expect(await store.negativePins(), {'old:22'});
      },
    );
  });

  test('a body never shadows the version', () async {
    final (file, _) = await SyncStateFile.open(
      fileIn(syncTripwiresFileName),
      access: _exclusive,
      decode: (body) => body,
    );
    expect(() => file.save({'version': 9}), throwsA(isA<AssertionError>()));
  });

  group('unguarded access (no instance lock)', () {
    test('changes stay in memory and nothing is written', () async {
      final verdicts = await openVerdicts(access: _unguarded);
      final tripwires = await openTripwires(access: _unguarded);
      final enrollment = await openEnrollment(access: _unguarded);

      await verdicts.addNegativePin('a.example:22');
      await verdicts.recordKeptVerdict('b.example:22', 'SHA256:x');
      await tripwires.trip('id');
      await enrollment.setPassphraseUnverified(true);
      await enrollment.setNotice('n', true);

      expect(await verdicts.negativePins(), {'a.example:22'});
      expect(await tripwires.trippedIds(), {'id'});
      expect(await enrollment.passphraseUnverified(), isTrue);
      expect(names(), isEmpty);
    });

    test('an existing file is read and left as it is', () async {
      const text = '{"version":1,"negativePins":["kept:22"]}';
      await fileIn(pinVerdictsFileName).writeAsString(text);

      final store = await openVerdicts(access: _unguarded);
      expect(store.issue, isNull);
      expect(await store.negativePins(), {'kept:22'});
      await store.removeNegativePin('kept:22');
      expect(await fileIn(pinVerdictsFileName).readAsString(), text);
    });

    test('a damaged file is not renamed', () async {
      await fileIn(syncTripwiresFileName).writeAsString('garbage');

      final store = await openTripwires(access: _unguarded);
      expect(store.issue!.kind, SyncStateIssueKind.leftAsIs);
      await store.trip('id');
      expect(names(), [syncTripwiresFileName]);
      expect(await fileIn(syncTripwiresFileName).readAsString(), 'garbage');
    });
  });

  // None holds a secret (03 section 4.5 keeps the token and vault key in
  // the keystore), so they stay at the process default, as settings.json
  // and host_keys.json do.
  test('the files keep the process default mode', () async {
    if (Platform.isWindows) return;
    // A plain create, independent of the writer under test.
    final reference = fileIn('reference.json');
    await reference.writeAsString('{}');

    final verdicts = await openVerdicts();
    await verdicts.addNegativePin('a.example:22');
    final tripwires = await openTripwires();
    await tripwires.trip('id');
    final enrollment = await openEnrollment();
    await enrollment.setPassphraseUnverified(true);

    final mode = (await reference.stat()).mode;
    for (final name in [
      pinVerdictsFileName,
      syncTripwiresFileName,
      syncEnrollmentFileName,
    ]) {
      expect((await fileIn(name).stat()).mode, mode, reason: name);
    }
  });
}
