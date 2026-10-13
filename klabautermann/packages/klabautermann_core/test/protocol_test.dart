import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_host/klabautermann_host.dart' show MemInfo;
import 'package:test/test.dart';

/// Echoes every message back; protocol values cross a real isolate boundary
/// so the test proves each is sendable (03 D18's plain-data rule).
void _echo(SendPort replies) {
  final inbox = ReceivePort();
  replies.send(inbox.sendPort);
  inbox.listen(replies.send);
}

const _webEntry = FleetEntry(
  serverId: 'ssh-config:web-1',
  label: 'web-1',
  host: 'web-1.example',
  port: 2222,
  user: 'deploy',
  origin: FleetEntryOrigin.sshConfig,
);

void main() {
  group('engine protocol (03 §10.1)', () {
    late Isolate echo;
    late SendPort toEcho;
    late ReceivePort port;
    late StreamIterator<Object?> replies;

    setUp(() async {
      port = ReceivePort();
      replies = StreamIterator<Object?>(port);
      echo = await Isolate.spawn(_echo, port.sendPort);
      await replies.moveNext();
      toEcho = replies.current as SendPort;
    });

    tearDown(() {
      echo.kill();
      port.close();
    });

    Future<Object?> roundTrip(Object value) {
      final response = replies.moveNext().then((_) => replies.current);
      toEcho.send(value);
      return response;
    }

    // Every 03 §10.1 row crosses the boundary with its runtime type intact.
    // Field-level assertions live in the representative cases below.
    test('every request type survives the isolate boundary', () async {
      final requests = <EngineRequest>[
        const Hello(),
        const Shutdown(),
        const EnrollSync(),
        const RunSyncRound(),
        const ConfirmEndpoints(['a', 'b']),
        const SetMonitorSet(['a']),
        const Connect('srv-1'),
        const Disconnect('srv-1'),
        const Subscribe(
          serverId: 'srv-1',
          collectors: {Collector.overview, Collector.core},
          cadence: Duration(seconds: 2),
        ),
        const Unsubscribe('srv-1'),
        const ImportSshConfig('Host web-1\n  HostName web-1.example\n'),
        const OpenLogStream(
          LogStreamSpec(
            serverId: 'srv-1',
            source: LogStreamSource.journal,
            target: 'docker.service',
          ),
        ),
        const CloseStream('stream-1'),
        const DockerQuery(
          'srv-1',
          DockerQuerySpec(kind: DockerQueryKind.containers),
        ),
        const PlanAction(
          ActionIntent(serverId: 'srv-1', action: 'container.restart'),
        ),
        const RunAction(
          'plan-1',
          ActionConfirmation(
            tier: ConfirmationTier.typedPhrase,
            phrase: 'web-1',
          ),
        ),
        const AnswerPrompt('prompt-1', PromptTrustAnswer(true)),
        const HandleAlert('alert-1', AlertAction.acknowledge),
        const OpenTerminal(
          serverId: 'srv-1',
          containerId: 'abc123',
          shell: '/bin/sh',
        ),
      ];

      for (final request in requests) {
        final received = await roundTrip(request);
        expect(
          received,
          isA<EngineRequest>(),
          reason: '$request lost its type',
        );
        expect(received.runtimeType, request.runtimeType);
      }
    });

    test('every event type survives the isolate boundary', () async {
      final events = <EngineEvent>[
        const EngineReady(kEngineProtocolVersion),
        const RequestRejected('Connect', 'nope'),
        CatalogReplaced(const [_webEntry]),
        const SshConfigImported(importedCount: 1, skippedCount: 0),
        const SyncStatus(SyncPhase.running),
        const EndpointChanged('srv-1'),
        const LinkState('srv-1', LinkPhase.connected),
        Sample(
          serverId: 'srv-1',
          seq: 7,
          snapshot: OverviewSnapshot(meminfo: MemInfo({'MemTotal': 1024})),
        ),
        const LogBatch(streamId: 'stream-1', lines: ['a'], dropped: 2),
        const DockerResult(serverId: 'srv-1', payload: {'Id': 'x'}),
        const DockerEvent('srv-1', {'status': 'start'}),
        const ActionPlanned('plan-1', ActionPreview(title: 'restart')),
        const ActionProgress(planId: 'plan-1', stepIndex: 1, stepCount: 3),
        const ActionFinished(
          planId: 'plan-1',
          outcome: ActionOutcome.succeeded,
        ),
        const Prompt(
          promptId: 'p-1',
          serverId: 'srv-1',
          kind: PromptKind.hostKey,
          message: 'trust?',
        ),
        const AlertsArrived('srv-1', [
          AlertDescriptor(ref: 'a-1', title: 'disk'),
        ]),
        const AlertStatusChanged('a-1', AlertStatus.acknowledged),
        TerminalBytes('t-1', Uint8List.fromList(const [1, 2, 3])),
        const TerminalClosed('t-1'),
      ];

      for (final event in events) {
        final received = await roundTrip(event);
        expect(received, isA<EngineEvent>(), reason: '$event lost its type');
        expect(received.runtimeType, event.runtimeType);
      }
    });

    test('compound fields survive: collectors, cadence, snapshot', () async {
      const request = Subscribe(
        serverId: 'srv-9',
        collectors: {Collector.fs, Collector.identity},
        cadence: Duration(milliseconds: 1500),
      );
      final received = await roundTrip(request) as Subscribe;
      expect(received.serverId, 'srv-9');
      expect(received.collectors, {Collector.fs, Collector.identity});
      expect(received.cadence, const Duration(milliseconds: 1500));

      final event =
          await roundTrip(
                Sample(
                  serverId: 'srv-9',
                  seq: 42,
                  snapshot: OverviewSnapshot(
                    meminfo: MemInfo({'MemTotal': 1024, 'MemAvailable': 512}),
                  ),
                ),
              )
              as Sample;
      expect(event.seq, 42);
      expect(event.snapshot.meminfo.totalKb, 1024);
    });

    test('fleet entries survive with every field and stay read-only', () async {
      final event =
          await roundTrip(
                CatalogReplaced(const [
                  _webEntry,
                  FleetEntry(
                    serverId: '0b9a6f3e-2d1c-4e5f-8a7b-6c5d4e3f2a1b',
                    label: 'db-1',
                    host: '10.0.0.4',
                    port: kSshDefaultPort,
                    origin: FleetEntryOrigin.synced,
                    group: 'Production',
                  ),
                ]),
              )
              as CatalogReplaced;

      final [web, db] = event.entries;
      expect(web.serverId, 'ssh-config:web-1');
      expect(web.label, 'web-1');
      expect(web.host, 'web-1.example');
      expect(web.port, 2222);
      expect(web.user, 'deploy');
      expect(web.group, isNull);
      expect(web.origin, FleetEntryOrigin.sshConfig);
      expect(db.user, isNull);
      expect(db.group, 'Production');
      expect(db.origin, FleetEntryOrigin.synced);
      // The snapshot replaces the UI's list wholesale; nobody edits it in
      // place, on either side of the boundary.
      expect(() => event.entries.add(_webEntry), throwsUnsupportedError);

      final answer =
          await roundTrip(
                const SshConfigImported(importedCount: 3, skippedCount: 2),
              )
              as SshConfigImported;
      expect(answer.importedCount, 3);
      expect(answer.skippedCount, 2);

      final request =
          await roundTrip(const ImportSshConfig('Host a\n')) as ImportSshConfig;
      expect(request.text, 'Host a\n');
    });

    test('sealed answers and typed bytes survive', () async {
      final trust =
          await roundTrip(const AnswerPrompt('p', PromptTrustAnswer(false)))
              as AnswerPrompt;
      expect((trust.answer as PromptTrustAnswer).accepted, isFalse);

      final bytes =
          await roundTrip(TerminalBytes('t', Uint8List.fromList(const [9, 8])))
              as TerminalBytes;
      expect(bytes.bytes, orderedEquals(const [9, 8]));
    });
  });
}
