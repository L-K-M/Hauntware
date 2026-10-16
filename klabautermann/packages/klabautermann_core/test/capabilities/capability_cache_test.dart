import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/capabilities/capability_cache.dart';
import 'package:test/test.dart';

const _web = 'ssh-config:web';
const _db = 'ssh-config:db';
const _uuid = '0f8e2c1a-5b6d-4e7f-8a9b-0c1d2e3f4a5b';

/// SHA-256 of `web` and `Web` in UTF-8.
const _webHash =
    '4b5e57f6eb2f42b9039b3d1e13929295f231749c510cbe341cd68036d9af97e2';
const _upperWebHash =
    '2975104784a401e3880e2215550e9490eda7e67db5fc2b35e1a244acb092ced3';

final _probedAt = DateTime.utc(2026, 10, 15, 2, 20);

Matcher _rejected(CachedProfileRejection reason) =>
    isA<CachedProfileRejected>().having((r) => r.reason, 'reason', reason);

HostProfile _profile({int systemd = 252}) => HostProfile(
  systemdVersion: systemd,
  groups: const ['adm'],
  sshConnection: '192.0.2.9 50000 192.0.2.10 22',
  sessionParentPid: 812,
  sessionParentComm: 'sshd',
  epochSeconds: 1760494800,
  zoneOffset: '+0200',
  timezone: 'Europe/Berlin',
);

void main() {
  group('cache file names (D59)', () {
    test('a synced id is its UUID in lowercase', () {
      expect(capabilityCacheFileName(_uuid), '$_uuid.json');
      expect(capabilityCacheFileName(_uuid.toUpperCase()), '$_uuid.json');
    });

    test('an import id is the SHA-256 of its alias, so case, separators and '
        'colons cannot collide or escape the directory', () {
      expect(capabilityCacheFileName(_web), 'ssh-config-$_webHash.json');
      expect(
        capabilityCacheFileName('ssh-config:Web'),
        'ssh-config-'
        '$_upperWebHash.json',
      );
      for (final alias in ['../../etc/passwd', r'a\b:c', 'x' * 400]) {
        final name = capabilityCacheFileName('ssh-config:$alias')!;
        expect(name, matches(RegExp(r'^ssh-config-[0-9a-f]{64}\.json$')));
      }
    });

    test('any other id names no file', () {
      for (final id in [
        'ssh-config-hop:bastion',
        'ssh-config:',
        '0f8e2c1a5b6d4e7f8a9b0c1d2e3f4a5b',
        '../$_uuid',
        '',
      ]) {
        expect(capabilityCacheFileName(id), isNull, reason: id);
      }
    });
  });

  group('the capability cache (03 §4.10, §6.1)', () {
    late Directory support;
    late Directory cache;
    late DateTime clock;

    setUp(() {
      support = Directory.systemTemp.createTempSync('klab-capabilities-');
      cache = Directory('${support.path}/$capabilityCacheDirectoryName');
      clock = _probedAt;
    });

    tearDown(() => support.deleteSync(recursive: true));

    Future<CapabilityCache> open({
      Set<String> fleet = const {_web},
      SupportDirectoryAccess access = SupportDirectoryAccess.exclusive,
    }) => CapabilityCache.open(
      support,
      access: access,
      fleet: fleet,
      now: () => clock,
    );

    File file(String serverId) =>
        File('${cache.path}/${capabilityCacheFileName(serverId)}');

    Map<String, Object?> document(String serverId) =>
        jsonDecode(file(serverId).readAsStringSync()) as Map<String, Object?>;

    void writeDocument(String serverId, Object? json) {
      cache.createSync(recursive: true);
      file(serverId).writeAsStringSync(jsonEncode(json));
    }

    Future<void> probed(String serverId) async {
      final writer = await open(fleet: {serverId});
      expect(await writer.probed(serverId, _profile()), CacheUpdate.applied);
    }

    test('a probe is written without its clock and session fields, and '
        'a later run sends it once, before any probe', () async {
      await probed(_web);
      final json = document(_web);
      expect(json['serverId'], _web);
      expect(json['probedAt'], '2026-10-15T02:20:00.000Z');
      expect(json['profile'], isNot(contains('sshConnection')));

      clock = _probedAt.add(const Duration(hours: 3));
      final later = await open();
      final sent = later.takeCached(_web)!;
      expect(sent.serverId, _web);
      expect(sent.cachedAt, _probedAt);
      expect(sent.profile.systemdVersion, 252);
      expect(sent.profile.timezone, 'Europe/Berlin');
      for (final volatile in [
        sent.profile.sshConnection,
        sent.profile.sessionParentPid,
        sent.profile.sessionParentComm,
        sent.profile.epochSeconds,
        sent.profile.zoneOffset,
      ]) {
        expect(volatile, isNull);
      }
      expect(later.takeCached(_web), isNull);
    });

    test('a probe in this run supersedes the cached profile', () async {
      await probed(_web);
      final later = await open();
      await later.probed(_web, _profile(systemd: 255));
      expect(later.takeCached(_web), isNull);
    });

    test('the profile lasts 24 hours by the clock, and one probed in the '
        'future has not lasted at all', () async {
      await probed(_web);

      clock = _probedAt.add(const Duration(hours: 23, minutes: 59));
      expect(await (await open()).read(_web), isA<CachedProfileFresh>());

      clock = _probedAt.add(capabilityCacheTtl);
      final expired = await open();
      expect(
        await expired.read(_web),
        isA<CachedProfileExpired>().having(
          (e) => e.probedAt,
          'probedAt',
          _probedAt,
        ),
      );
      expect(expired.takeCached(_web), isNull);

      clock = _probedAt.subtract(const Duration(minutes: 1));
      expect(await (await open()).read(_web), isA<CachedProfileExpired>());
    });

    test(
      'a profile that ages past 24 hours while waiting is not sent',
      () async {
        await probed(_web);
        final later = await open();
        clock = _probedAt.add(capabilityCacheTtl);
        expect(later.takeCached(_web), isNull);
      },
    );

    test('without the instance lock nothing is written or purged, and '
        'what is cached is still read', () async {
      final unguarded = await open(access: SupportDirectoryAccess.unguarded);
      expect(
        await unguarded.probed(_web, _profile()),
        CacheUpdate.notExclusive,
      );
      expect(cache.existsSync(), isFalse);

      await probed(_web);
      final reader = await open(
        fleet: const {},
        access: SupportDirectoryAccess.unguarded,
      );
      expect(file(_web).existsSync(), isTrue, reason: 'no sweep unguarded');
      expect(await reader.forget({_web}), [CacheUpdate.notExclusive]);
      expect(file(_web).existsSync(), isTrue);
      expect(await reader.read(_web), isA<CachedProfileFresh>());
    });

    test('a server removed from the fleet loses its file and its unsent '
        'profile (SYN-08)', () async {
      await probed(_web);
      final later = await open();
      expect(await later.forget({_web}), [CacheUpdate.applied]);
      expect(file(_web).existsSync(), isFalse);
      expect(later.takeCached(_web), isNull);
      expect(await later.forget({_web}), [CacheUpdate.applied]);
    });

    test('opening sweeps the files of servers outside the fleet and '
        'leftover temporary files, and nothing else', () async {
      final writer = await open(fleet: const {_web, _db, _uuid});
      for (final id in [_web, _db, _uuid]) {
        expect(await writer.probed(id, _profile()), CacheUpdate.applied);
      }
      final leftover = File('${file(_web).path}.tmp-1234')
        ..writeAsStringSync('');
      final unknown = File('${cache.path}/notes.txt')..writeAsStringSync('');

      await open(fleet: const {_web});
      expect(file(_web).existsSync(), isTrue);
      expect(file(_db).existsSync(), isFalse);
      expect(file(_uuid).existsSync(), isFalse);
      expect(leftover.existsSync(), isFalse);
      expect(unknown.existsSync(), isTrue);
    });

    test('an id that names no file is refused', () async {
      final store = await open();
      const hop = 'ssh-config-hop:bastion';
      expect(await store.probed(hop, _profile()), CacheUpdate.unnamed);
      expect(
        await store.read(hop),
        _rejected(CachedProfileRejection.unnamedServer),
      );
    });

    test('a write the file system refuses reports a failure', () async {
      support.createSync();
      File(cache.path).writeAsStringSync('in the way');
      final store = await open();
      expect(await store.probed(_web, _profile()), CacheUpdate.failed);
    });

    group('corrupt or foreign files are rejected explicitly', () {
      Map<String, Object?> valid() => {
        'format': 'klabautermann.capabilities',
        'version': 1,
        'serverId': _web,
        'probedAt': '2026-10-15T02:20:00.000Z',
        'profile': {'systemdVersion': 252},
      };

      const corrupt = CachedProfileRejection.corrupt;
      const foreign = CachedProfileRejection.foreign;
      for (final (what, json, reason) in [
        ('not an object', <Object?>[1, 2], corrupt),
        ('another format', {...valid(), 'format': 'other'}, foreign),
        ('another server\'s profile', {...valid(), 'serverId': _db}, foreign),
        (
          'a newer version',
          {...valid(), 'version': 2},
          CachedProfileRejection.newerVersion,
        ),
        ('no version', {...valid(), 'version': null}, corrupt),
        ('a local time', {...valid(), 'probedAt': '2026-10-15T02:20'}, corrupt),
        (
          'a mistyped profile',
          {
            ...valid(),
            'profile': {'uid': '0'},
          },
          corrupt,
        ),
        ('no profile', {...valid(), 'profile': null}, corrupt),
      ]) {
        test(what, () async {
          writeDocument(_web, json);
          final store = await open();
          expect(await store.read(_web), _rejected(reason));
          expect(store.takeCached(_web), isNull);
        });
      }

      test('a valid file reads', () async {
        writeDocument(_web, valid());
        expect(await (await open()).read(_web), isA<CachedProfileFresh>());
      });

      test('text that is not JSON, and an oversized file', () async {
        cache.createSync(recursive: true);
        file(_web).writeAsStringSync('{"format": ');
        final store = await open();
        expect(await store.read(_web), _rejected(corrupt));

        file(_web).writeAsStringSync(' ' * (300 * 1024));
        expect(await store.read(_web), _rejected(corrupt));
      });

      test('a file that cannot be read', () async {
        Directory(file(_web).path).createSync(recursive: true);
        expect(
          await (await open()).read(_web),
          _rejected(CachedProfileRejection.unreadable),
        );
      });

      test('no file is missing, not rejected', () async {
        expect(await (await open()).read(_web), isA<CachedProfileMissing>());
      });
    });
  });
}
