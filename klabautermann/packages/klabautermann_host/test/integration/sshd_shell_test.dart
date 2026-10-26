// SEC-01's script through real shells (03 §7.11), with a stand-in `sshd`
// first on PATH: one that takes the full `-C`, one too old for `laddr`
// that takes the user and address only, one that takes no `-C` at all,
// and one whose configuration is broken. Each runs as the builder's argv
// with `sh` replaced by the shell under test. Tagged `shell`; a shell
// that is not installed gets no tests.
@Tags(['shell'])
@TestOn('linux')
library;

import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

final _shells = {
  for (final name in ['dash', 'bash'])
    for (final dir in ['/bin', '/usr/bin'])
      if (File('$dir/$name').existsSync()) name: '$dir/$name',
};

/// Prints the spec it got as its AuthenticationMethods, so the test sees
/// which `-C` reached it. [accepts] is the `case` arms over the spec
/// that let it answer; any other spec is refused.
String _sshd(String accepts) =>
    '''
#!/bin/sh
[ "\$1" = -T ] || exit 2
spec=\$3
case "\$spec" in
  $accepts) ;;
  *) echo "sshd: invalid test mode specification \$spec" >&2; exit 255 ;;
esac
echo 'port 22'
echo "authenticationmethods \${spec:-any}"
echo 'allowstreamlocalforwarding no'
''';

const _broken = r'''#!/bin/sh
echo '/etc/ssh/sshd_config line 3: Bad configuration option: Prot' >&2
exit 255
''';

void main() {
  late Directory bin;

  setUp(() async {
    bin = await Directory.systemTemp.createTemp('klab-sshd-');
  });

  tearDown(() => bin.delete(recursive: true));

  Future<void> standIn(String script) async {
    final sshd = File('${bin.path}/sshd');
    await sshd.writeAsString(script);
    await Process.run('chmod', ['+x', sshd.path]);
  }

  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    group(name, () {
      Future<SshdRead> run({String? connection}) async {
        final command = HostCommands.sshdPosture(
          user: 'deploy',
          sshConnection: connection ?? '192.0.2.1 50000 192.0.2.2 22',
        );
        // The swap below runs the script under [shell] only while the
        // command names `sh`.
        expect(command.first, 'sh');
        final argv = [for (final w in command) w == 'sh' ? shell : w];
        final r = await Process.run(
          argv.first,
          argv.sublist(1),
          environment: {'PATH': '${bin.path}:/usr/bin:/bin'},
        );
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final read = parseSshdPosture(r.stdout as String);
        expect(read, isNotNull, reason: '${r.stdout}');
        return read!;
      }

      test('a current sshd applies the whole connection', () async {
        await standIn(_sshd('*'));
        final posture = ((await run()) as SshdConfig).posture;
        expect(posture.match, SshdMatchContext.connection);
        expect(posture.authenticationMethods, contains('lport=22'));
        expect(posture.dockerBlocks, {
          SshdForwardingBlock.allowStreamLocalForwarding,
        });
      });

      test(
        'an sshd without laddr falls back to the user and address',
        () async {
          await standIn(_sshd('*laddr*) exit 255 ;; *'));
          final posture = ((await run()) as SshdConfig).posture;
          expect(posture.match, SshdMatchContext.remote);
          expect(
            posture.authenticationMethods,
            'user=deploy,host=192.0.2.1,addr=192.0.2.1',
          );
        },
      );

      test('an sshd that takes no -C reads without Match blocks', () async {
        await standIn(_sshd("''"));
        final posture = ((await run()) as SshdConfig).posture;
        expect(posture.match, SshdMatchContext.none);
        expect(posture.authenticationMethods, isNull);
      });

      test('an unusable connection skips -C', () async {
        await standIn(_sshd("''"));
        final read = await run(connection: 'not a connection');
        expect((read as SshdConfig).posture.match, SshdMatchContext.none);
      });

      test('a broken configuration reports sshd\'s error', () async {
        await standIn(_broken);
        final read = await run();
        expect((read as SshdFailed).detail, contains('Bad configuration'));
      });

      test('no sshd anywhere reads as missing', () async {
        // The runner may have its own sshd where the script also looks.
        for (final dir in ['/usr/sbin', '/usr/local/sbin', '/sbin']) {
          if (File('$dir/sshd').existsSync()) {
            markTestSkipped('an sshd is installed in $dir');
            return;
          }
        }
        expect(await run(), isA<SshdMissing>());
      });
    });
  }
}
