// TRI-01: the doctor's read-only checklist with fix hints.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/docker_controller.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/controllers/tls_endpoints.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/charts/charts.dart' show ChartThresholds;
import 'package:klabautermann_app/ui/doctor.dart';
import 'package:klabautermann_app/ui/threshold_scope.dart'
    show kDefaultThresholds;
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _server = 'srv-1';
const _gib = 1 << 30;
const _web = TlsEndpoint('example.com', 443);
const _mail = TlsEndpoint('mail.example.com', 993);

final _now = DateTime.utc(2026, 10, 26, 12);

FsMount _mount(String mountPoint, {int use = 40, int inodes = 10}) => FsMount(
  device: '/dev/sda1',
  type: 'ext4',
  mountPoint: mountPoint,
  sizeBytes: 100 * _gib,
  usedBytes: use * _gib,
  availBytes: (100 - use) * _gib,
  capacityPercent: use,
  inodeUsePercent: inodes,
);

SystemdUnit _unit(String name) =>
    SystemdUnit(unit: name, load: 'loaded', active: 'failed', sub: 'failed');

TlsEndpointCheck _cert(TlsEndpoint endpoint, DateTime notAfter) =>
    TlsEndpointCheck(
      endpoint: endpoint,
      certificate: TlsCertificateFacts(
        subject: '/CN=${endpoint.host}',
        issuer: '/CN=R11',
        notBefore: DateTime.utc(2026, 9, 1),
        notAfter: notAfter,
      ),
      trusted: true,
    );

PackagesReport _packages(PackageCheck check) =>
    PackagesReport(serverId: _server, requestId: 'r', check: check);

Map<DoctorCheckKind, DoctorCheck> _byKind(DoctorInputs inputs) => {
  for (final check in doctorChecks(inputs)) check.kind: check,
};

void main() {
  test('a clock the kernel says is synchronized passes with timedated\'s '
      'NTP switch off, as under chrony, and the switch decides only when '
      'the kernel flag is unknown', () {
    DoctorVerdict timeSync(HostProfile profile) => _byKind(
      DoctorInputs(now: _now, profile: profile),
    )[DoctorCheckKind.timeSync]!.verdict;

    expect(
      timeSync(HostProfile(ntpEnabled: false, ntpSynchronized: true)),
      DoctorVerdict.ok,
    );
    expect(
      timeSync(HostProfile(ntpEnabled: true, ntpSynchronized: false)),
      DoctorVerdict.problem,
    );
    expect(timeSync(HostProfile(ntpEnabled: false)), DoctorVerdict.problem);
  });

  test('a healthy server passes every check, in the checklist order', () {
    final checks = doctorChecks(
      DoctorInputs(
        now: _now,
        fs: FsSnapshot([_mount('/')]),
        failedUnits: const [],
        profile: HostProfile(ntpEnabled: true, ntpSynchronized: true),
        skew: Duration.zero,
        packages: _packages(
          PackageCheck(
            manager: PackageManager.apt,
            securityCount: 0,
            reboot: RebootState.notRequired,
          ),
        ),
        endpoints: const [_web],
        tlsChecks: [_cert(_web, DateTime.utc(2027))],
        docker: true,
        diskUse: const DockerDiskUse(
          df: SystemDf(images: DiskUsageTotals(reclaimable: 200 << 20)),
        ),
        images: [
          const ImageSummary(id: 'sha256:a', repoTags: ['nginx:1.27']),
        ],
      ),
    );
    expect([for (final check in checks) check.kind], DoctorCheckKind.values);
    expect([
      for (final check in checks)
        if (check.verdict != DoctorVerdict.ok) check.kind,
    ], isEmpty);
  });

  test('the disk checks judge by the disk bands the user set (OV-11)', () {
    final fs = FsSnapshot([_mount('/', use: 85, inodes: 85)]);
    Map<DoctorCheckKind, DoctorCheck> judged(ChartThresholds levels) =>
        _byKind(DoctorInputs(now: _now, fs: fs, diskLevels: levels));

    expect(
      judged(kDefaultThresholds)[DoctorCheckKind.diskSpace]?.verdict,
      DoctorVerdict.warning,
    );
    final relaxed = judged(
      const ChartThresholds(careful: 80, warning: 90, critical: 95),
    );
    expect(relaxed[DoctorCheckKind.diskSpace]?.verdict, DoctorVerdict.ok);
    expect(relaxed[DoctorCheckKind.inodes]?.verdict, DoctorVerdict.ok);
  });

  test('each finding names what it concerns', () {
    final checks = _byKind(
      DoctorInputs(
        now: _now,
        fs: FsSnapshot([
          _mount('/', use: 85),
          _mount('/var', use: 95, inodes: 82),
        ]),
        failedUnits: [_unit('nginx.service'), _unit('backup.service')],
        profile: HostProfile(ntpEnabled: true, ntpSynchronized: true),
        skew: const Duration(minutes: 3),
        packages: _packages(
          PackageCheck(
            manager: PackageManager.apt,
            updates: const [
              PackageUpdate(name: 'openssl', available: '3.0.13'),
            ],
            securityCount: 1,
            reboot: RebootState.required,
            rebootPackages: const ['linux-image-6.8.0-48'],
          ),
        ),
        endpoints: const [_web, _mail],
        tlsChecks: [
          _cert(_web, _now.add(const Duration(days: 5))),
          _cert(_mail, _now.subtract(const Duration(days: 1))),
        ],
        docker: true,
        diskUse: const DockerDiskUse(
          df: SystemDf(buildCache: DiskUsageTotals(reclaimable: 3 * _gib)),
        ),
        images: [
          const ImageSummary(id: 'sha256:a', repoTags: ['<none>:<none>']),
          const ImageSummary(id: 'sha256:b', size: 100),
          const ImageSummary(id: 'sha256:c', repoTags: ['nginx:1.27']),
        ],
      ),
    );
    expect(
      checks[DoctorCheckKind.diskSpace],
      const DoctorCheck(
        DoctorCheckKind.diskSpace,
        DoctorVerdict.problem,
        count: 95,
        names: ['/var', '/'],
      ),
    );
    expect(
      checks[DoctorCheckKind.inodes],
      const DoctorCheck(
        DoctorCheckKind.inodes,
        DoctorVerdict.warning,
        count: 82,
        names: ['/var'],
      ),
    );
    expect(checks[DoctorCheckKind.failedUnits]!.names, [
      'nginx.service',
      'backup.service',
    ]);
    expect(
      checks[DoctorCheckKind.securityUpdates],
      const DoctorCheck(
        DoctorCheckKind.securityUpdates,
        DoctorVerdict.problem,
        count: 1,
      ),
    );
    expect(
      checks[DoctorCheckKind.rebootRequired],
      const DoctorCheck(
        DoctorCheckKind.rebootRequired,
        DoctorVerdict.warning,
        names: ['linux-image-6.8.0-48'],
      ),
    );
    expect(
      checks[DoctorCheckKind.timeSync],
      const DoctorCheck(
        DoctorCheckKind.timeSync,
        DoctorVerdict.warning,
        skew: Duration(minutes: 3),
      ),
      reason: 'synchronized by its own account, yet off this device',
    );
    expect(
      checks[DoctorCheckKind.certificates],
      const DoctorCheck(
        DoctorCheckKind.certificates,
        DoctorVerdict.problem,
        names: ['mail.example.com:993', 'example.com:443'],
      ),
      reason: 'the expired one first, then the one expiring soon',
    );
    expect(
      checks[DoctorCheckKind.dockerDiskUse],
      const DoctorCheck(
        DoctorCheckKind.dockerDiskUse,
        DoctorVerdict.warning,
        bytes: 3 * _gib,
      ),
    );
    expect(
      checks[DoctorCheckKind.danglingImages],
      const DoctorCheck(
        DoctorCheckKind.danglingImages,
        DoctorVerdict.warning,
        count: 2,
        bytes: 100,
      ),
    );
  });

  test('what is missing reads unknown, checking or not set up', () {
    final checks = _byKind(
      DoctorInputs(
        now: _now,
        fs: FsSnapshot([_mount('/', use: 99)]),
        fsFailed: true,
        packagesReading: true,
      ),
    );
    expect(
      {for (final MapEntry(:key, :value) in checks.entries) key: value.verdict},
      {
        DoctorCheckKind.diskSpace: DoctorVerdict.unknown,
        DoctorCheckKind.inodes: DoctorVerdict.unknown,
        DoctorCheckKind.failedUnits: DoctorVerdict.unknown,
        DoctorCheckKind.securityUpdates: DoctorVerdict.checking,
        DoctorCheckKind.rebootRequired: DoctorVerdict.checking,
        DoctorCheckKind.timeSync: DoctorVerdict.unknown,
        DoctorCheckKind.certificates: DoctorVerdict.notSetUp,
      },
      reason: 'a failed df leaves the older listing unread; no Docker checks',
    );

    final failed = _byKind(
      DoctorInputs(
        now: _now,
        packages: const PackagesReport(
          serverId: _server,
          requestId: 'r',
          failure: PackagesReportFailure.noLink,
        ),
        profile: HostProfile(ntpEnabled: false),
        endpoints: const [_web],
        docker: true,
        diskUse: const DockerDiskUse(inFlight: true),
      ),
    );
    expect(
      failed[DoctorCheckKind.securityUpdates]!.verdict,
      DoctorVerdict.unknown,
    );
    expect(failed[DoctorCheckKind.timeSync]!.verdict, DoctorVerdict.problem);
    expect(
      failed[DoctorCheckKind.certificates]!.verdict,
      DoctorVerdict.unknown,
      reason: 'the engine stopped before it answered',
    );
    expect(
      failed[DoctorCheckKind.dockerDiskUse]!.verdict,
      DoctorVerdict.checking,
    );
  });

  test('updates the manager cannot classify warn', () {
    final checks = _byKind(
      DoctorInputs(
        now: _now,
        packages: _packages(
          PackageCheck(
            manager: PackageManager.pacman,
            updates: const [
              PackageUpdate(name: 'openssl', available: '3.4.1'),
              PackageUpdate(name: 'curl', available: '8.11.1'),
            ],
          ),
        ),
      ),
    );
    expect(
      checks[DoctorCheckKind.securityUpdates],
      const DoctorCheck(
        DoctorCheckKind.securityUpdates,
        DoctorVerdict.warning,
        count: 2,
      ),
    );
    expect(
      checks[DoctorCheckKind.rebootRequired]!.verdict,
      DoctorVerdict.unknown,
    );
  });

  group('the view', () {
    late FakeEngineClient engine;
    late MonitoringController monitoring;
    var seq = 0;

    setUp(() {
      engine = FakeEngineClient();
      monitoring = MonitoringController(
        engine,
        tlsEndpoints: TlsEndpoints(
          stored: {
            _server: [_web],
          },
        ),
      );
    });

    tearDown(() async {
      monitoring.dispose();
      await engine.close();
    });

    void sample(SampleStream stream, SampleResult result) => engine.emit(
      Sample(
        serverId: _server,
        stream: stream,
        seq: ++seq,
        at: _now,
        result: result,
      ),
    );

    testWidgets('reads on demand, then says what it found and what to do', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      // The Overview's boxes, as it would hold them.
      monitoring.sampleFor(_server, SampleStream.fs);
      monitoring.sampleFor(_server, SampleStream.failedUnits);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: DoctorView(
              monitoring: monitoring,
              serverId: _server,
              now: () => _now,
            ),
          ),
        ),
      );
      sample(SampleStream.fs, FsResult(FsSnapshot([_mount('/', use: 93)])));
      sample(
        SampleStream.failedUnits,
        FailedUnitsResult([_unit('nginx.service')]),
      );
      engine.emit(
        ServerClock(_server, skew: const Duration(minutes: 3), at: _now),
      );
      await tester.pump();

      expect(find.text('Checking…'), findsOne);
      expect(find.text('Reading…'), findsNWidgets(3));
      final read = engine.sentOfType<ReadPackages>().single as ReadPackages;
      expect(read.fresh, isFalse, reason: "the engine's kept check");
      final tls =
          engine.sentOfType<CheckTlsEndpoints>().single as CheckTlsEndpoints;
      expect(tls.endpoints, [_web]);

      engine
        ..emit(
          PackagesReport(
            serverId: _server,
            requestId: read.requestId,
            check: PackageCheck(
              manager: PackageManager.apt,
              securityCount: 0,
              reboot: RebootState.required,
            ),
          ),
        )
        ..emit(
          TlsEndpointsChecked(tls.requestId, [
            _cert(_web, _now.add(const Duration(days: 60))),
          ]),
        );
      await tester.pump();

      expect(find.text('2 problems, 2 warnings'), findsOne);
      expect(find.text('Filling up, the fullest at 93%:'), findsOne);
      expect(find.text('/'), findsOne);
      expect(
        find.text(
          'Remove old logs, caches and unused images, or grow the '
          'filesystem. Disks on the System tab lists every mount.',
        ),
        findsOne,
      );
      expect(find.text('1 unit has failed:'), findsOne);
      expect(find.text('nginx.service'), findsOne);
      expect(find.text('No updates are pending.'), findsOne);
      expect(
        find.text(
          'A reboot is needed. Packages that asked for it, where the host '
          'says:',
        ),
        findsOne,
      );
      expect(
        find.text('The clock reads 3 minutes ahead of this device.'),
        findsOne,
      );
      expect(find.text('The endpoint presents a valid certificate.'), findsOne);
      expect(find.text('Docker disk use'), findsNothing, reason: 'no Docker');

      await tester.tap(find.text('Check again'));
      await tester.pump();
      expect(engine.sentOfType<ReadPackages>(), hasLength(2));
      expect(engine.sentOfType<CheckTlsEndpoints>(), hasLength(2));
      expect(find.text('Checking…'), findsOne);
    });
  });
}
