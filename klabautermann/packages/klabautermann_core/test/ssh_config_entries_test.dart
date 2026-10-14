import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/fleet/imported_fleet.dart';
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
        'value wins', () {
      final entries = {
        for (final h in importedHostsFromSshConfig(sshConfigFixture).hosts)
          h.alias: h,
      };

      final web = entries['web-1']!;
      expect(web.hostName, 'web-1.example.com');
      expect(web.port, 2222);
      // The later `Host web-1` block's `User someone-else` comes too late,
      // but its ProxyJump fills what the first block left unset.
      expect(web.user, 'deploy');
      expect(web.proxyJump, 'none');
      // As written: the engine expands `~` when it reads the key.
      expect(web.identityFile, '~/.ssh/id_ed25519');

      // A trailing comment is stripped; no Port means 22; no User leaves
      // the login name to ssh.
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
      // A later block for a name adds only what earlier ones left unset.
      final result = importedHostsFromSshConfig(
        'Host web db\n  HostName 10.0.0.7\n  Port 2200\n'
        'Host db\n  HostName other\n',
      );

      expect(result.hosts.map((h) => (h.alias, h.hostName, h.port)), [
        ('web', '10.0.0.7', 2200),
        ('db', '10.0.0.7', 2200),
      ]);
      expect(result.skippedCount, 0);
    });

    test('wildcard-only blocks name no host, and a Match block whose '
        'criteria fail applies to none', () {
      final result = importedHostsFromSshConfig(sshConfigFixture);
      final labels = result.hosts.map((h) => h.alias);

      expect(labels, isNot(contains('*')));
      expect(labels.where((l) => l.contains('corp')), isEmpty);
      expect(
        result.hosts.map((h) => h.user),
        isNot(contains('matched')),
        reason: 'the Match block\'s `host` criterion fails for every host',
      );
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
      // resolves a service name such as `ssh` to its port, 22. The import
      // leaves out the hosts such a Port applies to, and knows the
      // service names Séance's SshConfigImporter knows.
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

    test('leaves out a host with a line ssh rejects', () {
      // ssh rejects a directive with no value, or with more than the one
      // it takes, and with it the whole config.
      final result = importedHostsFromSshConfig(
        'Host blank\n  HostName=\n'
        'Host nobody\n  User\n'
        'Host two\n  IdentityFile ~/.ssh/a ~/.ssh/b\n'
        'Host *.example\n  ProxyJump\n'
        'Host db.example\n'
        'Host fine\n  User u\n',
      );

      expect(result.hosts.map((h) => h.alias), ['fine']);
      expect(result.skippedCount, 4);
    });

    test('expands %h and %% in HostName, as ssh does, and skips a host '
        'with another token', () {
      // ssh_config(5), TOKENS: HostName accepts %% and %h, the name given
      // to ssh; any other token makes ssh exit.
      final result = importedHostsFromSshConfig(
        'Host web1 web2\n  HostName %h.corp.example\n'
        'Host zone\n  HostName fe80::1%%eth0\n'
        'Host user-token\n  HostName %r.example\n'
        'Host trailing\n  HostName host%\n'
        'Host behind\n  ProxyJump user-token\n',
      );

      expect(result.hosts.map((h) => (h.alias, h.hostName)), [
        ('web1', 'web1.corp.example'),
        ('web2', 'web2.corp.example'),
        ('zone', 'fe80::1%eth0'),
      ]);
      // `behind` names a host left out, whose HostName ssh cannot use.
      expect(result.skippedCount, 3);
    });

    test('IdentityFile none is no key file, and a host whose IdentityFile '
        'ssh would expand is skipped', () {
      final result = importedHostsFromSshConfig(
        'Host none\n  IdentityFile NONE\n'
        'Host token\n  IdentityFile ~/.ssh/%r@%h\n'
        'Host variable\n  IdentityFile \${HOME}/.ssh/key\n'
        'Host dollar\n  IdentityFile ~/.ssh/a\$b\n'
        'Host behind\n  ProxyJump token\n',
      );

      expect(result.hosts.map((h) => (h.alias, h.identityFile)), [
        ('none', null),
        // ssh expands only `\${`, so a lone `\$` is part of the path.
        ('dollar', '~/.ssh/a\$b'),
      ]);
      expect(result.skippedCount, 3);
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

    test('keeps ProxyJump none; a Port ssh rejects in any block of a host '
        'leaves it out', () {
      final result = importedHostsFromSshConfig(
        'Host direct\n  ProxyJump none\n'
        'Host jump\n  HostName 10.0.0.1\n'
        'Host jump\n  Port 22a\n'
        'Host behind\n  ProxyJump jump\n',
      );

      expect(result.hosts.map((h) => h.alias), ['direct']);
      expect(result.skippedCount, 2);
      expect(result.hosts.first.proxyJump, 'none');
    });

    test('leaves out a route of more than 16 hops, which Séance refuses '
        'to dial', () {
      String names(String prefix, int count) => [
        for (var index = 1; index <= count; index++) '$prefix$index',
      ].join(',');
      // A chain of first hops: c<k> is k hops from c0.
      final chain = StringBuffer('Host c0\n');
      for (var k = 1; k <= 17; k++) {
        chain.write('Host c$k\n  ProxyJump c${k - 1}\n');
      }

      final result = importedHostsFromSshConfig(
        'Host t16\n  ProxyJump ${names('j', 16)}\n'
        'Host t17\n  ProxyJump ${names('j', 17)}\n'
        '$chain'
        // c10's ten hops, c10 itself and six more make 17.
        'Host mixed\n  ProxyJump c10,${names('x', 6)}\n'
        'Host behind\n  ProxyJump x,c17\n',
      );

      expect(result.hosts.map((h) => h.alias), [
        't16',
        for (var k = 0; k <= 16; k++) 'c$k',
      ]);
      expect(result.skippedCount, 4);
    });

    test('long chains cost linear time', () {
      // Recomputing a route per host, or taking a pass over every host for
      // each one left out, made these take about 50 s; the engine isolate
      // answers nothing meanwhile. A test timeout cannot cut synchronous
      // work short, so the time is measured instead.
      String chain(int count, String first, String hop) => [
        'Host h0\n$first',
        for (var index = 1; index < count; index++)
          'Host h$index\n  ProxyJump $hop${index - 1}\n',
      ].join();
      final clock = Stopwatch()..start();

      final firstHops = importedHostsFromSshConfig(chain(1000, '', 'h'));
      expect(firstHops.hosts, hasLength(17));
      expect(
        ImportedFleet(firstHops.hosts, localUser: 'me').entries,
        hasLength(17),
      );
      final laterHops = importedHostsFromSshConfig(
        chain(3000, '  ProxyJump j:0\n', 'x,h'),
      );
      expect(laterHops.skippedCount, 3000);
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });

  group('every block ssh applies, the first value first (03 §10.1)', () {
    test('a wildcard block with a negated pattern sets the jump host', () {
      const config =
          'Host * !bastion\n  ProxyJump bastion\n'
          'Host bastion\n  HostName bastion.example.com\n'
          'Host prod-web\n  HostName 10.0.0.5\n';

      expect(_dials(config), {
        'bastion': ['me@bastion.example.com:22'],
        'prod-web': ['me@bastion.example.com:22', 'me@10.0.0.5:22'],
      });
      expect(importedHostsFromSshConfig(config).skippedCount, 0);
    });

    test('a wildcard block before the host\'s own block comes first', () {
      expect(
        _dials(
          'Host prod-*\n  ProxyJump bastion\n  Port 2200\n'
          'Host prod-web\n  HostName 10.0.0.5\n  Port 2222\n',
        ),
        {
          'prod-web': ['me@bastion:22', 'me@10.0.0.5:2200'],
        },
      );
    });

    test('a later block for an alias adds what the first left unset', () {
      const config =
          'Host web\n  HostName 10.0.0.5\n'
          'Host web\n  HostName 10.9.9.9\n  ProxyJump bastion\n';

      expect(_dials(config), {
        'web': ['me@bastion:22', 'me@10.0.0.5:22'],
      });
      expect(importedHostsFromSshConfig(config).skippedCount, 0);
    });

    test('a directive repeated in one block keeps its first value', () {
      expect(
        _dials(
          'Host web\n  HostName 10.0.0.5\n  HostName 10.9.9.9\n'
          '  ProxyJump a\n  ProxyJump b\n  User first\n  User second\n',
        ),
        {
          // The hop takes a's own settings, not web's User.
          'web': ['me@a:22', 'first@10.0.0.5:22'],
        },
      );
    });

    test('User and IdentityFile come from Host * and top-level lines', () {
      final hosts = {
        for (final host in importedHostsFromSshConfig(
          'Host web\n  HostName 10.0.0.5\n  IdentityFile ~/.ssh/web\n'
          'Host agent\n  IdentityFile none\n'
          'Host plain\n'
          'Host *\n  User admin\n  IdentityFile ~/.ssh/id_ed25519\n',
        ).hosts)
          host.alias: (host.user, host.identityFile),
      };

      expect(hosts, {
        // ssh tries the files in the order it read them; the engine
        // signs in with the first.
        'web': ('admin', '~/.ssh/web'),
        // `none` names no file, so the next one is the first ssh loads.
        'agent': ('admin', '~/.ssh/id_ed25519'),
        'plain': ('admin', '~/.ssh/id_ed25519'),
      });

      // Lines before the first Host apply to every host, before its own.
      expect(
        importedHostsFromSshConfig(
          'User everyone\nHost web\n  User deploy\n',
        ).hosts.single.user,
        'everyone',
      );
    });

    test('a Match block applies when its criteria hold', () {
      // `host` compares the HostName read so far, `originalhost` the
      // name given to ssh.
      expect(
        _dials(
          'Match host web\n  ProxyJump bastion\n'
          'Host web\n  HostName 10.0.0.5\n',
        ),
        {
          'web': ['me@bastion:22', 'me@10.0.0.5:22'],
        },
      );
      expect(
        _dials(
          'Host web\n  HostName 10.0.0.5\n'
          'Match host web\n  ProxyJump bastion\n'
          'Match originalhost WEB,!db\n  User original\n'
          'Match all\n  Port 2200\n',
        ),
        {
          'web': ['original@10.0.0.5:2200'],
        },
      );
    });

    test('a Match block that may apply and could set a value first leaves '
        'the host out', () {
      final result = importedHostsFromSshConfig(
        'Host fixed\n  ProxyJump none\n'
        'Host open\n'
        // ssh reads the config for gw too, where the Match may apply.
        'Host via\n  ProxyJump none\n  HostName %h.example\n'
        'Host behind-gw\n  ProxyJump gw\n'
        'Match exec "test -f /tmp/vpn"\n  ProxyJump bastion\n'
        // A criterion that fails settles it, whatever the others say.
        'Match host none.example localnetwork 10.0.0.0/8\n  Port 2222\n'
        // Settings the engine does not map change nothing.
        'Match user root\n  ServerAliveInterval 5\n',
      );

      expect(result.hosts.map((h) => h.alias), ['fixed', 'via']);
      expect(result.skippedCount, 2);
    });

    test('a hop that names no alias takes the blocks that match its name', () {
      expect(
        _dials(
          'Host *.corp\n  HostName %h\n  Port 2222\n  User admin\n'
          'Host web\n  HostName 10.0.0.5\n  ProxyJump gw.corp\n',
        ),
        {
          'web': ['admin@gw.corp:2222', 'me@10.0.0.5:22'],
        },
      );
      // A first hop's own ProxyJump applies, from whichever block.
      expect(
        _dials(
          'Host *.internal\n  ProxyJump gw\n'
          'Host web\n  ProxyJump db.internal\n',
        ),
        {
          'web': ['me@gw:22', 'me@db.internal:22', 'me@web:22'],
        },
      );
    });

    test('reads a ProxyJump from the whole rest of its line, and leaves out '
        'a hop with whitespace or quotes', () {
      // ssh hands ProxyJump the rest of the line as written, quotes and
      // all, and runs the hops through /bin/sh.
      final result = importedHostsFromSshConfig(
        'Host spaced\n  ProxyJump a ,b\n'
        'Host quoted\n  ProxyJump "a, b"\n'
        'Host bare\n  ProxyJump = a,b # two hops\n',
      );

      expect(result.hosts.map((h) => (h.alias, h.proxyJump)), [
        ('bare', 'a,b # two hops'),
      ]);
      expect(result.skippedCount, 2);
    });

    test('leaves out a route ssh refuses as a jumphost loop', () {
      // ssh.c exits when the jump host as written is the host it would
      // dial next, on the same port (the hop's own, else 22) and as the
      // same user (the hop's own, else that host's). Every nested ssh
      // checks its own jump host, so this holds at every hop.
      List<String> kept(String config) => [
        for (final host in importedHostsFromSshConfig(config).hosts) host.alias,
      ];

      expect(kept('Host a\n  HostName 10.0.0.1\n  ProxyJump 10.0.0.1\n'), []);
      // The hop's port and user as written count, not gw's own Port.
      expect(
        kept(
          'Host gw\n  HostName 10.0.0.1\n  Port 2222\n'
          'Host a\n  HostName gw\n  ProxyJump gw\n',
        ),
        ['gw'],
      );
      expect(
        kept(
          'Host a\n  HostName 10.0.0.1\n  User root\n'
          '  ProxyJump root@10.0.0.1:22\n',
        ),
        [],
      );
      // An address compares by value: ssh writes the host it dials in
      // canonical form.
      expect(
        kept('Host v6\n  HostName 2001:0db8::1\n  ProxyJump [2001:db8::1]\n'),
        [],
      );
      // A hop before the last: the nested ssh for gw jumps through
      // 10.0.0.1, which is where gw is.
      expect(
        kept(
          'Host gw\n  HostName 10.0.0.1\n'
          'Host t\n  HostName 10.9.9.9\n  ProxyJump 10.0.0.1,gw\n',
        ),
        ['gw'],
      );
      // Not loops: another port, another user, or another spelling.
      expect(
        kept(
          'Host port\n  HostName 10.0.0.1\n  ProxyJump 10.0.0.1:2222\n'
          'Host user\n  HostName 10.0.0.1\n  User root\n'
          '  ProxyJump admin@10.0.0.1\n'
          'Host case\n  HostName gw\n  ProxyJump GW\n',
        ),
        ['port', 'user', 'case'],
      );
      // With no User, ssh compares the hop's user with the local account,
      // which the import does not know.
      expect(
        kept('Host a\n  HostName 10.0.0.1\n  ProxyJump admin@10.0.0.1\n'),
        [],
      );
    });

    test('leaves out a host whose route is a ProxyCommand, which the engine '
        'cannot run', () {
      // Whichever of ProxyCommand and ProxyJump ssh reads first is the
      // route, and `none` is direct.
      final result = importedHostsFromSshConfig(
        'Host command\n  HostName 10.0.0.5\n'
        '  ProxyCommand ssh -W %h:%p bastion\n'
        'Host command-first\n  ProxyCommand nc -X connect %h %p\n'
        '  ProxyJump gw\n'
        'Host jump-first\n  ProxyJump gw\n  ProxyCommand nc %h %p\n'
        'Host none\n  ProxyCommand none\n'
        'Host behind\n  ProxyJump command\n'
        'Host *.ssm\n  ProxyCommand aws ssm start-session --target %h\n'
        'Host db.ssm\n',
      );

      expect(result.hosts.map((h) => (h.alias, h.proxyJump)), [
        ('jump-first', 'gw'),
        ('none', null),
      ]);
      // command, command-first, behind (through command) and db.ssm.
      expect(result.skippedCount, 4);
    });

    test('an Include leaves out every host whose settings it could '
        'change', () {
      // The engine opens no included file. One could set any value a
      // host has not fixed when ssh reads it, or hold a `Match final`,
      // after which ssh reads the config again for every host.
      final top = importedHostsFromSshConfig(
        'Include ~/.ssh/config.d/*\n'
        'Host web\n  HostName 10.0.0.5\n',
      );
      expect(top.hosts, isEmpty);
      expect(top.skippedCount, 1);

      final inside = importedHostsFromSshConfig(
        'Host legacy\n  HostName legacy.example.com\n  Include legacy.conf\n'
        'Host partial\n  HostName p.example\n'
        'Host fixed\n  HostName f.example\n  Port 22\n  User u\n'
        '  IdentityFile ~/.ssh/k\n  ProxyJump none\n',
      );
      expect(inside.hosts.map((h) => h.alias), ['fixed']);
      expect(inside.skippedCount, 2);
    });
  });
}

/// What the engine would dial for each imported host, keyed by alias:
/// its hops, first hop first, then the host, each as `user@host:port`.
Map<String, List<String>> _dials(String config) {
  final imported = importedHostsFromSshConfig(config);
  final fleet = ImportedFleet(
    imported.hosts,
    hops: imported.hops,
    localUser: 'me',
  );
  List<String> chain(String id) {
    final config = fleet.serverConfig(id);
    if (config == null) return ['no config for $id'];

    final hop = config.jumpHostId;
    return [
      if (hop != null) ...chain(hop),
      '${config.username}@${config.host}:${config.port}',
    ];
  }

  return {
    for (final entry in fleet.entries) entry.label: chain(entry.serverId),
  };
}
