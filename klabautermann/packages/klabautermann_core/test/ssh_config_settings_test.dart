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

    test('patterns match UTF-8 bytes, as match_pattern() does', () {
      // `?` is one byte, and é two.
      expect(_applies('Host caf?', 'café'), isFalse);
      expect(_applies('Host caf??', 'café'), isTrue);
      expect(_applies('Host *é', 'café'), isTrue);
      expect(_applies('Match originalhost caf?', 'café'), isFalse);
      expect(_applies('Match originalhost CAF??', 'café'), isTrue);
      expect(
        _resolve(
          'Host caf?\n  HostName 10.0.0.9\nHost café\n  HostName '
              '10.0.0.5\n',
          'café',
        ),
        ('10.0.0.5', 22, null, null, null),
      );
      // A subpattern of 1023 bytes or more matches nothing.
      final long = 'é' * 512;
      expect(_applies('Match originalhost $long', long), isFalse);
      expect(_applies('Match originalhost ${'é' * 511}', 'é' * 511), isTrue);
    });

    test('U+FFFD, which stands for bytes that are not UTF-8, decides '
        'nothing', () {
      // The app decodes the config with replacement characters; ssh
      // compares the bytes themselves.
      expect(
        _resolve('Host caf\u{FFFD}\n  HostName 10.0.0.5\n', 'caf\u{FFFD}'),
        UnresolvedReason.undecodedName,
      );
      // A wildcard pattern holding one may match any name.
      for (final block in [
        'Host caf\u{FFFD}*',
        'Match originalhost caf\u{FFFD}*',
        'Host * !caf\u{FFFD}*',
      ]) {
        expect(
          _resolve('$block\n  User x\n', 'web'),
          UnresolvedReason.mayApply,
          reason: block,
        );
      }
      // Bytes that are not UTF-8 never equal a name that is.
      expect(_applies('Host caf\u{FFFD} web', 'web'), isTrue);
      expect(_applies('Host caf\u{FFFD}', 'web'), isFalse);
    });

    test('a name ssh refuses as a host name is unresolved', () {
      // ssh.c's valid_hostname(), with isspace() and iscntrl() in the C
      // locale.
      for (final name in [
        '-web',
        for (final c in '\'`"\$\\;&<>|(){}'.split('')) 'a${c}b',
        for (final c in [' ', '\t', '\n', '\v', '\f', '\r', '\x01', '\x7f'])
          'a${c}b',
        // ssh.c reads these as user@host or as an ssh URI.
        'me@web', '@web', 'web@', 'ssh://db', 'ssh://',
      ]) {
        expect(
          _resolve('Host *\n  HostName 10.0.0.5\n', name),
          UnresolvedReason.rejectedName,
          reason: name,
        );
      }
      for (final name in [
        'a-b',
        'a!b',
        'caf\u00e9',
        'a~b',
        'a#b',
        'a[b]',
        'SSH://db',
        // Only the full scheme marks a URI.
        'ssh:db',
      ]) {
        expect(_resolve('Host *\n  HostName 10.0.0.5\n', name), (
          '10.0.0.5',
          22,
          null,
          null,
          null,
        ), reason: name);
      }
    });

    test('a HostName, User or IdentityFile holding U+FFFD leaves the name '
        'out', () {
      // ssh dials and signs in with the bytes themselves, which the
      // import cannot know.
      for (final line in [
        'HostName caf\u{FFFD}.example',
        'HostName %h.caf\u{FFFD}',
        'User j\u{FFFD}rg',
        'IdentityFile ~/.ssh/k\u{FFFD}y',
        'IdentityFile none\n  IdentityFile ~/.ssh/k\u{FFFD}y',
      ]) {
        expect(
          _resolve('Host x\n  $line\n', 'x'),
          UnresolvedReason.undecodedValue,
          reason: line,
        );
      }
      // Only the values ssh uses count.
      expect(
        _resolve(
          'Host x\n  User a\n  IdentityFile ~/.ssh/a\n'
              '  User j\u{FFFD}rg\n  IdentityFile ~/.ssh/k\u{FFFD}y\n',
          'x',
        ),
        ('x', 22, 'a', '~/.ssh/a', null),
      );
    });

    test('splits lines as readconf.c does', () {
      // Only space, tab, CR, LF and form feed end a line, and only space
      // and tab separate arguments: U+00A0, U+FEFF, \v and other Unicode
      // whitespace are part of a token.
      const nbsp = 'Host web\u00A0\n  HostName 10.0.0.5\n  ProxyJump b\n';
      expect(SshConfigSettings.parse(nbsp).aliases, ['web\u00A0']);
      expect(_resolve(nbsp, 'web'), ('web', 22, null, null, null));
      expect(_resolve(nbsp, 'web\u00A0'), ('10.0.0.5', 22, null, null, 'b'));
      for (final end in ['\u00A0', '\u{FEFF}', '\v', '\u2003', '\u3000']) {
        expect(
          _resolve('Host web\n  HostName 10.0.0.5$end\n  User u$end\n', 'web'),
          ('10.0.0.5$end', 22, 'u$end', null, null),
          reason: end.codeUnits.toString(),
        );
      }
      expect(_resolve('Host web\f\r \t\n  HostName 10.0.0.5 \f\t\r\n', 'web'), (
        '10.0.0.5',
        22,
        null,
        null,
        null,
      ));
      // A NUL ends the line, as it ends a C string.
      expect(_resolve('Host web\n  HostName 10.0.0.5\u0000 x\n', 'web'), (
        '10.0.0.5',
        22,
        null,
        null,
        null,
      ));
      // strdelim() ends the keyword at a quote too, and drops the quotes.
      expect(_resolve('Host web\n  "HostName" 10.0.0.5\n', 'web'), (
        '10.0.0.5',
        22,
        null,
        null,
        null,
      ));
      expect(_resolve('Host web\n  =HostName 10.0.0.5\n', 'web'), (
        '10.0.0.5',
        22,
        null,
        null,
        null,
      ));
      // argv_split() reads a backslash and a space as a space only outside
      // quotes.
      expect(_resolve('Host web\n  HostName "a\\ b"\n  User u\\ v\n', 'web'), (
        'a\\ b',
        22,
        'u v',
        null,
        null,
      ));
      // strdelim() skips one `=` after the keyword, with the whitespace
      // around it, so a second one starts the value.
      expect(_resolve('Host web\n  HostName==x\n  User=  =u\n', 'web'), (
        '=x',
        22,
        '=u',
        null,
        null,
      ));
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
      // `canonical` and `final` hold only on a second pass, which
      // /etc/ssh/ssh_config may ask for (below).
      expect(_applies('Match !canonical host web', 'web'), isTrue);
      expect(
        _resolve('Match canonical\n  User x\n', 'web'),
        UnresolvedReason.secondPass,
      );
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
          'Host web\n  ProxyJump=a,b # c\n  ProxyCommand nc %h %p\n',
          'web',
        ),
        ('web', 22, null, null, 'a,b # c'),
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

    test('IdentityFile2, an obsolete name, adds a key file too', () {
      // readconf.c still maps identityfile2 to oIdentityFile.
      expect(
        _resolve(
          'Host web\n  HostName 10.0.0.5\n  IdentityFile2 ~/.ssh/old\n'
              '  IdentityFile ~/.ssh/new\n',
          'web',
        ),
        ('10.0.0.5', 22, null, '~/.ssh/old', null),
      );
      expect(_resolve('Host web\n  identityfile2 ~/.ssh/only\n', 'web'), (
        'web',
        22,
        null,
        '~/.ssh/only',
        null,
      ));
      // The final pass that /etc/ssh/ssh_config may ask for would set it.
      expect(
        _resolve(
          'Host web\n  HostName 10.0.0.5\n'
              'Host 10.0.0.*\n  IdentityFile2 ~/.ssh/k\n',
          'web',
        ),
        UnresolvedReason.secondPass,
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
      for (final value in ['yes', 'always', 'True']) {
        expect(
          _resolve('CanonicalizeHostname $value\nHost web\n', 'web'),
          UnresolvedReason.secondPass,
          reason: value,
        );
      }
      // ssh rejects the whole config over any other value.
      expect(
        _resolve('CanonicalizeHostname bogus\nHost web\n', 'web'),
        UnresolvedReason.rejectedLine,
      );
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

    test('a final pass that /etc/ssh/ssh_config may ask for leaves out a '
        'name whose Port, User, key or route it would set', () {
      // Fedora and RHEL ship `Match final all` there, so ssh reads this
      // file again, matching Host patterns against the host it dials,
      // and sets what is still unset; other systems do not.
      const config =
          'Host db\n  HostName db.internal.example.com\n'
          'Host *.internal.example.com\n  User ops\n  ProxyJump bastion\n'
          'Host bastion\n  HostName bastion.example.com\n  ProxyJump none\n';
      expect(_resolve(config, 'db'), UnresolvedReason.secondPass);
      // The import still sees both, to keep the first where ssh would
      // refuse the final pass's route.
      final passes = (SshConfigSettings.parse(
        config,
      ).resolve('db') as UnresolvedSshSettings).passes!;
      expect(
        [
          passes.firstPass,
          passes.finalPass,
        ].map((h) => (h.alias, h.hostName, h.user, h.proxyJump)),
        [
          ('db', 'db.internal.example.com', null, null),
          ('db', 'db.internal.example.com', 'ops', 'bastion'),
        ],
      );
      expect(_resolve(config, 'bastion'), (
        'bastion.example.com',
        22,
        null,
        null,
        'none',
      ));
      for (final block in [
        'Host 10.0.0.*\n  Port 2200',
        'Host 10.0.0.5\n  IdentityFile ~/.ssh/k',
        'Match canonical host 10.0.0.5\n  ProxyCommand none',
        'Match final\n  User late',
      ]) {
        expect(
          _resolve('Host web\n  HostName 10.0.0.5\n$block\n', 'web'),
          // A Match final here asks for the pass, and what it sets applies.
          block.startsWith('Match final')
              ? ('10.0.0.5', 22, 'late', null, null)
              : UnresolvedReason.secondPass,
          reason: block,
        );
      }

      // The first pass's values stay, and HostName is fixed by then.
      expect(
        _resolve(
          'Host web\n  HostName web.example.com\n  User u\n'
              'Host *.example.com\n  User late\n  HostName other\n',
          'web',
        ),
        ('web.example.com', 22, 'u', null, null),
      );
      // ssh matches the host lowercased, an address as getnameinfo()
      // writes it unless only its case differs, and a Match host the same.
      for (final (hostName, block, changes) in [
        ('WEB.example.com', 'Host web.*', true),
        ('WEB.example.com', 'Host WEB.*', false),
        ('2001:0db8::1', 'Host 2001:db8::1', true),
        ('2001:DB8::1', 'Host 2001:db8::1', false),
        ('2001:DB8::1', 'Host 2001:DB8::1', true),
        ('2001:0db8::1', 'Match host 2001:db8::1', true),
        ('web.example.com', 'Match host web,!web.example.com', false),
        ('web.example.com', 'Match originalhost web canonical', true),
      ]) {
        final config = 'Host web\n  HostName $hostName\n$block\n  User x\n';
        expect(
          _resolve(config, 'web'),
          changes ? UnresolvedReason.secondPass : isA<Record>(),
          reason: config,
        );
      }
      // A scoped address's form depends on the device's interfaces, so a
      // block may then match; `*` matches anything.
      expect(
        _resolve(
          'Host z\n  HostName fe80::1%%eth0\nHost fe80::*\n  User x\n',
          'z',
        ),
        UnresolvedReason.mayApply,
      );
      expect(
        _resolve(
          'Host z\n  HostName fe80::1%%eth0\nHost *\n  User x\n'
              'Host web\n  Port 2200\n',
          'z',
        ),
        ('fe80::1%eth0', 22, 'x', null, null),
        reason: 'an address never looks like `web`',
      );
    });

    test('a Match final in the file asks for the final pass, and what it '
        'sets applies', () {
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
        _resolve(
          'Host web\n  User u\nMatch final\n  User late\n  Port 2200\n',
          'web',
        ),
        ('web', 2200, 'u', null, null),
      );
      // Host patterns then match the host ssh dials.
      expect(
        _resolve(
          'Host web\n  HostName 10.0.0.5\nHost 10.0.0.*\n  ProxyJump b\n'
              'Match final\n',
          'web',
        ),
        ('10.0.0.5', 22, null, null, 'b'),
      );
      // A final block that may apply and would set a value first.
      expect(
        _resolve('Host web\nMatch final exec "true"\n  User late\n', 'web'),
        UnresolvedReason.mayApply,
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

    test('Port, User, the first IdentityFile and the route each count for '
        'the final pass', () {
      const fixed = {
        'Port': '  Port 22\n',
        'User': '  User u\n',
        'IdentityFile': '  IdentityFile ~/.ssh/k\n',
        'route': '  ProxyJump none\n',
      };
      const late = {
        'Port': '  Port 2200\n',
        'User': '  User late\n',
        'IdentityFile': '  IdentityFile ~/.ssh/late\n',
        'route': '  ProxyJump gw\n',
      };
      const settled = ('web.example.com', 22, 'u', '~/.ssh/k', 'none');
      const afterLate = {
        'Port': ('web.example.com', 2200, 'u', '~/.ssh/k', 'none'),
        'User': ('web.example.com', 22, 'late', '~/.ssh/k', 'none'),
        'IdentityFile': ('web.example.com', 22, 'u', '~/.ssh/late', 'none'),
        'route': ('web.example.com', 22, 'u', '~/.ssh/k', 'gw'),
      };

      for (final unset in fixed.keys) {
        final host = [
          'Host web\n  HostName web.example.com\n',
          for (final MapEntry(:key, :value) in fixed.entries)
            if (key != unset) value,
        ].join();

        // An Include anywhere could ask for the pass and set it then.
        expect(
          _resolve('${host}Host other\n  Include other.conf\n', 'web'),
          UnresolvedReason.secondPass,
          reason: '$unset unset, with an Include',
        );
        // A pass that /etc/ssh/ssh_config may ask for would set it.
        expect(
          _resolve('${host}Host *.example.com\n${late[unset]}', 'web'),
          UnresolvedReason.secondPass,
          reason: '$unset set only on the final pass',
        );
        // A Match final here asks for the pass, and it sets the value.
        expect(
          _resolve('${host}Match final\n${late[unset]}', 'web'),
          afterLate[unset],
          reason: '$unset set by a Match final',
        );
      }

      // With all four set, neither can change what the engine dials.
      final all =
          'Host web\n  HostName web.example.com\n${fixed.values.join()}';
      expect(
        _resolve('${all}Host other\n  Include other.conf\n', 'web'),
        settled,
      );
      expect(
        _resolve('${all}Host *.example.com\n${late.values.join()}', 'web'),
        settled,
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
        // ssh checks these two in every block.
        final everywhere =
            line.startsWith('ProxyJump') ||
            line.startsWith('CanonicalizeHostname');
        expect(
          _resolve('Host web\nHost db\n  $line\n', 'web'),
          everywhere
              ? UnresolvedReason.rejectedLine
              : ('web', 22, null, null, null),
          reason: '$line applies to db only',
        );
      }
      expect(
        _resolve('Host web\n  Port +2200\nHost *\n  Port https\n', 'web'),
        ('web', 2200, null, null, null),
      );
    });

    test('an unclosed quote or an empty Host pattern leaves out the names '
        'its block applies to', () {
      // ssh rejects the config over either: argv_split() over the quote
      // ("invalid quotes"), oHost over the pattern ("empty argument").
      for (final config in [
        'Host t\n  HostName "10.0.0.5\n',
        'Host t\n  ProxyJump "a\n',
        'Host t\n  User u\nHost *\n  IdentityFile \'~/.ssh/k\n',
        'Host "t\n  HostName 10.0.0.5\n',
        'Host "" t\n  HostName 10.0.0.5\n',
        'Host t \'\'\n',
      ]) {
        expect(
          _resolve(config, 't'),
          UnresolvedReason.rejectedLine,
          reason: config,
        );
      }
      expect(
        _resolve('Match originalhost "t\n  User x\n', 't'),
        UnresolvedReason.mayApply,
      );
      // In a block that does not apply, as for any line ssh rejects.
      expect(_resolve('Host t\nHost "" db\n  User "u\n', 't'), (
        't',
        22,
        null,
        null,
        null,
      ));
      // Closed, escaped or commented quotes are fine.
      expect(
        _resolve(
          'Host t\n  HostName "10.0.0.5" # it\'s\n  User \\"u\n'
              '  IdentityFile \'~/.ssh/my key\'\n',
          't',
        ),
        ('10.0.0.5', 22, '"u', '~/.ssh/my key', null),
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

    test('resolves quickly when each host has wildcard patterns of its '
        'own', () {
      // 20,000 hosts, each with a pattern that ends or starts with `*`.
      final config = StringBuffer();
      for (var host = 0; host < 20000; host++) {
        config.write(
          '${host.isEven ? 'Host h$host h$host.*' : 'Host h$host *.h$host'}\n'
          '  HostName 10.0.${host >> 8}.${host & 255}\n  User u$host\n',
        );
      }
      final clock = Stopwatch()..start();

      final settings = SshConfigSettings.parse(config.toString());
      final resolved = [
        for (final alias in settings.aliases) settings.resolve(alias),
      ];

      expect(resolved.whereType<ResolvedSshSettings>(), hasLength(20000));
      expect(
        (resolved[7] as ResolvedSshSettings).host.user,
        'u7',
        reason: 'each host keeps its own block',
      );
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('a wildcard Host block applies wherever its pattern matches', () {
      // Blocks reach a name through the literal start or end of their
      // patterns; patterns with neither reach every name.
      const config =
          'Host web*\n  User prefix\n'
          'Host *.example.com\n  Port 2200\n'
          'Host *eb*\n  IdentityFile ~/.ssh/middle\n'
          'Host w?b-*-x\n  ProxyJump gw\n'
          'Host web-1 web-1.*\n  User own\n';

      expect(_resolve(config, 'web-1.example.com'), (
        'web-1.example.com',
        2200,
        'prefix',
        '~/.ssh/middle',
        null,
      ));
      expect(_resolve(config, 'wab-1-x'), ('wab-1-x', 22, null, null, 'gw'));
      expect(_resolve(config, 'db'), ('db', 22, null, null, null));
    });
  });
}
