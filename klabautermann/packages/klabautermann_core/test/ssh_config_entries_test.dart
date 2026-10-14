import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/fleet/ssh_config_entries.dart';
import 'package:test/test.dart';

import 'fixtures/ssh_config_fixture.dart';

void main() {
  group('fleetEntriesFromSshConfig (FL-02)', () {
    test('imports host blocks in file order and counts the skipped', () {
      final result = fleetEntriesFromSshConfig(sshConfigFixture);

      expect(result.entries.map((e) => e.label), sshConfigFixtureEntries);
      expect(result.skippedCount, sshConfigFixtureSkipped);
      for (final entry in result.entries) {
        expect(entry.serverId, 'ssh-config:${entry.label}');
        expect(entry.origin, FleetEntryOrigin.sshConfig);
        expect(entry.group, isNull, reason: 'ssh_config has no groups');
      }
    });

    test('returns a list no caller can edit', () {
      // The engine keeps this list as its import state.
      final entries = fleetEntriesFromSshConfig(sshConfigFixture).entries;

      expect(() => entries.add(entries.first), throwsUnsupportedError);
      // A fixed-length list would still allow this; an unmodifiable one not.
      expect(() => entries[0] = entries[1], throwsUnsupportedError);
    });

    test('reads HostName, Port and User; the first block wins', () {
      final entries = {
        for (final e in fleetEntriesFromSshConfig(sshConfigFixture).entries)
          e.label: e,
      };

      final web = entries['web-1']!;
      expect(web.host, 'web-1.example.com');
      expect(web.port, 2222);
      // The later `Host web-1` block's `User someone-else` is not merged.
      expect(web.user, 'deploy');

      // A trailing comment is stripped; no Port means 22; no User leaves
      // the login name to ssh rather than the top-level default.
      final db = entries['db-1']!;
      expect(db.host, '10.0.0.4');
      expect(db.port, kSshDefaultPort);
      expect(db.user, isNull);

      // No HostName: the alias is the address, as ssh does.
      final bastion = entries['bastion']!;
      expect(bastion.host, 'bastion');
      expect(bastion.user, 'admin');

      expect(entries['v6']!.host, '2001:db8::1');
    });

    test('a Host line with several names makes an entry for each', () {
      // A name an earlier block took is skipped, as for a whole block.
      final result = fleetEntriesFromSshConfig(
        'Host web db\n  HostName 10.0.0.7\n  Port 2200\n'
        'Host db\n  HostName other\n',
      );

      expect(result.entries.map((e) => (e.label, e.host, e.port)), [
        ('web', '10.0.0.7', 2200),
        ('db', '10.0.0.7', 2200),
      ]);
      expect(result.skippedCount, 1);
    });

    test('drops wildcard-only blocks and ignores Match blocks', () {
      final result = fleetEntriesFromSshConfig(sshConfigFixture);
      final labels = result.entries.map((e) => e.label);

      expect(labels, isNot(contains('*')));
      expect(labels.where((l) => l.contains('corp')), isEmpty);
      expect(
        result.entries.map((e) => e.user),
        isNot(contains('matched')),
        reason: 'a Match block\'s directives apply to no imported host',
      );
    });

    test('does not follow Include, at top level or inside a block', () {
      // The engine opens no file; the included hosts simply do not exist
      // for the importer. A block with an Include keeps its own values.
      final result = fleetEntriesFromSshConfig(
        'Include ~/.ssh/config.d/*\n'
        'Host legacy\n'
        '  Include legacy.conf\n'
        '  HostName legacy.example.com\n',
      );

      expect(result.entries, hasLength(1));
      expect(result.entries.single.host, 'legacy.example.com');
      expect(result.skippedCount, 0);
    });

    test('skips ports outside 1 to 65535 and counts them', () {
      final result = fleetEntriesFromSshConfig(
        'Host zero\n  Port 0\n'
        'Host high\n  Port 65536\n'
        'Host top\n  Port 65535\n',
      );

      expect(result.entries.map((e) => e.label), ['top']);
      expect(result.entries.single.port, 65535);
      expect(result.skippedCount, 2);
    });

    test('a Port ssh rejects is skipped; a service name resolves', () {
      // ssh rejects the whole config over `Port -1` or `Port 22a`, but it
      // resolves a service name such as `ssh` to its port, 22. Séance's
      // SshConfigImporter skips and reports a block whose Port ssh would
      // reject, and resolves `ssh` itself. This pins that behavior, so a
      // change in seance_core surfaces here.
      final result = fleetEntriesFromSshConfig(
        'Host negative\n  Port -1\n'
        'Host typo\n  Port 22a\n'
        'Host word\n  Port ssh\n',
      );

      expect(result.entries.map((e) => (e.label, e.port)), [
        ('word', kSshDefaultPort),
      ]);
      expect(result.skippedCount, 2);
    });

    test('an empty HostName or User counts as absent', () {
      final result = fleetEntriesFromSshConfig(
        'Host blank\n  HostName=\n  User=\n',
      );

      expect(result.entries.single.host, 'blank');
      expect(result.entries.single.user, isNull);
    });

    test('reads CRLF configs', () {
      final result = fleetEntriesFromSshConfig(
        'Host win\r\n  HostName win.example\r\n  Port 2200\r\n',
      );

      expect(result.entries.single.host, 'win.example');
      expect(result.entries.single.port, 2200);
    });

    test('an empty or comment-only config imports nothing', () {
      for (final text in ['', '\n\n', '# nothing here\n', 'Host *\n']) {
        final result = fleetEntriesFromSshConfig(text);
        expect(result.entries, isEmpty, reason: text);
        expect(result.skippedCount, 0, reason: text);
      }
    });
  });
}
