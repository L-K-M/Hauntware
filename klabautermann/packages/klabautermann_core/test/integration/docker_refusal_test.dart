// The Docker host's negative sshd variants over a real SshLink (03 §5.3,
// §11.3; M3 D11): which sshd settings refuse `direct-streamlocal` to the
// engine socket on the fixture's OpenSSH, how seance_core classifies each
// refusal, the session limit `MaxSessions 2` teaches the link, and the
// exec probe that tells EACCES from disabled forwarding. Spike S1's
// refusal evidence: each test writes what it saw, with the OpenSSH
// version and sshd's own log lines, to
// $KLABAUTERMANN_EVIDENCE_DIR/fixture/refusals/. run.sh starts the
// fixture; without it these skip.
@Tags(['integration', 'docker'])
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_docker/klabautermann_docker.dart' as docker;
import 'package:seance_core/seance_core.dart'
    show
        ChannelOpenException,
        ChannelRefusal,
        SshLinkDegraded,
        SshLinkDegradedReason;
import 'package:test/test.dart';

import 'support/docker_host.dart';
import 'support/fixture.dart';

/// What a channel open to the Docker host did.
enum _Outcome {
  /// sshd opened the channel.
  opened,

  /// sshd refused it, and seance_core classified the refusal as forwarding
  /// disabled.
  forwardDisabled,

  /// sshd refused it, and seance_core classified it some other way. No
  /// variant expects this, so the test fails, after the evidence is
  /// written.
  otherRefusal,
}

/// A forwarding variant of the Docker host, and what its OpenSSH does with
/// a streamlocal open to the socket and a `direct-tcpip` open to its own
/// sshd on 127.0.0.1:22. These are recorded behaviour, not wishes: the
/// test fails when the fixture's OpenSSH starts doing otherwise.
///
/// Recorded on the base's OpenSSH 10.6: every streamlocal refusal is
/// reason 2 (connect failed) "open failed" and every `direct-tcpip` one
/// reason 1 (administratively prohibited) "open failed". sshd logs
/// "refused streamlocal port forward" where its streamlocal check refuses
/// (AllowStreamLocalForwarding, DisableForwarding, `restrict`), and
/// "Received request to connect to path ..., but the request was denied"
/// where the local TCP permissions it applies to socket paths do
/// (AllowTcpForwarding, PermitOpen).
typedef _Variant = ({
  FixtureService service,
  String setting,
  _Outcome streamlocal,
  _Outcome tcp,
});

const _variants = <_Variant>[
  (
    service: FixtureService.noStreamlocal,
    setting: 'AllowStreamLocalForwarding no',
    streamlocal: _Outcome.forwardDisabled,
    tcp: _Outcome.opened,
  ),
  (
    service: FixtureService.disableForwarding,
    setting: 'DisableForwarding yes',
    streamlocal: _Outcome.forwardDisabled,
    tcp: _Outcome.forwardDisabled,
  ),
  (
    service: FixtureService.noTcp,
    setting: 'AllowTcpForwarding no',
    streamlocal: _Outcome.forwardDisabled,
    tcp: _Outcome.forwardDisabled,
  ),
  (
    service: FixtureService.permitOpen,
    setting: 'PermitOpen 127.0.0.1:1',
    streamlocal: _Outcome.forwardDisabled,
    tcp: _Outcome.forwardDisabled,
  ),
  (
    service: FixtureService.restrict,
    setting: 'authorized_keys restrict',
    streamlocal: _Outcome.forwardDisabled,
    tcp: _Outcome.forwardDisabled,
  ),
];

/// The sshd log lines that explain a refusal, whatever OpenSSH words them.
final _refusalLog = RegExp(
  'refused|denied|prohibited|not permitted|failed|streamlocal|forward|'
  'no more sessions',
  caseSensitive: false,
);

void main() {
  final fixture = Fixture.fromEnvironment();
  if (fixture == null) {
    test('the Docker refusal suite', () {}, skip: fixtureSkipReason);
    return;
  }

  late String openSshVersion;
  setUpAll(() async {
    openSshVersion = await _identification(
      await fixture.endpoint(FixtureService.dockerHost),
    );
    await fixture.recordEvidence('refusals/openssh.txt', '$openSshVersion\n');
  });

  /// Records [details] about [service] with the OpenSSH version and the
  /// lines sshd logged about it since [logged], and prints them, so the
  /// job log carries them too.
  Future<void> record(
    FixtureService service,
    int logged,
    Map<String, Object?> details,
  ) async {
    final log = (await fixture.logs(service)).skip(logged);
    final evidence = const JsonEncoder.withIndent('  ').convert({
      'service': service.composeName,
      'openssh': openSshVersion,
      ...details,
      'sshdLog': [
        for (final line in log)
          if (_refusalLog.hasMatch(line)) line,
      ],
    });
    print(evidence);
    await fixture.recordEvidence(
      'refusals/${service.composeName}.json',
      '$evidence\n',
    );
  }

  for (final variant in _variants) {
    final service = variant.service;
    test(
      '${variant.setting} (${service.composeName}): streamlocal '
      '${variant.streamlocal.name}, direct-tcpip ${variant.tcp.name}',
      () async {
        final logged = (await fixture.logs(service)).length;
        final link = await connectDockerHost(fixture, service, fixture.user);

        // The ladder's exec probe sees a socket the account may write, so a
        // refusal here can only be disabled forwarding (03 §5.3).
        final probe = await link.run(
          'test -S $dockerSocket && test -w $dockerSocket',
        );
        expect(
          probe.exitCode,
          0,
          reason: 'the exec probe ran: ${probe.stderr}',
        );

        // The open first, on its own: the HTTP client would wrap its
        // refusal. A channel that opens must also reach the engine.
        final streamlocal = await _attempt(() async {
          await (await link.openUnixStream(dockerSocket)).close();
          final engine = docker.DockerClient(
            streamlocalClient(link, dockerSocket),
            apiVersion: docker.clientMaxTestedApiVersion,
          );
          await engine.ping();
        });
        final tcp = await _attempt(() async {
          final duplex = await link.openTcpStream('127.0.0.1', 22);
          await duplex.close();
        });
        await record(service, logged, {
          'setting': variant.setting,
          'streamlocal': streamlocal.evidence,
          'directTcpip': tcp.evidence,
        });

        expect(streamlocal.outcome, variant.streamlocal, reason: 'streamlocal');
        expect(tcp.outcome, variant.tcp, reason: 'direct-tcpip');
        expect(
          link.seen.forwardingRefused,
          variant.streamlocal == _Outcome.forwardDisabled ||
              variant.tcp == _Outcome.forwardDisabled,
        );
      },
    );
  }

  test('MaxSessions 2 (neg-maxsessions2): the third session is refused and '
      'the link learns a limit of 2', () async {
    const service = FixtureService.maxSessions2;
    final logged = (await fixture.logs(service)).length;
    final link = await connectDockerHost(fixture, service, fixture.user);

    // Each `cat` holds its session until its stdin closes; sshd frees a
    // session only once its command exits, not when the channel closes.
    final held = [await link.start('cat'), await link.start('cat')];
    final refused = await _refusal(link.start('cat'));
    await record(service, logged, {
      'setting': 'MaxSessions 2',
      'thirdSession': _evidence(refused),
      'learnedSessionLimit': link.seen.learnedSessionLimit,
    });

    expect(refused?.refusal, ChannelRefusal.sessionLimit);
    expect(link.seen.learnedSessionLimit, 2);
    expect(
      link.state,
      isA<SshLinkDegraded>().having(
        (state) => state.reason,
        'reason',
        SshLinkDegradedReason.sessionLimitLearned,
      ),
    );

    // At the learned limit a session queues instead of being refused,
    // and opens once a held one ends.
    final queued = link.run('echo queued');
    await held.first.stdin.close();
    await held.first.exit;
    expect((await queued).stdout.trim(), 'queued');
    await held.last.stdin.close();
    await held.last.exit;
  });

  test('klab-nosock (docker-sshd): the exec probe sees the socket and '
      'EACCES, and sshd refuses the streamlocal open', () async {
    const service = FixtureService.dockerHost;
    final logged = (await fixture.logs(service)).length;
    final link = await connectDockerHost(fixture, service, negativeUser);

    final present = await link.run('test -S $dockerSocket');
    final writable = await link.run('test -w $dockerSocket');
    // The CLI names the errno the probe's `test -w` cannot.
    final cli = await link.run(
      'docker --host unix://$dockerSocket version --format x',
    );
    final refused = await _refusal(link.openUnixStream(dockerSocket));
    await record(service, logged, {
      'user': negativeUser,
      'testS': present.exitCode,
      'testW': writable.exitCode,
      'dockerCli': cli.stderr.trim(),
      'streamlocal': _evidence(refused),
    });

    expect(present.exitCode, 0);
    expect(writable.exitCode, isNot(0));
    expect(cli.exitCode, isNot(0));
    expect(cli.stderr.toLowerCase(), contains('permission denied'));
    expect(refused?.refusal, ChannelRefusal.forwardDisabled);
  });
}

/// What one channel open did, and its evidence.
typedef _Attempt = ({_Outcome outcome, Object evidence});

/// Runs [open], which opens a channel and uses it, and reports what sshd
/// did. A refusal classified other than as forwarding disabled reads as
/// [_Outcome.otherRefusal], which the variant comparison fails on once
/// the evidence is recorded.
Future<_Attempt> _attempt(Future<void> Function() open) async {
  try {
    await open();
    return (outcome: _Outcome.opened, evidence: 'opened');
  } on ChannelOpenException catch (error) {
    final outcome = error.refusal == ChannelRefusal.forwardDisabled
        ? _Outcome.forwardDisabled
        : _Outcome.otherRefusal;
    return (outcome: outcome, evidence: _evidence(error));
  }
}

/// [refusal] for the evidence file, its cause carrying sshd's reason code
/// and description, or `opened`.
Object _evidence(ChannelOpenException? refusal) => refusal == null
    ? 'opened'
    : {
        'refusal': refusal.refusal.name,
        'message': refusal.message,
        'cause': '${refusal.cause}',
      };

/// The refusal [open] ended in, or null when it opened (and is closed
/// again by the link's teardown).
Future<ChannelOpenException?> _refusal(Future<Object?> open) async {
  try {
    await open;
    return null;
  } on ChannelOpenException catch (error) {
    return error;
  }
}

/// The identification string sshd sends at [endpoint] before key
/// exchange (RFC 4253 §4.2), such as `SSH-2.0-OpenSSH_9.9`.
Future<String> _identification(Endpoint endpoint) async {
  final socket = await Socket.connect(
    endpoint.host,
    endpoint.port,
    timeout: const Duration(seconds: 10),
  );
  try {
    final line = await socket
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .firstWhere((line) => line.startsWith('SSH-'))
        .timeout(const Duration(seconds: 10));
    return line.trim();
  } finally {
    socket.destroy();
  }
}
