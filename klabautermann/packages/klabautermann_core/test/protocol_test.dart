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
        const SetAppActivity(AppActivity.background),
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
        const SshConfigImported(importedCount: 1, skippedCount: 0, saved: true),
        const SyncStatus(SyncPhase.running),
        const EndpointChanged('srv-1'),
        const LinkState('srv-1', LinkReady()),
        const Reachability('srv-1', ReachabilityStatus.online),
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
          host: 'web-1.example',
          port: kSshDefaultPort,
          request: CredentialPromptRequest(user: 'deploy'),
        ),
        const PromptWithdrawn('p-1', PromptWithdrawnReason.expired),
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
                // Growable, so the read-only check below proves the event
                // holds its own copy instead of passing a const list on.
                CatalogReplaced([
                  _webEntry,
                  const FleetEntry(
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
                const SshConfigImported(
                  importedCount: 3,
                  skippedCount: 2,
                  saved: false,
                ),
              )
              as SshConfigImported;
      expect(answer.importedCount, 3);
      expect(answer.skippedCount, 2);
      expect(answer.saved, isFalse);

      final request =
          await roundTrip(const ImportSshConfig('Host a\n')) as ImportSshConfig;
      expect(request.text, 'Host a\n');
    });

    test('the import store issue survives with EngineReady', () async {
      final ready =
          await roundTrip(
                const EngineReady(
                  kEngineProtocolVersion,
                  importStoreIssue: ImportStoreIssue(
                    ImportStoreIssueKind.recovered,
                    preservedAs: '/support/ssh_config_imports.json.corrupt-1',
                    detail: 'entry 0 has no host',
                  ),
                ),
              )
              as EngineReady;
      final issue = ready.importStoreIssue!;
      expect(issue.kind, ImportStoreIssueKind.recovered);
      expect(issue.preservedAs, '/support/ssh_config_imports.json.corrupt-1');
      expect(issue.detail, 'entry 0 has no host');

      final clean =
          await roundTrip(const EngineReady(kEngineProtocolVersion))
              as EngineReady;
      expect(clean.importStoreIssue, isNull);
    });

    test('fleet entries compare by value, across the boundary too', () async {
      // Built at run time, so equal entries are never one canonical const.
      FleetEntry entry({
        String serverId = 'ssh-config:web-1',
        String label = 'web-1',
        String host = 'web-1.example',
        int port = 2222,
        String? user = 'deploy',
        String? group,
        FleetEntryOrigin origin = FleetEntryOrigin.sshConfig,
        List<String>? jumpRoute = const ['bastion'],
        FleetAuthKind? authKind = FleetAuthKind.agent,
        String? searchText = 'web-1 deploy@web-1.example:2222',
        List<String>? locatorConflict = const ['ssh-config:db-1'],
      }) => FleetEntry(
        serverId: serverId,
        label: label,
        host: host,
        port: port,
        user: user,
        group: group,
        origin: origin,
        // Fresh lists, so equality has to compare their items.
        jumpRoute: jumpRoute?.toList(),
        authKind: authKind,
        searchText: searchText,
        locatorConflict: locatorConflict?.toList(),
      );

      final web = entry();
      expect(web, entry());
      expect(web.hashCode, entry().hashCode);
      // Every SendPort copy is a new object; it still equals the original.
      expect(await roundTrip(web), web);

      for (final other in [
        entry(serverId: 'ssh-config:web-2'),
        entry(label: 'web'),
        entry(host: 'web-2.example'),
        entry(port: kSshDefaultPort),
        entry(user: null),
        entry(group: 'Production'),
        entry(origin: FleetEntryOrigin.synced),
        entry(jumpRoute: null),
        entry(jumpRoute: const ['bastion', 'inner']),
        entry(jumpRoute: const []),
        entry(authKind: null),
        entry(authKind: FleetAuthKind.identityFile),
        entry(searchText: null),
        entry(searchText: 'web-1'),
        entry(locatorConflict: null),
        entry(locatorConflict: const ['ssh-config:db-2']),
      ]) {
        expect(web, isNot(other));
      }
    });

    test(
      'the v3 fleet fields survive, and an M1 entry leaves them null',
      () async {
        const routed = FleetEntry(
          serverId: 'ssh-config:inner',
          label: 'inner',
          host: '10.0.0.4',
          port: kSshDefaultPort,
          origin: FleetEntryOrigin.sshConfig,
          jumpRoute: ['bastion', 'deploy@hop.example:2200'],
          authKind: FleetAuthKind.identityFile,
          searchText: 'inner @10.0.0.4:22 ',
          locatorConflict: ['ssh-config:other-inner'],
        );
        final event =
            await roundTrip(CatalogReplaced(const [routed, _webEntry]))
                as CatalogReplaced;

        final [inner, web] = event.entries;
        expect(inner, routed);
        expect(inner.jumpRoute, ['bastion', 'deploy@hop.example:2200']);
        expect(inner.authKind, FleetAuthKind.identityFile);
        expect(inner.searchText, 'inner @10.0.0.4:22 ');
        expect(inner.locatorConflict, ['ssh-config:other-inner']);
        expect(web.jumpRoute, isNull);
        expect(web.authKind, isNull);
        expect(web.searchText, isNull);
        expect(web.locatorConflict, isNull);
      },
    );

    test('every link status survives with its values (D46)', () async {
      final statuses = <LinkStatus>[
        const LinkIdle(),
        const LinkConnecting(),
        const LinkAuthenticating(),
        const LinkReady(),
        const LinkDegraded(LinkDegradedReason.sessionLimitLearned),
        LinkBackoff(DateTime.utc(2026, 10, 14, 12, 0, 30)),
        const LinkNeedsUser(promptId: 'p-1', kind: PromptKind.hostKey),
        const LinkBlocked(LinkBlockedReason.hostKeyChanged),
        const LinkClosed(LinkClosedReason.closedByOwner),
        const LinkClosed(
          LinkClosedReason.connectFailed,
          failure: LinkFailureKind.authenticationRejected,
        ),
      ];

      for (final status in statuses) {
        final received =
            await roundTrip(LinkState('srv-1', status)) as LinkState;
        expect(received.serverId, 'srv-1');
        // Const statuses may arrive shared rather than copied; the backoff's
        // run-time DateTime arrives as a copy, so equality is by value.
        expect(received.status, status);
        expect(received.status.hashCode, status.hashCode);
      }
    });

    test('link statuses differ by variant and by every value', () {
      final distinct = <LinkStatus>[
        const LinkIdle(),
        const LinkConnecting(),
        const LinkAuthenticating(),
        const LinkReady(),
        const LinkDegraded(LinkDegradedReason.sessionLimitLearned),
        LinkBackoff(DateTime.utc(2026, 10, 14, 12)),
        LinkBackoff(DateTime.utc(2026, 10, 14, 12, 0, 1)),
        const LinkNeedsUser(promptId: 'p-1', kind: PromptKind.hostKey),
        const LinkNeedsUser(promptId: 'p-2', kind: PromptKind.hostKey),
        const LinkNeedsUser(promptId: 'p-1', kind: PromptKind.credential),
        const LinkBlocked(LinkBlockedReason.hostKeyChanged),
        const LinkBlocked(LinkBlockedReason.endpointChanged),
        const LinkClosed(LinkClosedReason.closedByOwner),
        const LinkClosed(LinkClosedReason.pingTimeout),
        const LinkClosed(
          LinkClosedReason.pingTimeout,
          failure: LinkFailureKind.timedOut,
        ),
      ];

      // Built at run time, so equal statuses are not one canonical const.
      LinkStatus closed(LinkClosedReason reason, [LinkFailureKind? failure]) =>
          LinkClosed(reason, failure: failure);
      expect(
        closed(LinkClosedReason.linkLost, LinkFailureKind.unreachable),
        closed(LinkClosedReason.linkLost, LinkFailureKind.unreachable),
      );

      for (var i = 0; i < distinct.length; i++) {
        for (var j = 0; j < distinct.length; j++) {
          if (i == j) continue;
          expect(
            distinct[i],
            isNot(distinct[j]),
            reason: '${distinct[i]} vs ${distinct[j]}',
          );
        }
      }
    });

    test('structured prompts survive with every field', () async {
      Future<PromptRequest> request(PromptRequest request) async {
        final prompt =
            await roundTrip(
                  Prompt(
                    promptId: 'p-7',
                    serverId: 'ssh-config:inner',
                    host: 'bastion.example',
                    port: 2200,
                    request: request,
                  ),
                )
                as Prompt;
        // The jump host asks here, not the server the prompt is for.
        expect(prompt.promptId, 'p-7');
        expect(prompt.serverId, 'ssh-config:inner');
        expect(prompt.host, 'bastion.example');
        expect(prompt.port, 2200);
        return prompt.request;
      }

      final hostKey =
          await request(
                const HostKeyPromptRequest(
                  keyType: 'ssh-ed25519',
                  fingerprintSha256: 'SHA256:abc',
                ),
              )
              as HostKeyPromptRequest;
      expect(hostKey.kind, PromptKind.hostKey);
      expect(hostKey.keyType, 'ssh-ed25519');
      expect(hostKey.fingerprintSha256, 'SHA256:abc');

      final challenge =
          await request(
                const KeyboardInteractivePromptRequest(
                  name: 'Duo',
                  instruction: 'Second factor',
                  questions: ['Passcode: ', 'Push? '],
                ),
              )
              as KeyboardInteractivePromptRequest;
      expect(challenge.kind, PromptKind.keyboardInteractive);
      expect(challenge.name, 'Duo');
      expect(challenge.instruction, 'Second factor');
      expect(challenge.questions, ['Passcode: ', 'Push? ']);

      final credential =
          await request(
                const CredentialPromptRequest(user: 'deploy', retry: true),
              )
              as CredentialPromptRequest;
      expect(credential.kind, PromptKind.credential);
      expect(credential.user, 'deploy');
      expect(credential.retry, isTrue);

      final elevation =
          await request(const ElevationPromptRequest(user: 'deploy'))
              as ElevationPromptRequest;
      expect(elevation.kind, PromptKind.elevation);
      expect(elevation.user, 'deploy');
      expect(elevation.retry, isFalse);

      final withdrawn =
          await roundTrip(
                const PromptWithdrawn(
                  'p-7',
                  PromptWithdrawnReason.attemptEnded,
                ),
              )
              as PromptWithdrawn;
      expect(withdrawn.promptId, 'p-7');
      expect(withdrawn.reason, PromptWithdrawnReason.attemptEnded);
    });

    test('app activity and reachability survive', () async {
      for (final activity in AppActivity.values) {
        final received =
            await roundTrip(SetAppActivity(activity)) as SetAppActivity;
        expect(received.activity, activity);
      }
      for (final status in ReachabilityStatus.values) {
        final received =
            await roundTrip(Reachability('srv-1', status)) as Reachability;
        expect(received.serverId, 'srv-1');
        expect(received.status, status);
      }
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
