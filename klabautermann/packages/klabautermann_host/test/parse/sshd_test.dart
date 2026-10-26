// SEC-01's parser and command: `sshd -T`'s settings, the Docker
// transport's forwarding blockers, and the `-C` specs built from the
// probe's user and `$SSH_CONNECTION`.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const _debian12 = '''
port 22
addressfamily any
listenaddress [::]:22
listenaddress 0.0.0.0:22
permitrootlogin without-password
passwordauthentication yes
kbdinteractiveauthentication no
pubkeyauthentication yes
authenticationmethods any
hostkey /etc/ssh/ssh_host_rsa_key
hostkey /etc/ssh/ssh_host_ecdsa_key
hostkey /etc/ssh/ssh_host_ed25519_key
pubkeyacceptedalgorithms ssh-ed25519,ecdsa-sha2-nistp256,rsa-sha2-512
maxsessions 10
allowtcpforwarding yes
allowstreamlocalforwarding yes
disableforwarding no
permitopen any
''';

SshdPosture _posture(String raw) =>
    (parseSshdPosture(raw)! as SshdConfig).posture;

void main() {
  test('sshd -T gives the login, key and forwarding settings', () {
    final posture = _posture('$kSshdMarker full\n$_debian12');
    expect(posture.match, SshdMatchContext.connection);
    expect(posture.ports, [22]);
    expect(posture.listenAddresses, ['[::]:22', '0.0.0.0:22']);
    expect(posture.permitRootLogin, SshdRootLogin.keysOnly);
    expect(posture.passwordAuthentication, isTrue);
    expect(posture.keyboardInteractive, isFalse);
    expect(posture.pubkeyAuthentication, isTrue);
    expect(posture.authenticationMethods, isNull);
    expect(posture.hostKeyTypes, ['rsa', 'ecdsa', 'ed25519']);
    expect(posture.userKeyTypes, [
      'ssh-ed25519',
      'ecdsa-sha2-nistp256',
      'rsa-sha2-512',
    ]);
    expect(posture.maxSessions, 10);
    expect(posture.allowTcpForwarding, SshdForwarding.all);
    expect(posture.dockerBlocks, isEmpty);
  });

  test('older sshd names keep their meaning', () {
    final posture = _posture(
      '$kSshdMarker basic\n'
      'port 2222\n'
      'port 22\n'
      'challengeresponseauthentication yes\n'
      'pubkeyacceptedkeytypes ssh-ed25519,ssh-rsa\n'
      'authenticationmethods publickey,password\n'
      'hostkey /etc/ssh/custom_host_key\n',
    );
    expect(posture.match, SshdMatchContext.remote);
    expect(posture.ports, [2222, 22]);
    expect(posture.keyboardInteractive, isTrue);
    expect(posture.userKeyTypes, ['ssh-ed25519', 'ssh-rsa']);
    expect(posture.authenticationMethods, 'publickey,password');
    expect(posture.hostKeyTypes, ['/etc/ssh/custom_host_key']);
    expect(posture.passwordAuthentication, isNull);
  });

  test('each forwarding setting that refuses sockets blocks Docker', () {
    Set<SshdForwardingBlock> blocks(String settings) =>
        _posture('$kSshdMarker none\nport 22\n$settings').dockerBlocks;

    expect(blocks('allowstreamlocalforwarding remote\n'), {
      SshdForwardingBlock.allowStreamLocalForwarding,
    });
    expect(blocks('allowtcpforwarding no\n'), {
      SshdForwardingBlock.allowTcpForwarding,
    });
    expect(blocks('permitopen 127.0.0.1:1\n'), {
      SshdForwardingBlock.permitOpen,
    });
    expect(blocks('disableforwarding yes\n'), {
      SshdForwardingBlock.disableForwarding,
    });
    expect(
      blocks('allowtcpforwarding local\nallowstreamlocalforwarding all\n'),
      isEmpty,
    );
  });

  test('a missing or failing sshd reads as such', () {
    expect(parseSshdPosture('$kSshdMarker missing\n'), isA<SshdMissing>());
    final failed = parseSshdPosture(
      '$kSshdMarker failed\n'
      '/etc/ssh/sshd_config line 3: Bad configuration option: Prot\n'
      '\n'
      '/etc/ssh/sshd_config: terminating, 1 bad configuration options\n',
    );
    expect(
      (failed! as SshdFailed).detail,
      '/etc/ssh/sshd_config line 3: Bad configuration option: Prot\n'
      '/etc/ssh/sshd_config: terminating, 1 bad configuration options',
    );
  });

  test('other output is not the read', () {
    expect(parseSshdPosture(''), isNull);
    expect(parseSshdPosture(_debian12), isNull);
    expect(parseSshdPosture('$kSshdMarker full\n'), isNull);
    expect(parseSshdPosture('$kSshdMarker full\nWarning: Odd\n'), isNull);
  });

  group('the command', () {
    List<String> specs({String? user, String? connection}) =>
        HostCommands.sshdPosture(
          user: user,
          sshConnection: connection,
        ).sublist(4);

    test('names the connection from the probe', () {
      expect(
        specs(user: 'deploy', connection: '192.0.2.1 50000 192.0.2.2 22'),
        [
          'user=deploy,host=192.0.2.1,addr=192.0.2.1,'
              'laddr=192.0.2.2,lport=22',
          'user=deploy,host=192.0.2.1,addr=192.0.2.1',
        ],
      );
      expect(
        specs(
          user: 'deploy',
          connection: '2001:db8::1 50000 2001:db8::2 2222',
        ).first,
        endsWith('laddr=2001:db8::2,lport=2222'),
      );
    });

    test('leaves -C out for anything that is not a connection', () {
      for (final (user, connection) in [
        (null, '192.0.2.1 50000 192.0.2.2 22'),
        ('deploy', null),
        ('deploy', ''),
        ('deploy', '192.0.2.1 50000 192.0.2.2'),
        ('deploy', '192.0.2.1,x 50000 192.0.2.2 22'),
        ('deploy', '192.0.2.1 50000 192.0.2.2 0'),
        ('a,b=c', '192.0.2.1 50000 192.0.2.2 22'),
      ]) {
        expect(specs(user: user, connection: connection), [
          '',
          '',
        ], reason: '$user $connection');
      }
    });
  });
}
