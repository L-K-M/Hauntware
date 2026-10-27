// PRC-02 end to end (M4 E14) over a link whose commands run in local
// shells: the engine plans a kill from the probe and the process as it
// stands, refuses one whose start time no longer matches, and runs the
// confirmed guarded kill. Tagged `shell`; a shell that is not installed
// gets no test.
@Tags(['shell'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/engine/engine_isolate.dart';
import 'package:test/test.dart';

import '../support/local_process_link.dart';

final _shells = {
  for (final name in ['dash', 'bash'])
    if (localShell(name) case final path?) name: path,
};

const _web = 'ssh-config:web';

/// The engine run in this isolate, its dial handing out [link]. It is
/// never sent [Shutdown], whose `Isolate.exit` would end the test isolate.
Future<(SendPort, StreamIterator<Object?>)> _start(
  String support,
  LocalProcessLink link,
) async {
  final port = ReceivePort();
  addTearDown(port.close);
  final events = StreamIterator<Object?>(port);
  engineMain(
    EngineStart(
      uiPort: port.sendPort,
      supportDirectory: support,
      linksEnabled: true,
      supportDirectoryAccess: SupportDirectoryAccess.exclusive,
    ),
    dial: ({
      required config,
      required credentials,
      required tofu,
      required onHostKey,
      onKeyboardInteractive,
      resolveJumpHost,
    }) async => link,
  );
  expect(await events.moveNext(), isTrue);
  return (events.current as SendPort, events);
}

/// Field 22 of `/proc/<pid>/stat`, after the parenthesised comm.
int _startTicks(int pid) {
  final stat = File('/proc/$pid/stat').readAsStringSync();
  final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
  return int.parse(fields[19]);
}

void main() {
  for (final MapEntry(key: name, value: path) in _shells.entries) {
    test('$name: a kill is planned from the process as it stands and runs '
        'once confirmed', () async {
      final support = Directory.systemTemp.createTempSync('klab-plans-');
      addTearDown(() => support.deleteSync(recursive: true));
      final link = await LocalProcessLink.create(path);
      addTearDown(link.dispose);
      final target = await Process.start('sleep', ['60']);
      addTearDown(target.kill);

      final (commands, events) = await _start(support.path, link);
      Future<T> until<T extends EngineEvent>() async {
        while (true) {
          final arrived = await events.moveNext().timeout(
            const Duration(seconds: 20),
          );
          expect(arrived, isTrue);
          if (events.current case final T event) return event;
        }
      }

      commands
        ..send(const Hello())
        ..send(const SetDeviceName('Klabautermann on Linux'))
        ..send(
          const SetSafetyPolicy(
            SafetyPolicy(servers: {_web: ServerSafety(management: true)}),
          ),
        )
        ..send(
          const ImportSshConfig('Host web\n  HostName 192.0.2.10\n  User me\n'),
        );
      await until<SshConfigImported>();
      commands.send(const Connect(_web));
      while ((await until<LinkState>()).status != const LinkReady()) {}
      // The planners read the probe, which the first subscription runs.
      commands.send(
        const Subscribe(
          serverId: _web,
          subscriptionId: 'overview',
          streams: {SampleStream.identity},
        ),
      );
      await until<HostProfileChanged>();

      final ticks = _startTicks(target.pid);
      commands.send(
        PlanAction(KillProcess(_web, pid: target.pid, startTicks: ticks + 1)),
      );
      expect(
        (await until<ActionRefused>()).reason,
        ActionRefusalReason.targetChanged,
      );

      commands.send(
        PlanAction(KillProcess(_web, pid: target.pid, startTicks: ticks)),
      );
      final planned = await until<ActionPlanned>();
      expect(planned.preview.targetName, 'sleep');
      expect(planned.preview.requiredLevel, RequiredLevel.login);
      expect(planned.preview.requiredTier, ConfirmationTier.acknowledge);
      // The engine ends the plan with the host syslog line (SAF-13).
      final line = planned.preview.steps.last as ShellStep;
      expect(line.bestEffort, isTrue);
      expect(line.argv.last, 'kill sleep by Klabautermann on Linux');

      // With the server's switch off, a plan holds the action alone.
      commands
        ..send(
          const SetSafetyPolicy(
            SafetyPolicy(
              servers: {
                _web: ServerSafety(management: true, hostAuditLine: false),
              },
            ),
          ),
        )
        ..send(
          PlanAction(KillProcess(_web, pid: target.pid, startTicks: ticks)),
        );
      final quiet = await until<ActionPlanned>();
      expect(quiet.preview.steps, hasLength(planned.preview.steps.length - 1));
      expect(
        quiet.preview.hostWrites,
        isNot(contains(HostWriteRow.auditSyslog)),
      );

      commands.send(
        RunAction(
          planned.planId,
          const ActionConfirmation(tier: ConfirmationTier.acknowledge),
        ),
      );
      final finished = await until<ActionFinished>();
      expect(finished.outcome, ActionOutcome.succeeded);
      expect(
        await target.exitCode.timeout(const Duration(seconds: 5)),
        -ProcessSignal.sigterm.signalNumber,
      );
    });
  }
}
