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
        const CatalogReplaced({'servers': 3}),
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
