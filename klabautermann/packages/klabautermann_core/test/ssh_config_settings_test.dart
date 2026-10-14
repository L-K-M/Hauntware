import 'package:klabautermann_core/src/fleet/ssh_config_settings.dart';
import 'package:test/test.dart';

/// [name]'s settings in [config] as `(hostName, port, user, identityFile,
/// proxyJump)`, or the reason there are none.
Object _resolve(String config, String name) =>
    switch (SshConfigSettings.parse(config).resolve(name)) {
      ResolvedSshSettings(:final host) => (
        host.hostName,
        host.port,
        host.user,
        host.identityFile,
        host.proxyJump,
      ),
      UnresolvedSshSettings(:final reason) => reason,
    };

/// Whether [config]'s one block, which sets `User x`, applies to [name].
bool _applies(String config, String name) =>
    switch (SshConfigSettings.parse('$config\n  User x\n').resolve(name)) {
      ResolvedSshSettings(:final host) => host.user == 'x',
      UnresolvedSshSettings(:final reason) => throw StateError('$reason'),
    };

void main() {
  group('SshConfigSettings (03 §10.1)', () {
    test('lists the names Host lines give, once, in order', () {
      expect(
        SshConfigSettings.parse(
          'Host b a\nHost * c !d\nMatch host e\nHost a f? g !g\n',
        ).aliases,
        ['b', 'a', 'c'],
      );
    });

    test('Host patterns match as match_pattern() does', () {
      expect(_applies('Host w?b', 'web'), isTrue);
      expect(_applies('Host w?b', 'webb'), isFalse);
      expect(_applies('Host *.example.*', 'a.example.com'), isTrue);
      expect(_applies('Host *.example.*', 'example.com'), isFalse);
      expect(_applies('Host a**b*', 'axxbyy'), isTrue);
      expect(_applies('Host *?c', 'c'), isFalse);
      // Case-sensitively, unlike a Match.
      expect(_applies('Host Web', 'web'), isFalse);
    });

    test('a negated Host pattern turns the block off wherever it '
        'stands', () {
      expect(_applies('Host * !bastion', 'bastion'), isFalse);
      expect(_applies('Host !bastion *', 'bastion'), isFalse);
      expect(_applies('Host !bastion', 'web'), isFalse, reason: 'no positive');
      expect(_applies('Host * !bastion', 'web'), isTrue);
    });

    test('Match criteria read as match_cfg_line() reads them', () {
      // `host` and `originalhost` lowercase both sides and take a list.
      expect(_applies('Match host WEB*,!web2', 'web1'), isTrue);
      expect(_applies('Match host WEB*,!web2', 'web2'), isFalse);
      expect(_applies('Match !originalhost db', 'web'), isTrue);
      expect(_applies('Match all', 'web'), isTrue);
      expect(_applies('Match !all', 'web'), isFalse);
      // ssh accepts `all` after one other criterion, as a no-op.
      expect(_applies('Match host web all', 'web'), isTrue);
      // `canonical` and `final` hold only on a second pass.
      expect(_applies('Match canonical', 'web'), isFalse);
      expect(_applies('Match !canonical host web', 'web'), isTrue);
    });

    test('Match host compares the HostName read so far', () {
      const config =
          'Host web\n  HostName %h.example.com\n'
          'Match host web.example.com\n  User x\n'
          'Match host web\n  Port 2200\n';

      expect(_resolve(config, 'web'), ('web.example.com', 22, 'x', null, null));
    });

    test('a Match with a criterion this cannot evaluate leaves a name out '
        'only where it would set a value first', () {
      for (final criterion in [
        'exec "true"',
        'user root',
        'localuser me',
        'localnetwork 10.0.0.0/8',
        'tagged t',
      ]) {
        final config = 'Host fixed\n  User u\nMatch $criterion\n  User x\n';
        expect(
          _resolve(config, 'open'),
          UnresolvedReason.mayApply,
          reason: criterion,
        );
        expect(_resolve(config, 'fixed'), (
          'fixed',
          22,
          'u',
          null,
          null,
        ), reason: criterion);
      }
      // ssh rejects these Match lines, and with them the config.
      for (final line in [
        'Match',
        'Match host',
        'Match all host web',
        'Match host a host b all',
        'Match bogus x',
      ]) {
        expect(
          _resolve('$line\n  User x\n', 'web'),
          UnresolvedReason.mayApply,
          reason: line,
        );
      }
    });

    test('the first value read wins, ProxyJump and ProxyCommand sharing '
        'one', () {
      expect(
        _resolve(
          'Host web\n  ProxyJump=a, b\n  ProxyCommand nc %h %p\n',
          'web',
        ),
        ('web', 22, null, null, 'a, b'),
      );
      expect(
        _resolve('Host web\n  ProxyCommand none\n  ProxyJump a\n', 'web'),
        ('web', 22, null, null, null),
      );
      expect(
        _resolve('Host web\n  ProxyCommand nc %h %p\n  ProxyJump a\n', 'web'),
        UnresolvedReason.proxyCommand,
      );
    });

    test('the first IdentityFile that is not none is the key', () {
      expect(
        _resolve(
          'Host web\n  IdentityFile NONE\n  IdentityFile ~/.ssh/a\n'
              '  IdentityFile ~/.ssh/b\n',
          'web',
        ),
        ('web', 22, null, '~/.ssh/a', null),
      );
      // Only the key the engine uses is checked for tokens.
      expect(
        _resolve(
          'Host web\n  IdentityFile ~/.ssh/a\n  IdentityFile ~/.ssh/%h\n',
          'web',
        ),
        ('web', 22, null, '~/.ssh/a', null),
      );
      expect(
        _resolve('Host *\n  IdentityFile ~/.ssh/%h\n', 'web'),
        UnresolvedReason.identityFileToken,
      );
    });

    test('the host ssh dials is lowercased unless it is an address', () {
      expect(_resolve('Host Web\n', 'Web'), ('web', 22, null, null, null));
      expect(_resolve('Host web\n  HostName Web.Example.COM\n', 'web'), (
        'web.example.com',
        22,
        null,
        null,
        null,
      ));
      expect(_resolve('Host v6\n  HostName 2001:DB8::1\n', 'v6'), (
        '2001:DB8::1',
        22,
        null,
        null,
        null,
      ));
      expect(_resolve('Host zone\n  HostName fe80::1%%Eth0\n', 'zone'), (
        'fe80::1%Eth0',
        22,
        null,
        null,
        null,
      ));
    });

    test('CanonicalizeHostname other than no leaves a name out', () {
      for (final value in ['yes', 'always', 'True', 'bogus']) {
        expect(
          _resolve('CanonicalizeHostname $value\nHost web\n', 'web'),
          UnresolvedReason.secondPass,
          reason: value,
        );
      }
      for (final value in ['no', 'False']) {
        expect(_resolve('CanonicalizeHostname $value\nHost web\n', 'web'), (
          'web',
          22,
          null,
          null,
          null,
        ), reason: value);
      }
    });

    test('a Match final makes every value still unset after the first pass '
        'unknown', () {
      const fixed =
          'Host web\n  Port 22\n  User u\n  IdentityFile ~/.ssh/k\n'
          '  ProxyJump none\n';

      expect(_resolve('${fixed}Match final\n  User late\n', 'web'), (
        'web',
        22,
        'u',
        '~/.ssh/k',
        'none',
      ));
      expect(
        _resolve('Host web\n  User u\nMatch final\n  User late\n', 'web'),
        UnresolvedReason.secondPass,
      );
      // `final` read as a host pattern is no attribute.
      expect(_resolve('Host web\nMatch host final\n  User late\n', 'web'), (
        'web',
        22,
        null,
        null,
        null,
      ));
    });

    test('an Include that applies leaves a name out', () {
      expect(
        _resolve('Host web\n  Include web.conf\n', 'web'),
        UnresolvedReason.include,
      );
      expect(
        _resolve('Match host db\n  Include db.conf\nHost web\n', 'web'),
        UnresolvedReason.secondPass,
        reason: 'it could hold a Match final',
      );
    });

    test('a line ssh rejects leaves out the names its block applies to', () {
      for (final line in [
        'Port 0',
        'Port 65536',
        'Port 22a',
        'Port domain',
        'HostName',
        'User a b',
        'IdentityFile ""',
        'ProxyJump',
        'ProxyCommand=',
        'CanonicalizeHostname',
      ]) {
        expect(
          _resolve('Host web\n  User u\nHost *\n  $line\n', 'web'),
          UnresolvedReason.rejectedLine,
          reason: line,
        );
        expect(_resolve('Host web\nHost db\n  $line\n', 'web'), (
          'web',
          22,
          null,
          null,
          null,
        ), reason: '$line applies to db only');
      }
      expect(
        _resolve('Host web\n  Port +2200\nHost *\n  Port https\n', 'web'),
        ('web', 2200, null, null, null),
      );
    });

    test('resolves every alias of a large config quickly', () {
      // 20,000 hosts behind 300 wildcard blocks, each matching some.
      final config = StringBuffer();
      for (var block = 0; block < 300; block++) {
        config.write('Host *.zone$block !skip.zone$block\n  Port 2222\n');
      }
      for (var host = 0; host < 20000; host++) {
        config.write(
          'Host h$host.zone${host % 300}\n  HostName 10.0.${host >> 8}.'
          '${host & 255}\n  User u$host\n',
        );
      }
      final clock = Stopwatch()..start();

      final settings = SshConfigSettings.parse(config.toString());
      final resolved = [
        for (final alias in settings.aliases) settings.resolve(alias),
      ];

      expect(resolved, hasLength(20000));
      expect(resolved.whereType<ResolvedSshSettings>(), hasLength(20000));
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });
}
