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
        'Host fine\n  User u\n',
      );

      expect(result.hosts.map((h) => h.alias), ['fine']);
      expect(result.skippedCount, 3);
    });

    test('leaves out a host whose name ssh refuses as a host name', () {
      // ssh.c's valid_hostname() refuses a name that starts with `-`, or
      // holds whitespace, a control character or one of '`"$\;&<>|(){}.
      // Lines split only at spaces and tabs, so a \v or \f stays part of
      // a Host pattern.
      final result = importedHostsFromSshConfig(
        'Host -web\n  HostName 10.0.0.5\n'
        'Host a;b\n  HostName 10.0.0.6\n'
        'Host web\v\n  HostName 10.0.0.8\n'
        'Host c\fd e\$f g\x01h i\x7fj k\\"l m(n o|p\n  HostName 10.0.0.9\n'
        'Host a!b caf\u00e9 a~b a#b a[b]\n  HostName 10.0.0.7\n',
      );

      expect(result.hosts.map((h) => h.alias), [
        'a!b',
        'caf\u00e9',
        'a~b',
        'a#b',
        'a[b]',
      ]);
      expect(result.skippedCount, 10);
    });

    test('leaves out a host whose name ssh reads as user@host or an ssh '
        'URI', () {
      // ssh.c reads a destination that starts with ssh:// as an ssh URI
      // (parse_uri() compares the scheme in this case only), and splits
      // any other at its last @, before it reads the config: `ssh me@web`
      // dials web as me, `ssh ssh://db` dials db, `ssh web@` dials an
      // empty host as web, and `ssh @web` and `ssh ssh://` exit. So no
      // such Host block applies. ssh -G (9.9p1) gives me@10.0.0.9:22 and
      // 10.0.0.7:22 for the first two, and 10.0.0.7:22 for SSH://db.
      final result = importedHostsFromSshConfig(
        'Host me@web\n  HostName 10.0.0.5\n'
        'Host ssh://db\n  HostName 10.0.0.6\n'
        'Host @web web@ ssh://\n  HostName 10.0.0.8\n'
        'Host web\n  HostName 10.0.0.9\n'
        'Host db SSH://db\n  HostName 10.0.0.7\n',
      );

      expect(result.hosts.map((h) => h.alias), ['web', 'db', 'SSH://db']);
      expect(result.skippedCount, 5);
    });

    test('a ProxyJump or CanonicalizeHostname line ssh rejects anywhere '
        'leaves out every host', () {
      // parse_jump() checks every ProxyJump line, in a block that applies
      // or not, and readconf.c every CanonicalizeHostname value; ssh
      // rejects the whole config over one (each checked with OpenSSH
      // 9.9p1's `ssh -G`).
      for (final line in [
        'ProxyJump',
        'ProxyJump ==',
        'ProxyJump a,,b',
        'ProxyJump a,b,',
        'ProxyJump #old',
        'ProxyJump "a, b"',
        'ProxyJump "gw',
        'ProxyJump @gw',
        'ProxyJump [gw',
        'ProxyJump [gw]x',
        'ProxyJump gw/2222',
        'ProxyJump gw:0',
        'ProxyJump gw:65536',
        'ProxyJump 2001:db8::1',
        'ProxyJump ssh://_gw',
        'ProxyJump ssh://gw..x',
        'ProxyJump ssh://[::1]',
        'ProxyJump ssh://;x@gw',
        'ProxyJump ssh://u%zz@gw',
        'ProxyJump ssh://gw/path',
        'ProxyJump ssh://gw:22/x',
        'ProxyJump ssh://gw:/',
        'ProxyJump gw,ssh://_x',
        'CanonicalizeHostname',
        'CanonicalizeHostname maybe',
        'CanonicalizeHostname yes no',
      ]) {
        for (final config in [
          'Host web\n  HostName 10.0.0.5\n'
              'Host *.unused\n  $line\n'
              'Host db\n  HostName 10.0.0.6\n',
          // After the value it would set is set.
          'Host web\n  HostName 10.0.0.5\n  ProxyJump none\n'
              '  CanonicalizeHostname no\n  $line\n'
              'Host db\n  HostName 10.0.0.6\n',
        ]) {
          final result = importedHostsFromSshConfig(config);

          expect(result.hosts, isEmpty, reason: config);
          expect(result.skippedCount, 2, reason: config);
        }
      }

      // Forms ssh accepts, though the engine follows not all of them.
      for (final line in [
        'ProxyJump NONE',
        'ProxyJump none # old',
        'ProxyJump = = gw',
        'ProxyJump a ,b',
        'ProxyJump gw:',
        'ProxyJump gw:+22',
        'ProxyJump [gw]:ssh',
        'ProxyJump u@[]',
        'ProxyJump x@y@gw',
        'ProxyJump ssh://9gw.',
        'ProxyJump ssh://u;x@gw:',
        'ProxyJump ssh://u%41@gw:22/',
        'CanonicalizeHostname NO',
        'CanonicalizeHostname always # c',
      ]) {
        final result = importedHostsFromSshConfig(
          'Host web\n  HostName 10.0.0.5\nHost *.unused\n  $line\n',
        );

        expect(result.hosts.map((h) => h.alias), ['web'], reason: line);
      }
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

    test('leaves out a host whose values hold bytes that are not UTF-8', () {
      // The app decodes Latin-1 é and ö as U+FFFD; ssh would dial and sign
      // in with the bytes themselves, here or for a jump host.
      final result = importedHostsFromSshConfig(
        'Host x\n  HostName caf\u{FFFD}.example\n'
        'Host y\n  User j\u{FFFD}rg\n'
        'Host z\n  IdentityFile ~/.ssh/k\u{FFFD}y\n'
        'Host behind-user\n  HostName 10.0.0.5\n  ProxyJump j\u{FFFD}rg@gw\n'
        'Host behind-y\n  HostName 10.0.0.6\n  ProxyJump y\n'
        'Host fine\n  HostName 10.0.0.7\n  ProxyJump gw\n',
      );

      expect(result.hosts.map((h) => h.alias), ['fine']);
      expect(result.skippedCount, 5);
    });

    test('a byte-order mark makes ssh reject the whole file', () {
      // ssh reads the mark's bytes as the start of the first keyword:
      // "Bad configuration option: \357\273\277host". The app keeps the
      // mark that Dart's UTF-8 decoder drops.
      final result = importedHostsFromSshConfig(
        '\u{FEFF}Host web\n  HostName 10.0.0.5\nHost db\n',
      );

      expect(result.hosts, isEmpty);
      expect(result.skippedCount, 2);
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

      // One host per line, each with a route ssh reads otherwise. A
      // ProxyJump ssh rejects leaves out every host (above).
      final result = importedHostsFromSshConfig(
        'Host service\n  ProxyJump jump:ssh\n'
        'Host token\n  ProxyJump %h-jump\n'
        'Host fine\n  ProxyJump jump\n',
      );
      expect(result.hosts.map((h) => h.alias), ['fine']);
      expect(result.skippedCount, 2);

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
      String names(String prefix, int count) =>
          [for (var index = 1; index <= count; index++) '$prefix$index']
              .join(',');
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
          'Host * !bastion !bastion.example.com\n  ProxyJump bastion\n'
          'Host bastion\n  HostName bastion.example.com\n'
          'Host prod-web\n  HostName 10.0.0.5\n';

      expect(_dials(config), {
        'bastion': ['me@bastion.example.com:22'],
        'prod-web': ['me@bastion.example.com:22', 'me@10.0.0.5:22'],
      });
      expect(importedHostsFromSshConfig(config).skippedCount, 0);
    });

    test('a final pass that would route a host through itself keeps the '
        'first pass', () {
      // The final pass that /etc/ssh/ssh_config may ask for (Fedora's and
      // RHEL's do) matches `*` against bastion.example.com and routes
      // bastion through itself, or into ssh's jumphost loop. ssh cannot
      // reach bastion that way, so that pass is not the route ssh takes.
      for (final jump in ['bastion', 'bastion.example.com']) {
        final config =
            'Host * !bastion\n  ProxyJump $jump\n'
            'Host bastion\n  HostName bastion.example.com\n'
            'Host prod-web\n  HostName 10.0.0.5\n';

        expect(_dials(config)['bastion'], [
          'me@bastion.example.com:22',
        ], reason: config);
      }
      const common =
          'Host * !bastion\n  ProxyJump bastion\n'
          'Host bastion\n  HostName bastion.example.com\n'
          'Host prod-web\n  HostName 10.0.0.5\n';
      expect(_dials(common), {
        'bastion': ['me@bastion.example.com:22'],
        'prod-web': ['me@bastion.example.com:22', 'me@10.0.0.5:22'],
      });
      expect(importedHostsFromSshConfig(common).skippedCount, 0);

      // Two valid routes: direct, or through gw on that pass.
      final twoRoutes = importedHostsFromSshConfig(
        'Host web\n  HostName 10.0.0.5\n'
        'Host 10.0.0.*\n  ProxyJump gw\n'
        'Host gw\n  HostName gw.example.com\n',
      );
      expect(twoRoutes.hosts.map((h) => h.alias), ['gw']);
      expect(twoRoutes.skippedCount, 1);

      // With no User, ssh compares a jump's own user with the local
      // account, which the import does not know: not certainly a loop.
      final unknownUser = importedHostsFromSshConfig(
        'Match originalhost bastion.example.com\n  ProxyJump none\n'
        'Host * !bastion\n  ProxyJump admin@bastion.example.com\n'
        'Host bastion\n  HostName bastion.example.com\n',
      );
      expect(unknownUser.hosts, isEmpty);
      expect(unknownUser.skippedCount, 1);
    });

    test('a hop keeps its first pass only where its final pass would loop '
        'there too', () {
      // Reached as itself, bastion's final pass routes it through
      // bastion.example.com, a jumphost loop, so bastion keeps its first
      // pass. As a later hop the nested ssh gets -J, which overrides that
      // route but not the final pass's User, so ssh takes that pass there.
      const later =
          'Host *.example.com\n  User ops\n  ProxyJump bastion.example.com\n'
          'Host bastion\n  HostName bastion.example.com\n'
          'Host gw\n  HostName 10.0.0.9\n'
          'Host web\n  HostName 10.0.0.5\n  ProxyJump gw,bastion\n'
          'Host web2\n  HostName 10.0.0.6\n  ProxyJump gw,ops@bastion\n';
      expect(_dials(later), {
        'bastion': ['me@bastion.example.com:22'],
        'gw': ['me@10.0.0.9:22'],
        // The hop's own user is the one both passes give.
        'web2': [
          'me@10.0.0.9:22',
          'ops@bastion.example.com:22',
          'me@10.0.0.6:22',
        ],
      });
      expect(importedHostsFromSshConfig(later).skippedCount, 1);

      // The final pass's Port and IdentityFile count there too: behind gw,
      // ssh's final pass dials bastion.example.com on 2200, or with k9.
      for (final setting in [
        'Port 2200\n  ProxyJump bastion.example.com:2200',
        'IdentityFile ~/.ssh/k9\n  ProxyJump bastion.example.com',
      ]) {
        final config =
            'Host *.example.com\n  $setting\n'
            'Host bastion\n  HostName bastion.example.com\n'
            'Host gw\n  HostName 10.0.0.9\n'
            'Host web\n  HostName 10.0.0.5\n  ProxyJump gw,bastion\n';
        expect(_dials(config), {
          'bastion': ['me@bastion.example.com:22'],
          'gw': ['me@10.0.0.9:22'],
        }, reason: config);
        expect(
          importedHostsFromSshConfig(config).skippedCount,
          1,
          reason: config,
        );
      }

      // The hop's own port comes first, so both passes dial bastion on
      // 2222.
      expect(
        _dials(
          'Host *.example.com\n'
          '  Port 2200\n  ProxyJump bastion.example.com:2200\n'
          'Host bastion\n  HostName bastion.example.com\n'
          'Host gw\n  HostName 10.0.0.9\n'
          'Host web\n  HostName 10.0.0.5\n  ProxyJump gw,bastion:2222\n',
        )['web'],
        ['me@10.0.0.9:22', 'me@bastion.example.com:2222', 'me@10.0.0.5:22'],
      );

      // As a first hop on another port, the loop test no longer matches.
      const firstHop =
          'Match originalhost bastion.example.com\n  ProxyJump none\n'
          'Host *.example.com\n  ProxyJump bastion.example.com\n'
          'Host bastion\n  HostName bastion.example.com\n'
          'Host web\n  HostName 10.0.0.5\n  ProxyJump bastion:2222\n'
          'Host web2\n  HostName 10.0.0.6\n  ProxyJump bastion\n';
      expect(_dials(firstHop), {
        'bastion': ['me@bastion.example.com:22'],
        'web2': ['me@bastion.example.com:22', 'me@10.0.0.6:22'],
      });
      expect(importedHostsFromSshConfig(firstHop).skippedCount, 1);

      // Nor as another user: as u2, bastion's final pass jumps through
      // u1@bastion.example.com, which ssh takes, so web has two routes.
      // As u1 that jump is the loop.
      const firstHopUser =
          'Match originalhost bastion.example.com\n  ProxyJump none\n'
          'Host *.example.com\n  User u1\n  ProxyJump u1@bastion.example.com\n'
          'Host bastion\n  HostName bastion.example.com\n'
          'Host web\n  HostName 10.0.0.5\n  ProxyJump u2@bastion\n'
          'Host db\n  HostName 10.0.0.6\n  ProxyJump u1@bastion\n';
      expect(_dials(firstHopUser), {
        'bastion': ['me@bastion.example.com:22'],
        'db': ['u1@bastion.example.com:22', 'me@10.0.0.6:22'],
      });
      expect(importedHostsFromSshConfig(firstHopUser).skippedCount, 1);

      // A final pass that routes bastion back through itself loops on
      // any port.
      expect(
        _dials(
          'Host prod-web\n  HostName 10.0.0.5\n  ProxyJump bastion:2222\n'
          'Host * !bastion\n  ProxyJump bastion\n'
          'Host bastion\n  HostName bastion.example.com\n',
        )['prod-web'],
        ['me@bastion.example.com:2222', 'me@10.0.0.5:22'],
      );
    });

    test('a hop\'s final pass counts only where ssh\'s final pass reaches '
        'the hop', () {
      // bastion and bastion2 keep their first pass: on their final pass
      // both jump through bastion.example.com, which jumps through itself.
      const loops =
          'Host *.example.com\n  User ops\n  ProxyJump bastion.example.com\n'
          'Host bastion\n  HostName bastion.example.com\n'
          'Host bastion2\n  HostName b2.example.com\n';

      // As a later hop, bastion2's final pass gives User ops, but ssh's
      // final pass already fails at bastion, the first hop, so ssh reaches
      // bastion2 only on its first pass.
      const behindFirstHop =
          '${loops}Host web\n  HostName 10.0.0.5\n'
          '  ProxyJump bastion,bastion2\n';
      expect(_dials(behindFirstHop)['web'], [
        'me@bastion.example.com:22',
        'me@b2.example.com:22',
        'me@10.0.0.5:22',
      ]);
      expect(importedHostsFromSshConfig(behindFirstHop).skippedCount, 0);

      // The same where the first hop's own route holds only by looping.
      const behindUpstream =
          '${loops}Host gw\n  HostName gw.internal\n  ProxyJump bastion\n'
          'Host web\n  HostName 10.0.0.5\n  ProxyJump gw,bastion2\n';
      expect(_dials(behindUpstream)['web'], [
        'me@bastion.example.com:22',
        'me@gw.internal:22',
        'me@b2.example.com:22',
        'me@10.0.0.5:22',
      ]);
      expect(importedHostsFromSshConfig(behindUpstream).skippedCount, 0);

      // web's final pass gives it Port 2222, where its last hop is a
      // jumphost loop, so web keeps its first pass, and ssh's final pass
      // fails before any of its hops.
      const ownPass =
          '${loops}Host 10.0.0.*\n  Port 2222\n'
          'Host gw\n  HostName gw.internal\n'
          'Host web\n  HostName 10.0.0.5\n'
          '  ProxyJump gw,bastion2,10.0.0.5:2222\n';
      expect(_dials(ownPass)['web'], [
        'me@gw.internal:22',
        'me@b2.example.com:22',
        'me@10.0.0.5:2222',
        'me@10.0.0.5:22',
      ]);
      expect(importedHostsFromSshConfig(ownPass).skippedCount, 0);

      // x is left out: ssh's final pass reaches bastion2 behind gw, as
      // ops. So is web, which names x, although ssh's final pass fails
      // at web: the import keeps no settings for a host it leaves out.
      const leftOutFirstHop =
          '${loops}Host 10.0.0.*\n  Port 2222\n'
          'Host gw\n  HostName gw.internal\n'
          'Host x\n  HostName x.internal\n  ProxyJump gw,bastion2\n'
          'Host web\n  HostName 10.0.0.5\n  ProxyJump x,10.0.0.5:2222\n';
      expect(_dials(leftOutFirstHop).keys, ['bastion', 'bastion2', 'gw']);

      // The same where the first hop is a hop record, which the import
      // would store: gw.internal's own route counts as where ssh dials
      // it as itself, and there the final pass reaches bastion2 as ops.
      // Plain ssh reaches web, so leaving it out is conservative.
      const leftOutRecord =
          '${loops}Host 10.0.0.*\n  Port 2222\n'
          'Host *.internal\n  ProxyJump h0.lan,bastion2\n'
          'Host web\n  HostName 10.0.0.5\n'
          '  ProxyJump gw.internal,10.0.0.5:2222\n';
      expect(_dials(leftOutRecord).keys, ['bastion', 'bastion2']);

      // bastion2's final pass gives it User ops without a loop, so it is
      // left out, and so is web, which names it, although ssh's final
      // pass fails at bastion first and plain ssh reaches web through
      // bastion2's first pass. That is conservative.
      const leftOutLaterHop =
          'Host *.example.com\n  User ops\n'
          'Host *.example.com !b2.example.com\n'
          '  ProxyJump bastion.example.com\n'
          'Host bastion\n  HostName bastion.example.com\n'
          'Host bastion2\n  HostName b2.example.com\n'
          'Host web\n  HostName 10.0.0.5\n  ProxyJump bastion,bastion2\n';
      expect(_dials(leftOutLaterHop).keys, ['bastion']);
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
        importedHostsFromSshConfig('User everyone\nHost web\n  User deploy\n')
            .hosts
            .single
            .user,
        'everyone',
      );
      // So does a `Host *` key at the top: ssh offers the host's own key
      // next, which the engine, holding one key, does not (03 §10.1).
      expect(
        importedHostsFromSshConfig(
          'Host *\n  IdentityFile ~/.ssh/id_ed25519\n'
          'Host gh\n  HostName github.com\n  IdentityFile ~/.ssh/gh\n',
        ).hosts.single.identityFile,
        '~/.ssh/id_ed25519',
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
      // That hop is a record of its own, resolved and stored: only
      // another hop record's route names it.
      const nested =
          'Host *.internal\n  ProxyJump gw.corp\n'
          'Host *.corp\n  Port 2222\n  User admin\n'
          'Host web\n  ProxyJump db.internal\n';
      expect(_dials(nested), {
        'web': ['admin@gw.corp:2222', 'me@db.internal:22', 'me@web:22'],
      });
      expect(
        importedHostsFromSshConfig(nested).hops
            .map((h) => (h.alias, h.port, h.user, h.proxyJump)),
        [
          ('db.internal', 22, null, 'gw.corp'),
          ('gw.corp', 2222, 'admin', null),
        ],
      );
    });

    test('reads a ProxyJump from the whole rest of its line, and leaves out '
        'a hop with whitespace or quotes', () {
      // ssh hands ProxyJump the rest of the line as written, quotes and
      // all, and runs the hops through /bin/sh.
      final result = importedHostsFromSshConfig(
        'Host spaced\n  ProxyJump a ,b\n'
        'Host quoted\n  ProxyJump "a,b"\n'
        'Host bare\n  ProxyJump = a,b # two hops\n',
      );

      expect(result.hosts.map((h) => (h.alias, h.proxyJump)), [
        ('bare', 'a,b # two hops'),
      ]);
      expect(result.skippedCount, 2);
    });

    test('keeps Unicode whitespace at the end of a ProxyJump hop', () {
      // parse_jump()'s rtrim() drops only ASCII whitespace, so U+00A0 is
      // part of the hop's name, which `Host gw` does not match.
      expect(
        _dials(
          'Host web\n  HostName 10.0.0.5\n  ProxyJump gw\u00A0\n'
          'Host gw\n  HostName gw.example.com\n',
        )['web'],
        ['me@gw\u00A0:22', 'me@10.0.0.5:22'],
      );
    });

    test('leaves out a ProxyJump whose comment holds a comma', () {
      // parse_jump() drops the comment before it splits the hops, but
      // cuts the hops it hands the nested ssh with -J from the value as
      // written, at its last comma. `ssh -J bastion # old -W ... bastion`
      // reaches /bin/sh, which drops the destination with the comment;
      // `-J a#x` adds a second hop to a.
      final result = importedHostsFromSshConfig(
        'Host spaced\n  HostName 10.0.0.5\n  ProxyJump bastion # old,new\n'
        'Host tight\n  ProxyJump a#x,b\n'
        'Host fine\n  ProxyJump a,b # two hops\n',
      );

      expect(result.hosts.map((h) => h.alias), ['fine']);
      expect(result.skippedCount, 2);
    });

    test('leaves out a ProxyJump whose first hop of several is none', () {
      // ssh hands the nested ssh the hops before the last as written, with
      // -J, and `-J none` means no jump: ssh reaches gw directly, without
      // gw's own route, and not through a host named none. With three
      // hops, the nested ssh for gw hands on `-J none` in turn.
      final result = importedHostsFromSshConfig(
        'Host web\n  HostName 10.0.0.5\n  ProxyJump none,gw\n'
        'Host web2\n  HostName 10.0.0.6\n  ProxyJump NONE,gw\n'
        'Host web3\n  HostName 10.0.0.7\n  ProxyJump none,a,gw\n'
        'Host gw\n  HostName 10.0.0.9\n  ProxyJump bastion\n'
        'Host bastion\n  HostName 10.0.0.1\n',
      );

      expect(result.hosts.map((h) => h.alias), ['gw', 'bastion']);
      expect(result.skippedCount, 3);
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
      // ssh compares the jump as written with the host it dials, which it
      // writes as getnameinfo() does when it is an address, unless only
      // its case would change.
      for (final (hostName, jump, loops) in [
        ('2001:0db8::1', '2001:db8::1', true),
        ('2001:db8::1', '2001:0db8::1', false),
        ('2001:0DB8::1', '2001:0DB8::1', false),
        ('2001:DB8::1', '2001:db8::1', false),
        ('2001:DB8::1', '2001:DB8::1', true),
        // The system resolver may read `10.1` as 10.0.0.1, which Dart
        // cannot tell, so any address counts.
        ('10.1', '10.0.0.1', true),
        ('10.1', 'gw', false),
      ]) {
        final config = 'Host v6\n  HostName $hostName\n  ProxyJump [$jump]\n';
        expect(kept(config), loops ? isEmpty : ['v6'], reason: config);
      }
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
