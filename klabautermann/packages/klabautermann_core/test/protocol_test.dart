import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        CoreCpuTimes,
        CronDst,
        CronExpression,
        CronJob,
        CronJobEntry,
        FsMount,
        ServerZone,
        SystemdTimer,
        mergeJobs,
        perCpuBusyPercent;
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
        const EnrollSync(
          baseUrl: 'https://sync.example.com',
          username: 'ops',
          password: 'pw',
          encryptionPassphrase: 'pp',
        ),
        const RunSyncRound(),
        AnswerKeystore(3, KeystoreMasterKey(Uint8List.fromList([1, 2]))),
        const ConfirmEndpoints(['a', 'b']),
        const SetMonitorSet(['a']),
        const Connect('srv-1'),
        const Disconnect('srv-1'),
        const SetAppActivity(AppActivity.background),
        const Subscribe(
          serverId: 'srv-1',
          subscriptionId: 'row',
          streams: {SampleStream.overview, SampleStream.fs},
        ),
        const Unsubscribe(serverId: 'srv-1', subscriptionId: 'row'),
        const RefreshSubscription(serverId: 'srv-1', subscriptionId: 'row'),
        const SetCadenceProfile(CadenceProfile.phone),
        const ImportSshConfig('Host web-1\n  HostName web-1.example\n'),
        OpenLogStream(
          streamId: 'stream-1',
          spec: LogStreamSpec(
            serverId: 'srv-1',
            source: const JournalLogSource(unit: 'docker.service'),
            window: 50,
            follow: false,
          ),
        ),
        const CloseStream('stream-1'),
        const DockerQuery(
          serverId: 'srv-1',
          queryId: 'q-1',
          query: DockerContainersQuery(),
        ),
        const PlanAction(KillProcess('srv-1', pid: 42, startTicks: 9001)),
        const PlanAction(
          UnitAction(
            'srv-1',
            unit: 'nginx.service',
            verb: SystemctlVerb.restart,
          ),
        ),
        const PlanAction(StartTimer('srv-1', timer: 'backup.timer')),
        const PlanAction(
          ContainerAction(
            'srv-1',
            containerId: 'abc123',
            verb: ContainerVerb.kill,
            signal: KillSignal.sighup,
          ),
        ),
        const PlanAction(
          RemoveContainer('srv-1', containerId: 'abc123', volumes: true),
        ),
        const PlanAction(RemoveImage('srv-1', image: 'busybox:1', force: true)),
        const PlanAction(
          StackAction(
            'srv-1',
            project: 'web',
            verb: StackVerb.restart,
            actAnyway: true,
          ),
        ),
        const PlanAction(
          RedeployStack('srv-1', project: 'web', removeOrphans: true),
        ),
        const RunAction(
          'plan-1',
          ActionConfirmation(
            tier: ConfirmationTier.typedPhrase,
            phrase: 'web-1',
          ),
        ),
        const SetSafetyPolicy(
          SafetyPolicy(
            globalReadOnly: true,
            servers: {'srv-1': ServerSafety(management: true, readOnly: true)},
            adminExpiry: Duration(minutes: 30),
          ),
        ),
        const SetAdminMode('srv-1', enabled: true),
        const AnswerPrompt('prompt-1', PromptTrustAnswer(true)),
        const AnswerPrompt('prompt-2', PromptCancelAnswer()),
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
        const ConnectRejected('srv-1', ConnectRejectedReason.noLoginName),
        CatalogReplaced(const [_webEntry]),
        const SshConfigImported(importedCount: 1, skippedCount: 0, saved: true),
        const SyncStatus(
          SyncPhase.failed,
          operation: SyncOperation.enroll,
          account: SyncAccountInfo(
            baseUrl: 'https://sync.example.com',
            username: 'ops',
          ),
          failure: SyncFailure.credentialsRejected,
        ),
        const KeystoreRequest(4, KeystorePutApiKey('sync.token', 't')),
        const EndpointChanged('srv-1'),
        const LinkState('srv-1', LinkReady()),
        const Reachability('srv-1', ReachabilityStatus.online),
        Sample(
          serverId: 'srv-1',
          stream: SampleStream.overview,
          seq: 7,
          at: DateTime.utc(2026, 10, 14, 12),
          result: OverviewResult(),
        ),
        SamplingState(
          serverId: 'srv-1',
          phase: SamplingPhase.sampling,
          since: DateTime.utc(2026, 10, 14, 12),
        ),
        Gap(
          serverId: 'srv-1',
          streams: const {SampleStream.core},
          from: DateTime.utc(2026, 10, 14, 12),
          until: DateTime.utc(2026, 10, 14, 12, 1),
          cause: GapCause.readingLost,
        ),
        HostProfileChanged('srv-1', HostProfile()),
        LogBatch(
          streamId: 'stream-1',
          records: const [FileRecord('a')],
          dropped: 2,
        ),
        const LogStreamState('stream-1', LogStreamRunning()),
        const DockerResult(
          serverId: 'srv-1',
          queryId: 'q-1',
          payload: DockerImagesPayload([]),
        ),
        const DockerEndpointState(
          serverId: 'srv-1',
          phase: DockerEndpointPhase.waiting,
        ),
        const DockerEvent('srv-1', {'status': 'start'}),
        ActionPlanned(
          'plan-1',
          ActionPreview(
            intent: const ContainerAction(
              'srv-1',
              containerId: 'abc123',
              verb: ContainerVerb.restart,
            ),
            targetName: 'web-1',
            steps: [
              ShellStep(['systemctl', 'restart', 'nginx.service']),
              ApiStep(
                method: 'POST',
                path: '/v1.44/containers/abc123/restart',
                query: {'t': '10'},
              ),
            ],
            requiredLevel: RequiredLevel.admin,
            runner: const RunnerFacts(
              identity: 'root',
              engine: 'docker',
              credentials: RunnerCredentials.adminPassword,
            ),
            requiredTier: ConfirmationTier.typedPhrase,
            hostWrites: const [HostWriteRow.engineState],
            danger: const [
              DangerFinding(
                severity: DangerSeverity.warning,
                pattern: 'systemctl restart',
                explanation: 'restarts a service',
                line: 1,
              ),
            ],
            impact: const PlanImpact(ImpactKind.stopsContainers, count: 3),
            ownership: const PlanOwnership('coolify'),
            protected: ProtectedReason.userMarked,
          ),
        ),
        const ActionRefused(
          ActionRefusalReason.notImplemented,
          intent: StartTimer('srv-1', timer: 'backup.timer'),
        ),
        const ActionRefused(ActionRefusalReason.stalePlan, planId: 'plan-1'),
        AdminModeState(
          'srv-1',
          AdminModePhase.on,
          expiresAt: DateTime.utc(2026, 10, 18, 12, 15),
        ),
        const AdminModeState(
          'srv-1',
          AdminModePhase.failed,
          failure: AdminFailure.ttyRequired,
        ),
        const AdminModeState(
          'srv-1',
          AdminModePhase.expired,
          ended: AdminEnd.linkLost,
        ),
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

    test('Docker queries, results and endpoint states survive with their '
        'payloads (M7)', () async {
      final query =
          await roundTrip(
                const DockerQuery(
                  serverId: 'srv-1',
                  queryId: 'q-7',
                  query: DockerContainerQuery('db'),
                ),
              )
              as DockerQuery;
      expect(query.serverId, 'srv-1');
      expect(query.queryId, 'q-7');
      expect((query.query as DockerContainerQuery).containerId, 'db');

      final result =
          await roundTrip(
                DockerResult(
                  serverId: 'srv-1',
                  queryId: 'q-7',
                  payload: DockerContainerPayload(
                    ContainerDetails(
                      id: 'abc',
                      args: [MaskedValue.secret('hunter2')],
                      state: ContainerDetailsState(
                        running: true,
                        health: ContainerDetailsHealth(
                          status: HealthStatus.healthy,
                          log: [
                            ContainerHealthCheck(
                              exitCode: 0,
                              output: MaskedValue.plain('ok'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  warnings: const ['Labels is not an object'],
                ),
              )
              as DockerResult;
      final details = (result.payload as DockerContainerPayload).container;
      expect(details.args.single.display, MaskedValue.maskToken);
      expect(details.args.single.reveal(), 'hunter2');
      expect(details.state!.health!.log.single.output!.display, 'ok');
      expect(result.warnings, ['Labels is not an object']);

      final state =
          await roundTrip(
                const DockerEndpointState(
                  serverId: 'srv-1',
                  phase: DockerEndpointPhase.ready,
                  route: DockerEndpointRoute(
                    rank: DockerRank.cliRelay,
                    socketPath: '/var/run/docker.sock',
                    rootEquivalence: DockerRootEquivalence.rootfulSocket,
                    runtime: EngineRuntime.podman,
                    mode: EngineMode.rootful,
                  ),
                  negotiatedApi: ApiVersion(1, 44),
                ),
              )
              as DockerEndpointState;
      expect(state.label, DockerRouteLabel.cliRelay);
      expect(state.route!.runtime, EngineRuntime.podman);
      expect(state.negotiatedApi, const ApiVersion(1, 44));

      final failed =
          await roundTrip(
                const DockerResult(
                  serverId: 'srv-1',
                  queryId: 'q-8',
                  payload: DockerQueryFailed(
                    DockerQueryFailure.notFound,
                    detail: 'No such container: db',
                  ),
                ),
              )
              as DockerResult;
      expect(
        (failed.payload as DockerQueryFailed).failure,
        DockerQueryFailure.notFound,
      );
    });

    test('sampling requests survive with their ids, streams and '
        'profile (D45)', () async {
      final subscribe =
          await roundTrip(
                const Subscribe(
                  serverId: 'srv-9',
                  subscriptionId: 'overview',
                  streams: {SampleStream.core, SampleStream.failedUnits},
                ),
              )
              as Subscribe;
      expect(subscribe.serverId, 'srv-9');
      expect(subscribe.subscriptionId, 'overview');
      expect(subscribe.streams, {SampleStream.core, SampleStream.failedUnits});

      final unsubscribe =
          await roundTrip(
                const Unsubscribe(serverId: 'srv-9', subscriptionId: 'row'),
              )
              as Unsubscribe;
      expect(unsubscribe.serverId, 'srv-9');
      expect(unsubscribe.subscriptionId, 'row');

      final refresh =
          await roundTrip(
                const RefreshSubscription(
                  serverId: 'srv-9',
                  subscriptionId: 'processes',
                ),
              )
              as RefreshSubscription;
      expect(refresh.serverId, 'srv-9');
      expect(refresh.subscriptionId, 'processes');

      for (final profile in CadenceProfile.values) {
        final received =
            await roundTrip(SetCadenceProfile(profile)) as SetCadenceProfile;
        expect(received.profile, profile);
      }
    });

    test('every sample result survives with its values (D43)', () async {
      Future<SampleResult> result(
        SampleStream stream,
        SampleResult value,
      ) async {
        final sample =
            await roundTrip(
                  Sample(
                    serverId: 'srv-1',
                    stream: stream,
                    seq: 41,
                    at: DateTime.utc(2026, 10, 14, 12, 0, 5),
                    result: value,
                  ),
                )
                as Sample;
        expect(sample.serverId, 'srv-1');
        expect(sample.stream, stream);
        expect(sample.seq, 41);
        expect(sample.at, DateTime.utc(2026, 10, 14, 12, 0, 5));
        return sample.result;
      }

      const memory = MemoryUsage(
        totalBytes: 8192,
        usedBytes: 4096,
        availableBytes: 4096,
        buffersBytes: 256,
        cachedBytes: 1024,
        sharedBytes: 128,
        swapTotalBytes: 2048,
        swapUsedBytes: 512,
        zfsArcCountedAsUsed: true,
      );
      const cpu = CpuPercentages([10, 0, 5, 80, 5], 15);
      const load = LoadAvg(load1: 1.5, load5: 1, load15: 0.5);

      final overview =
          await result(
                SampleStream.overview,
                OverviewResult(
                  cpu: cpu,
                  memory: memory,
                  load: load,
                  loadPerCore: 0.375,
                  network: const {
                    'eth0': NetRate(rxBytesPerSecond: 10, txBytesPerSecond: 2),
                  },
                  withheld: const {
                    MetricField.load: MetricWithheldReason.containerHostFigures,
                  },
                ),
              )
              as OverviewResult;
      expect(overview.cpu!.busy, 15);
      expect(overview.cpu!.system, 5);
      expect(overview.memory!.usedBytes, 4096);
      expect(overview.memory!.sharedBytes, 128);
      expect(overview.memory!.swapUsedBytes, 512);
      expect(overview.memory!.zfsArcCountedAsUsed, isTrue);
      expect(overview.load!.load5, 1);
      expect(overview.loadPerCore, 0.375);
      expect(overview.network!['eth0']!.rxBytesPerSecond, 10);
      expect(() => overview.network!.clear(), throwsUnsupportedError);
      expect(overview.withheld, {
        MetricField.load: MetricWithheldReason.containerHostFigures,
      });
      expect(() => overview.withheld.clear(), throwsUnsupportedError);

      final core =
          await result(
                SampleStream.core,
                CoreResult(
                  cpu: cpu,
                  // The host sends each core's busy and idle jiffies only
                  // (D48), so the engine can fill exactly this map.
                  perCpu: perCpuBusyPercent(
                    const {'cpu0': CoreCpuTimes('cpu0', busy: 10, idle: 90)},
                    const {'cpu0': CoreCpuTimes('cpu0', busy: 25, idle: 175)},
                  ),
                  disks: const {
                    'sda': DiskRate(
                      readBytesPerSecond: 512,
                      writeBytesPerSecond: 1024,
                    ),
                  },
                  ioPressure: const StallShares(some: StallAverages(1, 2, 3)),
                  uptime: const Duration(days: 3),
                  bootedAt: DateTime.utc(2026, 10, 11, 12),
                ),
              )
              as CoreResult;
      expect(core.perCpu, {'cpu0': 15});
      expect(core.disks!['sda']!.writeBytesPerSecond, 1024);
      expect(core.ioPressure!.some!.avg60, 2);
      expect(core.cpuPressure, isNull);
      expect(core.uptime, const Duration(days: 3));
      expect(core.bootedAt, DateTime.utc(2026, 10, 11, 12));
      // No previous reading is unknown, not zero (03 §1.2 principle 6).
      expect(core.network, isNull);
      final measuredNone =
          await result(SampleStream.overview, OverviewResult(network: {}))
              as OverviewResult;
      expect(measuredNone.network, isEmpty);

      final fs =
          await result(
                SampleStream.fs,
                FsResult(
                  FsSnapshot([
                    const FsMount(
                      device: '/dev/sda1',
                      type: 'ext4',
                      mountPoint: '/',
                      capacityPercent: 42,
                    ),
                  ]),
                ),
              )
              as FsResult;
      expect(fs.fs.mounts.single.capacityPercent, 42);

      final identity =
          await result(
                SampleStream.identity,
                const IdentityResult(
                  hostname: 'web-1',
                  osPrettyName: 'Debian GNU/Linux 12 (bookworm)',
                  kernelName: 'Linux',
                  kernelRelease: '6.1.0-26-amd64',
                  arch: 'x86-64',
                ),
              )
              as IdentityResult;
      expect(identity.hostname, 'web-1');
      expect(identity.osPrettyName, 'Debian GNU/Linux 12 (bookworm)');
      expect(identity.kernelName, 'Linux');
      expect(identity.kernelRelease, '6.1.0-26-amd64');
      expect(identity.arch, 'x86-64');

      final procs =
          await result(
                SampleStream.procs,
                ProcsResult(
                  [
                    ProcessRow(
                      pid: 812,
                      parentPid: 1,
                      name: 'mysql',
                      state: 'S',
                      userName: 'root',
                      uid: 0,
                      residentBytes: 8192,
                      cpuPercent: 0.5,
                      startTicks: 1234,
                      startedAt: DateTime.utc(2026, 10, 15, 9, 41),
                      arguments: [
                        MaskedValue.plain('mysql'),
                        MaskedValue.redacted('-p********', '-phunter2'),
                      ],
                    ),
                  ],
                  totalProcesses: 2083,
                  selection: ProcsSelection.cpuAndMemory,
                ),
              )
              as ProcsResult;
      expect(procs.totalProcesses, 2083);
      expect(procs.selection, ProcsSelection.cpuAndMemory);
      final mysql = procs.processes.single;
      expect(mysql.pid, 812);
      expect(mysql.parentPid, 1);
      expect(mysql.name, 'mysql');
      expect(mysql.userName, 'root');
      expect(mysql.residentBytes, 8192);
      expect(mysql.cpuPercent, 0.5);
      expect(mysql.startTicks, 1234);
      expect(mysql.startedAt, DateTime.utc(2026, 10, 15, 9, 41));
      // A masked argument crosses with its real text for the reveal
      // action (03 §8.9), and shows the mask.
      expect(mysql.arguments!.map((a) => a.display), ['mysql', '-p********']);
      expect(mysql.arguments!.last.reveal(), '-phunter2');

      const failedUnit = SystemdUnit(unit: 'nginx.service', active: 'failed');
      final units =
          await result(
                SampleStream.units,
                UnitsResult(
                  UnitsSnapshot(
                    units: const [failedUnit],
                    failed: const [failedUnit],
                  ),
                ),
              )
              as UnitsResult;
      expect(units.units.units.single.unit, 'nginx.service');
      final failed =
          await result(
                SampleStream.failedUnits,
                FailedUnitsResult(const [failedUnit]),
              )
              as FailedUnitsResult;
      expect(failed.failed.single.active, 'failed');

      final timers =
          await result(
                SampleStream.timers,
                TimersResult(
                  TimersSnapshot(
                    timers: const [
                      SystemdTimer(unit: 'apt-daily.timer', nextUs: 1),
                    ],
                  ),
                ),
              )
              as TimersResult;
      expect(timers.timers.timers.single.unit, 'apt-daily.timer');

      final crontab = CronSnapshot(
        jobs: [
          CronJob(
            source: '/etc/crontab',
            schedule: '@daily',
            user: 'root',
            command: 'backup',
            raw: '@daily root backup',
            expression: CronExpression.parse('@daily'),
          ),
        ],
      );
      final cron =
          await result(
                SampleStream.cron,
                CronResult(
                  crontab,
                  // The zone, which holds a function, stays behind (D52).
                  jobs: mergeJobs(
                    cron: crontab,
                    nowUtc: DateTime.utc(2026, 10, 14, 12),
                    zone: const ServerZone(offset: Duration(hours: 2)),
                  ),
                  zoneFallback: CronZoneFallback.noZoneName,
                ),
              )
              as CronResult;
      expect(cron.cron.jobs.single.command, 'backup');
      final run = (cron.jobs.single as CronJobEntry).nextRuns.first;
      expect(run.atUtc, DateTime.utc(2026, 10, 14, 22));
      expect(run.offset, const Duration(hours: 2));
      expect(run.dst, CronDst.none);
      expect(cron.zoneName, isNull);
      expect(cron.zoneFallback, CronZoneFallback.noZoneName);

      final unavailable =
          await result(
                SampleStream.units,
                const CollectorUnavailable(
                  CollectorUnavailableReason.missing,
                  detail: 'systemctl: not found',
                ),
              )
              as CollectorUnavailable;
      expect(unavailable.reason, CollectorUnavailableReason.missing);
      expect(unavailable.detail, 'systemctl: not found');
    });

    test('a sample holds its stream\'s variant or CollectorUnavailable', () {
      final variants = <SampleStream, SampleResult>{
        SampleStream.overview: OverviewResult(),
        SampleStream.core: CoreResult(),
        SampleStream.fs: FsResult(FsSnapshot(const [])),
        SampleStream.identity: const IdentityResult(),
        SampleStream.procs: ProcsResult(const []),
        SampleStream.units: UnitsResult(UnitsSnapshot()),
        SampleStream.failedUnits: FailedUnitsResult(const []),
        SampleStream.timers: TimersResult(TimersSnapshot()),
        SampleStream.cron: CronResult(CronSnapshot()),
      };
      expect(variants.keys, SampleStream.values);
      const unavailable = CollectorUnavailable(
        CollectorUnavailableReason.timeout,
      );

      Sample sample(SampleStream stream, SampleResult result) => Sample(
        serverId: 'srv-1',
        stream: stream,
        seq: 1,
        at: DateTime.utc(2026, 10, 14, 12),
        result: result,
      );

      for (final stream in SampleStream.values) {
        expect(sample(stream, unavailable).result, same(unavailable));
        for (final MapEntry(key: variantStream, value: result)
            in variants.entries) {
          if (variantStream == stream) {
            expect(sample(stream, result).result, same(result));
            continue;
          }

          expect(
            () => sample(stream, result),
            throwsA(isA<AssertionError>()),
            reason: '${result.runtimeType} is not a $stream result',
          );
        }
      }
    });

    test('sampling states, gaps and host profiles survive', () async {
      for (final phase in SamplingPhase.values) {
        final state =
            await roundTrip(
                  SamplingState(
                    serverId: 'srv-1',
                    phase: phase,
                    since: DateTime.utc(2026, 10, 14, 12, 1),
                  ),
                )
                as SamplingState;
        expect(state.serverId, 'srv-1');
        expect(state.phase, phase);
        expect(state.since, DateTime.utc(2026, 10, 14, 12, 1));
      }

      for (final cause in GapCause.values) {
        final gap =
            await roundTrip(
                  Gap(
                    serverId: 'srv-1',
                    streams: const {SampleStream.overview, SampleStream.fs},
                    from: DateTime.utc(2026, 10, 14, 12, 1),
                    until: DateTime.utc(2026, 10, 14, 12, 14),
                    cause: cause,
                  ),
                )
                as Gap;
        expect(gap.serverId, 'srv-1');
        expect(gap.streams, {SampleStream.overview, SampleStream.fs});
        expect(gap.from, DateTime.utc(2026, 10, 14, 12, 1));
        expect(gap.until, DateTime.utc(2026, 10, 14, 12, 14));
        expect(gap.cause, cause);
      }

      final changed =
          await roundTrip(
                HostProfileChanged(
                  'srv-1',
                  HostProfile(
                    systemdVersion: 252,
                    groups: const ['adm', 'systemd-journal'],
                    tools: const {'timeout': '/usr/bin/timeout', 'zstd': null},
                  ),
                  cachedAt: DateTime.utc(2026, 10, 15, 9),
                ),
              )
              as HostProfileChanged;
      expect(changed.serverId, 'srv-1');
      expect(changed.cachedAt, DateTime.utc(2026, 10, 15, 9));
      expect(changed.profile.systemdVersion, 252);
      expect(changed.profile.groups, ['adm', 'systemd-journal']);
      expect(changed.profile.timeoutPresent, isTrue);
      expect(changed.profile.toolPresent('zstd'), isFalse);
      expect(changed.profile.kernelRelease, isNull);
    });

    test('log stream requests survive with their specs', () async {
      Future<LogStreamSpec> spec(LogStreamSpec value) async {
        final open =
            await roundTrip(OpenLogStream(streamId: 'logs-1', spec: value))
                as OpenLogStream;
        expect(open.streamId, 'logs-1');
        return open.spec;
      }

      // LOG-01's filters, paging on from the oldest record held.
      final journal = await spec(
        LogStreamSpec(
          serverId: 'srv-1',
          source: JournalLogSource(
            unit: 'nginx.service',
            identifier: 'nginx',
            priority: LogPriority.warning,
            currentBootOnly: true,
            since: DateTime.utc(2026, 10, 14),
            until: DateTime.utc(2026, 10, 15),
          ),
          window: 500,
          follow: false,
          afterCursor: 's=ab;i=1f;b=cd;m=2;t=3;x=4',
        ),
      );
      expect(journal.serverId, 'srv-1');
      expect(journal.window, 500);
      expect(journal.follow, isFalse);
      expect(journal.afterCursor, 's=ab;i=1f;b=cd;m=2;t=3;x=4');
      final filters = journal.source as JournalLogSource;
      expect(filters.unit, 'nginx.service');
      expect(filters.identifier, 'nginx');
      expect(filters.priority, LogPriority.warning);
      expect(filters.currentBootOnly, isTrue);
      expect(filters.since, DateTime.utc(2026, 10, 14));
      expect(filters.until, DateTime.utc(2026, 10, 15));

      final unfiltered = await spec(
        LogStreamSpec(
          serverId: 'srv-1',
          source: const JournalLogSource(),
          window: 100,
          follow: true,
        ),
      );
      final none = unfiltered.source as JournalLogSource;
      expect(none.unit, isNull);
      expect(none.priority, isNull);
      expect(none.currentBootOnly, isFalse);
      expect(none.since, isNull);
      expect(unfiltered.afterCursor, isNull);

      final kernel = await spec(
        LogStreamSpec(
          serverId: 'srv-1',
          source: const KernelLogSource(),
          window: 0,
          follow: true,
        ),
      );
      expect(kernel.source, isA<KernelLogSource>());
      expect(kernel.window, 0);
      expect(kernel.follow, isTrue);

      final file = await spec(
        LogStreamSpec(
          serverId: 'srv-1',
          source: const FileLogSource('/var/log/nginx/access.log'),
          window: 200,
          follow: true,
        ),
      );
      expect((file.source as FileLogSource).path, '/var/log/nginx/access.log');

      final close = await roundTrip(const CloseStream('logs-1')) as CloseStream;
      expect(close.streamId, 'logs-1');
    });

    test('a log spec holds only what its source and mode can read', () {
      LogStreamSpec spec({
        LogSource source = const JournalLogSource(),
        int window = 10,
        bool follow = false,
        String? afterCursor,
      }) => LogStreamSpec(
        serverId: 'srv-1',
        source: source,
        window: window,
        follow: follow,
        afterCursor: afterCursor,
      );

      expect(() => spec(window: -1), throwsA(isA<AssertionError>()));
      expect(
        () => spec(
          source: const FileLogSource('/var/log/syslog'),
          afterCursor: 's=1',
        ),
        throwsA(isA<AssertionError>()),
        reason: 'a file tail has no cursor',
      );
      final bounded = JournalLogSource(until: DateTime.utc(2026, 10, 15));
      expect(
        () => spec(source: bounded, follow: true),
        throwsA(isA<AssertionError>()),
        reason: 'a follow reads up to the present',
      );

      expect(spec(source: bounded).follow, isFalse);
      expect(
        spec(source: const KernelLogSource(), afterCursor: 's=1').afterCursor,
        's=1',
      );
      expect(
        () => LogBatch(streamId: 'logs-1', records: const [], dropped: -1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('every log record survives with its values', () async {
      final batch =
          await roundTrip(
                LogBatch(
                  streamId: 'logs-1',
                  // Growable, so the read-only check below proves the
                  // batch holds its own copy.
                  records: [
                    JournalRecord(
                      cursor: 's=ab;i=1f',
                      at: DateTime.utc(2026, 10, 14, 12, 0, 0, 0, 7),
                      priority: LogPriority.error,
                      unit: 'nginx.service',
                      identifier: 'nginx',
                      pid: 812,
                      message: 'bind() failed',
                      fields: Map.unmodifiable({
                        '__CURSOR': 's=ab;i=1f',
                        'MESSAGE': 'bind() failed',
                        'CODE_LINE': null,
                      }),
                    ),
                    const KernelRecord(
                      message: 'usb 1-1: new high-speed USB device',
                      sinceBoot: Duration(seconds: 3, microseconds: 12),
                      priority: LogPriority.info,
                    ),
                    const KernelRecord(message: 'no level'),
                    const FileRecord('GET / HTTP/1.1 200'),
                  ],
                  dropped: 41,
                ),
              )
              as LogBatch;
      expect(batch.streamId, 'logs-1');
      expect(batch.dropped, 41);
      expect(batch.records.map((r) => r.runtimeType), [
        JournalRecord,
        KernelRecord,
        KernelRecord,
        FileRecord,
      ]);
      expect(() => batch.records.clear(), throwsUnsupportedError);

      final journal = batch.records[0] as JournalRecord;
      expect(journal.cursor, 's=ab;i=1f');
      expect(journal.at, DateTime.utc(2026, 10, 14, 12, 0, 0, 0, 7));
      expect(journal.priority, LogPriority.error);
      expect(journal.unit, 'nginx.service');
      expect(journal.identifier, 'nginx');
      expect(journal.pid, 812);
      expect(journal.message, 'bind() failed');
      expect(journal.fields, {
        '__CURSOR': 's=ab;i=1f',
        'MESSAGE': 'bind() failed',
        'CODE_LINE': null,
      });
      expect(journal.fields.containsKey('CODE_LINE'), isTrue);
      expect(() => journal.fields.clear(), throwsUnsupportedError);

      final kernel = batch.records[1] as KernelRecord;
      expect(kernel.message, 'usb 1-1: new high-speed USB device');
      expect(kernel.sinceBoot, const Duration(seconds: 3, microseconds: 12));
      expect(kernel.priority, LogPriority.info);
      final unleveled = batch.records[2] as KernelRecord;
      expect(unleveled.sinceBoot, isNull);
      expect(unleveled.priority, isNull);

      expect((batch.records[3] as FileRecord).text, 'GET / HTTP/1.1 200');

      final empty = await roundTrip(const JournalRecord()) as JournalRecord;
      expect(empty.fields, isEmpty);
      expect(empty.cursor, isNull);
      expect(empty.at, isNull);
    });

    test('log stream states survive and compare by value', () async {
      final statuses = <LogStreamStatus>[
        for (final reason in LogStreamWaitReason.values)
          LogStreamWaiting(reason),
        for (final reader in LogReader.values) LogStreamRunning(reader: reader),
        const LogStreamRunning(continuity: LogContinuity.gap),
        for (final reason in LogStreamEndReason.values) LogStreamEnded(reason),
        const LogStreamEnded(
          LogStreamEndReason.denied,
          detail: "tail: cannot open '/var/log/auth.log': Permission denied",
        ),
      ];

      for (final status in statuses) {
        final state =
            await roundTrip(LogStreamState('logs-1', status)) as LogStreamState;
        expect(state.streamId, 'logs-1');
        expect(state.status, status);
        expect(state.status.hashCode, status.hashCode);
      }

      // Every status differs from every other: by variant, reader,
      // continuity, reason or detail.
      for (var i = 0; i < statuses.length; i++) {
        for (var j = i + 1; j < statuses.length; j++) {
          expect(statuses[i], isNot(statuses[j]));
        }
      }
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
        EndpointConfirmation? endpoint = EndpointConfirmation.confirmed,
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
        endpoint: endpoint,
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
        entry(endpoint: null),
        entry(endpoint: EndpointConfirmation.changed),
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

    test('endpoint confirmation survives: every state on an entry, and '
        'the ids it confirms', () async {
      for (final endpoint in [null, ...EndpointConfirmation.values]) {
        final entry = FleetEntry(
          serverId: '0b9a6f3e-2d1c-4e5f-8a7b-6c5d4e3f2a1b',
          label: 'db-1',
          host: '10.0.0.4',
          port: kSshDefaultPort,
          origin: FleetEntryOrigin.synced,
          endpoint: endpoint,
        );
        final event = await roundTrip(CatalogReplaced([entry]));
        expect((event as CatalogReplaced).entries.single.endpoint, endpoint);
      }

      final request =
          await roundTrip(const ConfirmEndpoints(['a', 'b']))
              as ConfirmEndpoints;
      expect(request.serverIds, ['a', 'b']);
      final changed =
          await roundTrip(const EndpointChanged('srv-1')) as EndpointChanged;
      expect(changed.serverId, 'srv-1');
    });

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
        const LinkClosed(
          LinkClosedReason.connectFailed,
          failure: LinkFailureKind.keyboardInteractiveCancelled,
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

    test('every failure kind survives on a closed link', () async {
      for (final failure in LinkFailureKind.values) {
        final status = LinkClosed(
          LinkClosedReason.connectFailed,
          failure: failure,
        );
        final received =
            await roundTrip(LinkState('srv-1', status)) as LinkState;

        expect(received.status, status);
        expect((received.status as LinkClosed).failure, failure);
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

    test('a Connect rejection keeps its server and every reason', () async {
      for (final reason in ConnectRejectedReason.values) {
        final received =
            await roundTrip(ConnectRejected('ssh-config:web', reason))
                as ConnectRejected;
        expect(
          (received.serverId, received.reason),
          ('ssh-config:web', reason),
        );
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
      expect(
        (hostKey.pinnedFingerprintSha256, hostKey.pinnedKeyType),
        (null, null),
      );
      final changed =
          await request(
                const HostKeyPromptRequest(
                  keyType: 'ecdsa-sha2-nistp256',
                  fingerprintSha256: 'SHA256:new',
                  pinnedFingerprintSha256: 'SHA256:abc',
                  pinnedKeyType: 'ssh-ed25519',
                ),
              )
              as HostKeyPromptRequest;
      expect(
        (
          changed.keyType,
          changed.fingerprintSha256,
          changed.pinnedFingerprintSha256,
          changed.pinnedKeyType,
        ),
        ('ecdsa-sha2-nistp256', 'SHA256:new', 'SHA256:abc', 'ssh-ed25519'),
      );

      final challenge =
          await request(
                const KeyboardInteractivePromptRequest(
                  user: 'jump',
                  name: 'Duo',
                  instruction: 'Second factor',
                  questions: ['Passcode: ', 'Push? '],
                ),
              )
              as KeyboardInteractivePromptRequest;
      expect(challenge.kind, PromptKind.keyboardInteractive);
      expect(challenge.user, 'jump');
      expect(challenge.name, 'Duo');
      expect(challenge.instruction, 'Second factor');
      expect(challenge.questions, ['Passcode: ', 'Push? ']);
      final unnamed =
          await request(const KeyboardInteractivePromptRequest())
              as KeyboardInteractivePromptRequest;
      expect(unnamed.user, isNull);

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
      final cancel =
          await roundTrip(const AnswerPrompt('p', PromptCancelAnswer()))
              as AnswerPrompt;
      expect(cancel.answer, isA<PromptCancelAnswer>());

      final bytes =
          await roundTrip(TerminalBytes('t', Uint8List.fromList(const [9, 8])))
              as TerminalBytes;
      expect(bytes.bytes, orderedEquals(const [9, 8]));
    });
  });

  test('crosses no klabautermann_host type that holds a function '
      '(D52)', () async {
    // The protocol guard checks a field's own type, not the fields of a
    // host class it names, so the host types that cross are listed.
    final uri = await Isolate.resolvePackageUri(
      Uri.parse('package:klabautermann_core/src/engine/protocol.dart'),
    );
    final source = File.fromUri(uri!).readAsStringSync();
    final shown = RegExp(
      r"import 'package:klabautermann_host/klabautermann_host\.dart'"
      r'\s+show([^;]+);',
    ).firstMatch(source)?[1];

    expect(shown, isNotNull, reason: 'host types cross only by name');
    final names = shown!.split(',').map((name) => name.trim()).toSet();
    expect(names, contains('HostProfile'));
    // Collector holds argument validators, ServerZone its `offsetAt`.
    expect(names.intersection({'Collector', 'ServerZone'}), isEmpty);
    // Pressure holds the cumulative stall counter, which stays in the
    // engine (D43); StallShares carries the averages.
    expect(names, isNot(contains('Pressure')));
    // A JournalEntry parses its columns on every read; the engine resolves
    // it into a JournalRecord.
    expect(names, isNot(contains('JournalEntry')));
  });
}
