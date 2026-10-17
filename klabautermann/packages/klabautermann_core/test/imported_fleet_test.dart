import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/fleet/imported_fleet.dart';
import 'package:klabautermann_core/src/fleet/jump_routes.dart';
import 'package:klabautermann_core/src/fleet/ssh_config_entries.dart';
import 'package:seance_core/seance_core.dart'
    show
        AuthMethod,
        CredentialDraft,
        CredentialResolver,
        CredentialSource,
        ImportedHost,
        Secret,
        ServerConfig,
        serverSearchHaystack;
import 'package:test/test.dart';

import 'fixtures/ssh_config_fixture.dart';

ImportedFleet _fleet(String config, {String? localUser = 'me'}) {
  final imported = importedHostsFromSshConfig(config);
  return ImportedFleet(
    imported.hosts,
    hops: imported.hops,
    localUser: localUser,
  );
}

Map<String, FleetEntry> _byLabel(ImportedFleet fleet) => {
  for (final entry in fleet.entries) entry.label: entry,
};

/// A key source that reads no file.
final class _Keys implements CredentialSource {
  @override
  Future<Secret?> storedSecret(String secretRef) async => null;

  @override
  Future<String> identityFile(ServerConfig config, CredentialDraft? draft) =>
      Future.value('pem of ${config.identityFilePath}');
}

void main() {
  group('localUserName', () {
    test('reads USER, then USERNAME, and ignores empty values', () {
      expect(localUserName({'USER': 'ann', 'USERNAME': 'bob'}), 'ann');
      expect(localUserName({'USER': '', 'USERNAME': 'bob'}), 'bob');
      expect(localUserName({'USERNAME': ''}), isNull);
      expect(localUserName({}), isNull);
    });
  });

  group('ImportedFleet (03 §4.6, §10.1)', () {
    test('lists every host with its fields filled', () {
      final fleet = _fleet(sshConfigFixture);
      final entries = _byLabel(fleet);

      expect(fleet.entries.map((e) => e.label), sshConfigFixtureEntries);
      for (final entry in fleet.entries) {
        expect(entry.serverId, 'ssh-config:${entry.label}');
        expect(entry.origin, FleetEntryOrigin.sshConfig);
        expect(entry.group, isNull, reason: 'ssh_config has no groups');
        final config = fleet.serverConfig(entry.serverId)!;
        expect(entry.searchText, serverSearchHaystack(config));
      }
      expect(entries['web-1']!.authKind, FleetAuthKind.identityFile);
      expect(entries['web-1']!.jumpRoute, isNull);
      expect(entries['db-1']!.authKind, FleetAuthKind.agent);
      expect(entries['bastion']!.jumpRoute, ['jump.example']);
      expect(entries['db-1']!.locatorConflict, isNull);
      expect(() => fleet.entries.add(entries['v6']!), throwsUnsupportedError);
    });

    test('maps each host to a ServerConfig, the local user filling in a '
        'missing User', () {
      final fleet = _fleet(sshConfigFixture);

      final web = fleet.serverConfig('ssh-config:web-1')!;
      expect(
        (web.host, web.port, web.username, web.authMethod),
        ('web-1.example.com', 2222, 'deploy', AuthMethod.privateKey),
      );
      expect(web.identityFilePath, '~/.ssh/id_ed25519');
      expect(web.jumpHostId, isNull);

      final db = fleet.serverConfig('ssh-config:db-1')!;
      expect((db.username, db.authMethod), ('me', AuthMethod.agent));
      // The rail shows what the config names.
      expect(_byLabel(fleet)['db-1']!.user, isNull);
      expect(_byLabel(fleet)['db-1']!.searchText, contains('me@10.0.0.4'));

      expect(fleet.serverConfig('db-1'), isNull);
    });

    test('without a local user, a host or hop that needs one has no '
        'config', () {
      final fleet = _fleet(
        'Host a\n  User u\n  ProxyJump j\n'
        'Host b\n  User u\n  ProxyJump v@j\n'
        'Host c\n',
        localUser: null,
      );

      expect(fleet.entries, hasLength(3), reason: 'still listed');
      expect(fleet.serverConfig('ssh-config:a'), isNull);
      expect(fleet.serverConfig('ssh-config-hop:j'), isNull);
      expect(fleet.serverConfig('ssh-config:b')?.username, 'u');
      expect(fleet.serverConfig('ssh-config-hop:v@j')?.username, 'v');
      expect(fleet.serverConfig('ssh-config:c'), isNull);

      // A connect to a host without a config says why (D61): here, the
      // login name of the host or of a hop on its route.
      expect(
        [
          for (final id in ['a', 'b', 'c'])
            fleet.missingConfigReason('ssh-config:$id'),
        ],
        [
          ConnectRejectedReason.noLoginName,
          null,
          ConnectRejectedReason.noLoginName,
        ],
      );
      expect(
        fleet.missingConfigReason('ssh-config-hop:j'),
        isNull,
        reason: 'a hop is no fleet server',
      );
      expect(fleet.missingConfigReason('ssh-config:gone'), isNull);
    });

    test('maps a ProxyJump chain to hop configs, each through the one '
        'before', () {
      final fleet = _fleet(
        'Host t\n  HostName 10.0.0.9\n  ProxyJump ops@a.example:2200,b.example\n',
      );

      expect(_byLabel(fleet)['t']!.jumpRoute, [
        'ops@a.example:2200',
        'b.example',
      ]);
      final target = fleet.serverConfig('ssh-config:t')!;
      expect(target.jumpHostId, 'ssh-config-hop:ops@a.example:2200,b.example');

      final last = fleet.serverConfig(target.jumpHostId!)!;
      expect(
        (last.host, last.port, last.username, last.authMethod),
        ('b.example', 22, 'me', AuthMethod.agent),
      );
      expect(last.label, 'b.example');
      expect(last.jumpHostId, 'ssh-config-hop:ops@a.example:2200');

      final first = fleet.serverConfig(last.jumpHostId!)!;
      expect(
        (first.host, first.port, first.username, first.jumpHostId),
        ('a.example', 2200, 'ops', null),
      );
    });

    test('a hop that names an alias takes its settings, its own user and '
        'port first', () {
      final fleet = _fleet(
        'Host bastion\n  HostName 203.0.113.5\n  Port 2222\n  User admin\n'
        '  IdentityFile ~/.ssh/jump\n'
        'Host t\n  ProxyJump bastion\n'
        'Host u\n  ProxyJump root@bastion:22\n',
      );

      final viaAlias = fleet.serverConfig('ssh-config-hop:bastion')!;
      expect(
        (viaAlias.host, viaAlias.port, viaAlias.username),
        ('203.0.113.5', 2222, 'admin'),
      );
      expect(viaAlias.authMethod, AuthMethod.privateKey);
      expect(viaAlias.identityFilePath, '~/.ssh/jump');

      final overridden = fleet.serverConfig('ssh-config-hop:root@bastion:22')!;
      expect(
        (overridden.host, overridden.port, overridden.username),
        ('203.0.113.5', 22, 'root'),
      );
      expect(overridden.identityFilePath, '~/.ssh/jump');
    });

    test('only the first hop\'s own ProxyJump applies', () {
      final fleet = _fleet(
        'Host outer\n  ProxyJump gw\n'
        'Host inner\n  HostName 10.1.0.1\n  ProxyJump other\n'
        'Host t1\n  ProxyJump outer\n'
        'Host t2\n  ProxyJump x,inner\n',
      );
      final entries = _byLabel(fleet);

      // ssh reaches `outer` with its own config, ProxyJump included.
      expect(entries['t1']!.jumpRoute, ['gw', 'outer']);
      expect(
        fleet.serverConfig('ssh-config-hop:gw,outer')!.jumpHostId,
        'ssh-config-hop:gw',
      );
      // A later hop gets `-J x`, which overrides its own ProxyJump.
      expect(entries['t2']!.jumpRoute, ['x', 'inner']);
      expect(fleet.serverConfig('ssh-config-hop:x,inner')!.host, '10.1.0.1');
      expect(entries['inner']!.jumpRoute, ['other']);
    });

    test('HostName %h dials each alias, for the host, its hops and its '
        'locator', () {
      final fleet = _fleet(
        'Host web1\n  HostName %h.example.com\n'
        'Host web2\n  HostName %h.example.com\n  ProxyJump gw\n'
        'Host t\n  ProxyJump web1\n',
      );
      final entries = _byLabel(fleet);

      expect(fleet.serverConfig('ssh-config:web1')!.host, 'web1.example.com');
      expect(entries['web2']!.host, 'web2.example.com');
      expect(entries['web1']!.searchText, contains('me@web1.example.com:22'));
      expect(
        fleet.serverConfig('ssh-config-hop:web1')!.host,
        'web1.example.com',
      );
      // Different machines, so no shared pin.
      expect(entries['web1']!.locatorConflict, isNull);
      expect(entries['web2']!.locatorConflict, isNull);
    });

    test('IdentityFile none signs in with the agent', () {
      final fleet = _fleet(
        'Host n\n  IdentityFile NONE\n'
        'Host t\n  ProxyJump n\n',
      );

      expect(_byLabel(fleet)['n']!.authKind, FleetAuthKind.agent);
      for (final id in ['ssh-config:n', 'ssh-config-hop:n']) {
        final config = fleet.serverConfig(id)!;
        expect(config.authMethod, AuthMethod.agent, reason: id);
        expect(config.identityFilePath, isNull, reason: id);
      }
    });

    test('ProxyJump none is a direct connection', () {
      final fleet = _fleet('Host d\n  ProxyJump NONE\n');

      expect(fleet.entries.single.jumpRoute, isNull);
      expect(fleet.serverConfig('ssh-config:d')!.jumpHostId, isNull);
    });

    test('hop ids are the same on every import and shared by routes', () {
      const config =
          'Host a\n  ProxyJump j,k\n'
          'Host b\n  ProxyJump j\n';
      List<String?> hopIds(ImportedFleet fleet) => [
        for (final entry in fleet.entries)
          fleet.serverConfig(entry.serverId)!.jumpHostId,
      ];

      expect(hopIds(_fleet(config)), [
        'ssh-config-hop:j,k',
        'ssh-config-hop:j',
      ]);
      expect(hopIds(_fleet(config)), hopIds(_fleet(config)));
      expect(
        _fleet(config).serverConfig('ssh-config-hop:j,k')!.jumpHostId,
        'ssh-config-hop:j',
      );
    });

    test('an endpoint changes with any address, port or login name on '
        'the way to a host', () {
      const host = 'ssh-config:a';
      const config =
          'Host a\n  HostName 192.0.2.1\n  ProxyJump j\n'
          'Host j\n  HostName 192.0.2.9\n';
      final endpoint = _fleet(config).endpointOf(host);

      expect(endpoint, isNotNull);
      expect(_fleet('${config}Host b\n').endpointOf(host), endpoint);
      for (final changed in [
        config.replaceFirst('192.0.2.1', '192.0.2.2'),
        config.replaceFirst('192.0.2.9', '192.0.2.8'),
        config.replaceFirst('  ProxyJump', '  Port 2222\n  ProxyJump'),
        config.replaceFirst('192.0.2.9', '192.0.2.9\n  User jumper'),
        'Host a\n  HostName 192.0.2.1\n',
      ]) {
        expect(
          _fleet(changed).endpointOf(host),
          isNot(endpoint),
          reason: changed,
        );
      }
      expect(
        _fleet(config, localUser: 'you').endpointOf(host),
        isNot(endpoint),
      );
      expect(_fleet(config).endpointOf('ssh-config:missing'), isNull);
    });

    test(
      'serves its hops through CredentialResolver.jumpHostResolver',
      () async {
        final fleet = _fleet(
          'Host gw\n  HostName 198.51.100.1\n  IdentityFile ~/.ssh/gw\n'
          'Host t\n  ProxyJump gw,inner.example\n',
        );
        final resolve = CredentialResolver(
          _Keys(),
        ).jumpHostResolver((id) async => fleet.serverConfig(id));

        final route = <String>[];
        var next = fleet.serverConfig('ssh-config:t')!.jumpHostId;
        while (next != null) {
          final hop = (await resolve(next))!;
          expect(hop.config.id, next);
          route.add('${hop.config.host} ${hop.credentials.method.name}');
          next = hop.config.jumpHostId;
        }
        expect(route, ['inner.example agent', '198.51.100.1 privateKey']);
        expect(await resolve('ssh-config-hop:unknown'), isNull);
      },
    );

    test('hosts with addresses only are listed without a route, a sign-in '
        'or a config', () {
      // A schema 1 store: whether `db` had a ProxyJump or IdentityFile is
      // unknown, so the engine claims neither and dials nothing.
      final fleet = ImportedFleet(
        const [
          ImportedHost(alias: 'db', hostName: '10.0.0.5', port: 22),
          ImportedHost(alias: 'lan', hostName: '10.0.0.5', port: 22),
        ],
        localUser: 'me',
        detail: ImportedHostDetail.addressOnly,
      );

      final entry = fleet.entries.first;
      expect(
        (entry.serverId, entry.host, entry.port),
        ('ssh-config:db', '10.0.0.5', 22),
      );
      expect(entry.jumpRoute, isNull);
      expect(entry.authKind, isNull);
      expect(entry.searchText, contains('10.0.0.5'));
      expect(entry.locatorConflict, isNull);
      expect(fleet.serverConfig('ssh-config:db'), isNull);
      expect(
        fleet.missingConfigReason('ssh-config:db'),
        ConnectRejectedReason.addressOnlyImport,
      );
    });

    test('flags servers at one locator behind different routes', () {
      final entries = _byLabel(
        _fleet(
          'Host lan\n  HostName 10.0.0.5\n'
          'Host vpn\n  HostName 10.0.0.5\n  ProxyJump gw\n'
          // The same jump host as another user is the same route.
          'Host vpn-root\n  HostName 10.0.0.5\n  ProxyJump root@gw\n'
          'Host other-port\n  HostName 10.0.0.5\n  Port 2200\n  ProxyJump gw\n',
        ),
      );

      expect(entries['lan']!.locatorConflict, [
        'ssh-config:vpn',
        'ssh-config:vpn-root',
      ]);
      expect(entries['vpn']!.locatorConflict, ['ssh-config:lan']);
      expect(entries['vpn-root']!.locatorConflict, ['ssh-config:lan']);
      expect(entries['other-port']!.locatorConflict, isNull);
    });

    test('flags a jump hop at one locator with a server or hop behind '
        'another route', () {
      // Séance checks every hop's host key under its own `host:port`.
      final entries = _byLabel(
        _fleet(
          'Host lan\n  HostName 10.0.0.1\n'
          'Host t\n  HostName 10.9.9.9\n  ProxyJump gw,10.0.0.1\n'
          'Host a\n  ProxyJump gw1,10.0.0.2\n'
          'Host b\n  ProxyJump gw2,10.0.0.2\n'
          // The same hop behind the same route is one machine.
          'Host c\n  ProxyJump gw1,10.0.0.2\n'
          // So is a direct hop and a direct server.
          'Host jumpbox\n  HostName gw1\n',
        ),
      );

      expect(entries['lan']!.locatorConflict, ['ssh-config:t']);
      expect(entries['t']!.locatorConflict, ['ssh-config:lan']);
      expect(entries['a']!.locatorConflict, ['ssh-config:b']);
      expect(entries['b']!.locatorConflict, ['ssh-config:a', 'ssh-config:c']);
      expect(entries['c']!.locatorConflict, ['ssh-config:b']);
      expect(entries['jumpbox']!.locatorConflict, isNull);
    });

    test('routes differ by a hop\'s port, and an entry never conflicts with '
        'itself', () {
      final entries = _byLabel(
        _fleet(
          // Two machines behind one address, reached through two ports.
          'Host a\n  HostName 10.0.0.5\n  ProxyJump gw\n'
          'Host b\n  HostName 10.0.0.5\n  ProxyJump gw:2222\n'
          // jump:22 is this entry's first hop and, behind it and h, its
          // server: one entry, so no conflict.
          'Host loop\n  HostName jump\n  ProxyJump jump,h\n',
        ),
      );

      expect(entries['a']!.locatorConflict, ['ssh-config:b']);
      expect(entries['b']!.locatorConflict, ['ssh-config:a']);
      expect(entries['loop']!.locatorConflict, isNull);
    });

    test('finds conflicts in linear time', () {
      // Comparing every pair took about 35 s for this many hosts, with
      // the engine isolate answering nothing meanwhile.
      const count = 40000;
      final hosts = [
        for (var index = 0; index < count; index++)
          ImportedHost(
            alias: 'h$index',
            hostName: '10.${index >> 16}.${(index >> 8) & 255}.${index & 255}',
            port: 22,
          ),
        const ImportedHost(
          alias: 'twin',
          hostName: '10.0.0.0',
          proxyJump: 'gw',
        ),
      ];
      final clock = Stopwatch()..start();

      final entries = ImportedFleet(hosts, localUser: 'me').entries;

      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
      expect(entries.first.locatorConflict, ['ssh-config:twin']);
      expect(entries.last.locatorConflict, ['ssh-config:h0']);
      expect(entries[1].locatorConflict, isNull);
    });
  });

  group('jumpRoutes', () {
    List<(String, String?, String, int)>? hops(String proxyJump) => jumpRoutes([
      ImportedHost(alias: 't', proxyJump: proxyJump),
    ])['t']?.map((h) => (h.name, h.user, h.host, h.port)).toList();

    test('reads the forms ssh accepts', () {
      // The user ends at the last `@`; brackets hold an address's colons;
      // an empty port is no port.
      expect(hops('a@b@h:2200'), [('a@b@h:2200', 'a@b', 'h', 2200)]);
      expect(hops('[2001:db8::1]:2201'), [
        ('[2001:db8::1]:2201', null, '2001:db8::1', 2201),
      ]);
      expect(hops('h:'), [('h:', null, 'h', 22)]);
      // An ssh URI drops `;` parameters and one trailing dot, and may end
      // in `/`.
      expect(hops('ssh://u;fp=1@h.example.:2202/'), [
        ('ssh://u;fp=1@h.example.:2202/', 'u', 'h.example', 2202),
      ]);
      // A `#` starts a comment.
      expect(hops('h#note'), [('h', null, 'h', 22)]);
    });

    test('refuses what ssh rejects or reads otherwise', () {
      for (final value in [
        'h:65536',
        'h:+22',
        '[h]x',
        ':22',
        'a,',
        'ssh://[2001:db8::1]',
        'ssh://h..example',
        'ssh://@h',
        // ssh puts the last hop's host in the command without brackets,
        // and the nested ssh reads it as an ssh URI: gw on port 2222.
        '[ssh://gw:2222]',
        'u@[ssh://gw]',
        'a,[ssh://gw]',
      ]) {
        expect(hops(value), isNull, reason: value);
      }
    });

    test('refuses a hop with whitespace, a quote or another character the '
        'shell reads', () {
      // ssh runs the hops as a ProxyCommand through /bin/sh, and the
      // nested ssh rejects such a host name (`valid_hostname()`) or reads
      // a leading `-` as an option.
      for (final value in [
        'a, b',
        'a ,b',
        'a b',
        '"bastion"',
        "'bastion'",
        'a;b',
        r'u$x@h',
        'h`id`',
        'a|b',
        '-oProxyCommand=x',
        '-u@h',
        'ssh://-h',
        // ssh decodes `+` in a URI's user to a space.
        'ssh://u+x@h',
        // A hop before the last reaches the shell as written.
        'ssh://u;fp=1@h,last',
      ]) {
        expect(hops(value), isNull, reason: value);
      }
      expect(hops('a,b'), hasLength(2));
      expect(hops('a,ssh://u;fp=1@h'), hasLength(2));
    });

    test('refuses a hop the shell would read as a home directory', () {
      // /bin/sh expands a word that starts with `~`: `-J ~root` and
      // `-l ~root` become /root, and so does a last hop's host.
      for (final value in [
        '~root',
        '~root,gw',
        '~root@gw',
        'gw,~root',
        'u@~gw:2222',
        'ssh://~root@gw',
      ]) {
        expect(hops(value), isNull, reason: value);
      }
      // Only a `~` at the start of a word.
      expect(hops('gw,a~b'), hasLength(2));
      expect(hops('a~b@gw'), [('a~b@gw', 'a~b', 'gw', 22)]);
    });

    test('refuses a hop with a character the shell globs', () {
      // ssh passes the hops before the last, and the last one's user and
      // host, to /bin/sh unquoted: `-J [2001:db8::1]` becomes `-J 1`
      // where ssh runs in a directory holding a file named 1.
      for (final value in [
        '[2001:db8::1],web',
        'gw*,web',
        'g?w,web',
        'u*@gw',
        'gw[1]',
        'ssh://u?@gw',
      ]) {
        expect(hops(value), isNull, reason: value);
      }
      // ssh drops the brackets around the last hop's host.
      expect(hops('web,[2001:db8::1]'), hasLength(2));
    });
  });
}
