import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/fleet/ssh_config_entries.dart';
import 'package:test/test.dart';

import 'fixtures/ssh_config_fixture.dart';

void main() {
  group('importedHostsFromSshConfig (FL-02)', () {
    test('imports host blocks in file order and counts the skipped', () {
      final result = importedHostsFromSshConfig(sshConfigFixture);

      expect(result.hosts.map((h) => h.alias), sshConfigFixtureEntries);
      expect(result.skippedCount, sshConfigFixtureSkipped);
    });

    test('returns a list no caller can edit', () {
      // The engine keeps this list as its import state.
      final hosts = importedHostsFromSshConfig(sshConfigFixture).hosts;

      expect(() => hosts.add(hosts.first), throwsUnsupportedError);
      // A fixed-length list would still allow this; an unmodifiable one not.
      expect(() => hosts[0] = hosts[1], throwsUnsupportedError);
    });

    test('reads HostName, Port, User, IdentityFile and ProxyJump; the first '
        'block wins', () {
      final entries = {
        for (final h in importedHostsFromSshConfig(sshConfigFixture).hosts)
          h.alias: h,
      };

      final web = entries['web-1']!;
      expect(web.hostName, 'web-1.example.com');
      expect(web.port, 2222);
      // The later `Host web-1` block's `User someone-else` is not merged.
      expect(web.user, 'deploy');
      // As written: the engine expands `~` when it reads the key.
      expect(web.identityFile, '~/.ssh/id_ed25519');
      expect(web.proxyJump, isNull);

      // A trailing comment is stripped; no Port means 22; no User leaves
      // the login name to ssh rather than the top-level default.
      final db = entries['db-1']!;
      expect(db.hostName, '10.0.0.4');
      expect(db.port, kSshDefaultPort);
      expect(db.user, isNull);
      expect(db.identityFile, isNull);

      // No HostName: the alias is the address, as ssh does.
      final bastion = entries['bastion']!;
      expect(bastion.hostName, 'bastion');
      expect(bastion.user, 'admin');
      expect(bastion.proxyJump, 'jump.example');

      expect(entries['v6']!.hostName, '2001:db8::1');
    });

    test('a Host line with several names makes an entry for each', () {
      // A name an earlier block took is skipped, as for a whole block.
      final result = importedHostsFromSshConfig(
        'Host web db\n  HostName 10.0.0.7\n  Port 2200\n'
        'Host db\n  HostName other\n',
      );

      expect(result.hosts.map((h) => (h.alias, h.hostName, h.port)), [
        ('web', '10.0.0.7', 2200),
        ('db', '10.0.0.7', 2200),
      ]);
      expect(result.skippedCount, 1);
    });

    test('drops wildcard-only blocks and ignores Match blocks', () {
      final result = importedHostsFromSshConfig(sshConfigFixture);
      final labels = result.hosts.map((h) => h.alias);

      expect(labels, isNot(contains('*')));
      expect(labels.where((l) => l.contains('corp')), isEmpty);
      expect(
        result.hosts.map((h) => h.user),
        isNot(contains('matched')),
        reason: 'a Match block\'s directives apply to no imported host',
      );
    });

    test('does not follow Include, at top level or inside a block', () {
      // The engine opens no file; the included hosts simply do not exist
      // for the importer. A block with an Include keeps its own values.
      final result = importedHostsFromSshConfig(
        'Include ~/.ssh/config.d/*\n'
        'Host legacy\n'
        '  Include legacy.conf\n'
        '  HostName legacy.example.com\n',
      );

      expect(result.hosts, hasLength(1));
      expect(result.hosts.single.hostName, 'legacy.example.com');
      expect(result.skippedCount, 0);
    });

    test('skips ports outside 1 to 65535 and counts them', () {
      final result = importedHostsFromSshConfig(
        'Host zero\n  Port 0\n'
        'Host high\n  Port 65536\n'
        'Host top\n  Port 65535\n',
      );

      expect(result.hosts.map((h) => h.alias), ['top']);
      expect(result.hosts.single.port, 65535);
      expect(result.skippedCount, 2);
    });

    test('a Port ssh rejects is skipped; a service name resolves', () {
      // ssh rejects the whole config over `Port -1` or `Port 22a`, but it
      // resolves a service name such as `ssh` to its port, 22. Séance's
      // SshConfigImporter skips and reports a block whose Port ssh would
      // reject, and resolves `ssh` itself. This pins that behavior, so a
      // change in seance_core surfaces here.
      final result = importedHostsFromSshConfig(
        'Host negative\n  Port -1\n'
        'Host typo\n  Port 22a\n'
        'Host word\n  Port ssh\n',
      );

      expect(result.hosts.map((h) => (h.alias, h.port)), [
        ('word', kSshDefaultPort),
      ]);
      expect(result.skippedCount, 2);
    });

    test('an empty HostName or User counts as absent', () {
      final result = importedHostsFromSshConfig(
        'Host blank\n  HostName=\n  User=\n',
      );

      expect(result.hosts.single.hostName, 'blank');
      expect(result.hosts.single.user, isNull);
    });

    test('reads CRLF configs', () {
      final result = importedHostsFromSshConfig(
        'Host win\r\n  HostName win.example\r\n  Port 2200\r\n',
      );

      expect(result.hosts.single.hostName, 'win.example');
      expect(result.hosts.single.port, 2200);
    });

    test('an empty or comment-only config imports nothing', () {
      for (final text in ['', '\n\n', '# nothing here\n', 'Host *\n']) {
        final result = importedHostsFromSshConfig(text);
        expect(result.hosts, isEmpty, reason: text);
        expect(result.skippedCount, 0, reason: text);
      }
    });

    test('leaves out and counts a host whose ProxyJump it cannot follow', () {
      List<String> aliases(String text) => [
        for (final h in importedHostsFromSshConfig(text).hosts) h.alias,
      ];

      // One host per line, each with what ssh rejects or reads otherwise.
      final result = importedHostsFromSshConfig(
        'Host empty-user\n  ProxyJump @jump\n'
        'Host port-zero\n  ProxyJump jump:0\n'
        'Host service\n  ProxyJump jump:ssh\n'
        'Host slash\n  ProxyJump jump/22\n'
        'Host bracket\n  ProxyJump [jump\n'
        'Host hole\n  ProxyJump a,,b\n'
        'Host token\n  ProxyJump %h-jump\n'
        'Host uri-path\n  ProxyJump ssh://jump/x\n'
        'Host fine\n  ProxyJump jump\n',
      );
      expect(result.hosts.map((h) => h.alias), ['fine']);
      expect(result.skippedCount, 8);

      // A first-hop loop, and a host that names a looping one.
      expect(
        aliases(
          'Host a\n  ProxyJump b\nHost b\n  ProxyJump a\n'
          'Host self\n  ProxyJump self\n'
          'Host c\n  ProxyJump x,a\n'
          'Host d\n',
        ),
        ['d'],
      );

      // A hop that names a host the importer refused: ssh would take that
      // block's HostName, which the engine does not have.
      final refused = importedHostsFromSshConfig(
        'Host jump\n  HostName 10.0.0.1\n  Port 22a\n'
        'Host behind\n  ProxyJump jump\n',
      );
      expect(refused.hosts, isEmpty);
      expect(refused.skippedCount, 2);
    });

    test('keeps ProxyJump none and an alias refused only in a later block', () {
      final result = importedHostsFromSshConfig(
        'Host direct\n  ProxyJump none\n'
        'Host jump\n  HostName 10.0.0.1\n'
        'Host jump\n  Port 22a\n'
        'Host behind\n  ProxyJump jump\n',
      );

      expect(result.hosts.map((h) => h.alias), ['direct', 'jump', 'behind']);
      expect(result.skippedCount, 1);
      expect(result.hosts.first.proxyJump, 'none');
    });
  });
}
