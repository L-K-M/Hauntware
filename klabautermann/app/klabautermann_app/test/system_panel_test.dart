import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:klabautermann_app/controllers/admin_controller.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/admin_mode_chip.dart' show AdminScope;
import 'package:klabautermann_app/ui/server_surfaces.dart';
import 'package:klabautermann_app/ui/system_panel.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/charts.dart'
    show goldenFontFamily, goldensCompareHere, loadGoldenFonts;
import 'support/fake_engine.dart';
import 'support/harness.dart';

const _serverId = 'srv-1';
const _kib = 1024;
const _mib = 1024 * _kib;
const _gib = 1024 * _mib;

const _wide = Size(718, 1000);
const _phone = Size(390, 1400);

/// When the readings are taken; local, so the words do not depend on the
/// test machine's zone.
final _now = DateTime(2026, 10, 15, 14, 30);
final _booted = DateTime(2026, 10, 3, 11, 23);

const _identity = IdentityResult(
  hostname: 'web-1',
  osPrettyName: 'Debian GNU/Linux 12 (bookworm)',
  kernelName: 'Linux',
  kernelRelease: '6.1.0-26-amd64',
  arch: 'x86_64',
);

CoreResult _core({
  Map<String, NetRate>? network = _network,
  Map<String, DiskRate>? disks = _disks,
}) => CoreResult(
  uptime: const Duration(days: 12, hours: 3, minutes: 7),
  bootedAt: _booted,
  network: network,
  disks: disks,
);

/// Two whole disks: one with collector set 10's timings, one as an older
/// reading without them.
const _disks = {
  'nvme0n1': DiskRate(
    readBytesPerSecond: 2.5 * _mib,
    writeBytesPerSecond: 3.0 * _mib,
    readsPerSecond: 812,
    writesPerSecond: 140.4,
    readAwaitMs: 0.42,
    writeAwaitMs: 1.85,
    busyPercent: 37.6,
  ),
  'sda': DiskRate(
    readBytesPerSecond: 0,
    writeBytesPerSecond: 512.0 * _kib,
    writesPerSecond: 9,
  ),
};

/// A CPU package with its limits and a drive without any.
const _temps = TempsSnapshot([
  TempSensor(
    id: 'hwmon2/temp1',
    chip: 'coretemp',
    label: 'Package id 0',
    celsius: 48,
    highCelsius: 84,
    criticalCelsius: 100,
  ),
  TempSensor(id: 'hwmon4/temp1', chip: 'drivetemp', celsius: 38.6),
]);

/// An NVIDIA GPU with every figure and an amdgpu card without a name or
/// a power reading.
const _gpus = GpuSnapshot([
  GpuDevice(
    id: 'nvidia0',
    source: GpuSource.nvidia,
    name: 'NVIDIA GeForce RTX 3080',
    busyPercent: 12,
    memoryUsedBytes: 1024 * _mib,
    memoryTotalBytes: 10240 * _mib,
    celsius: 45,
    powerWatts: 35.2,
    powerLimitWatts: 320,
  ),
  GpuDevice(
    id: 'card1',
    source: GpuSource.amdgpu,
    busyPercent: 37,
    memoryUsedBytes: 512 * _mib,
    memoryTotalBytes: 8192 * _mib,
    celsius: 52,
  ),
]);

const _network = {
  'eth0': NetRate(
    rxBytesPerSecond: 1.25 * _mib,
    txBytesPerSecond: 200.0 * _kib,
  ),
  'eth1': NetRate(
    rxBytesPerSecond: 0.25 * _mib,
    txBytesPerSecond: 100.0 * _kib,
  ),
};

/// A mount from `df`: sizes in GiB, then the use and inode shares.
FsMount _mount(
  String device,
  String type,
  String mountPoint,
  (num, num, num) gib, [
  int? use,
  int? inodes,
]) => FsMount(
  device: device,
  type: type,
  mountPoint: mountPoint,
  sizeBytes: (gib.$1 * _gib).round(),
  usedBytes: (gib.$2 * _gib).round(),
  availBytes: (gib.$3 * _gib).round(),
  capacityPercent: use,
  inodeUsePercent: inodes,
);

final _fs = FsSnapshot([
  _mount('/dev/sda1', 'ext4', '/', (50, 21, 26), 45, 12),
  _mount('tmpfs', 'tmpfs', '/run', (0.75, 0.002, 0.748), 1, 1),
  _mount('nas:/export/backup', 'nfs4', '/mnt/backup', (2048, 1700, 348), 84),
  _mount('/dev/sdb1', 'xfs', '/data', (500, 120, 380), 24, 3),
]);

final _vm = HostProfile(
  virtualization: 'kvm',
  container: 'none',
  lxcfsMounts: const [],
);

/// An LXC container without lxcfs: every system-wide `/proc` file is the
/// host's (D50).
final _container = HostProfile(
  virtualization: 'lxc',
  container: 'lxc',
  lxcfsMounts: const [],
);

final class _Panel {
  _Panel(this.engine, {this.serverId});

  final FakeEngineClient engine;

  /// The server a pumped panel shows; a new value switches it.
  final ValueNotifier<String>? serverId;
  int _seq = 0;

  Future<void> sample(
    WidgetTester tester,
    SampleStream stream,
    SampleResult result, {
    DateTime? at,
    String server = _serverId,
  }) async {
    engine.emit(
      Sample(
        serverId: server,
        stream: stream,
        seq: ++_seq,
        at: at ?? _now,
        result: result,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> profile(WidgetTester tester, HostProfile profile) async {
    engine.emit(HostProfileChanged(_serverId, profile));
    await tester.pumpAndSettle();
  }

  /// A healthy server: every stream read once.
  Future<void> all(WidgetTester tester, HostProfile profile) async {
    await this.profile(tester, profile);
    await sample(tester, SampleStream.identity, _identity);
    await sample(tester, SampleStream.core, _core());
    await sample(tester, SampleStream.fs, FsResult(_fs));
    await sample(tester, SampleStream.temps, const TempsResult(_temps));
    await sample(tester, SampleStream.gpu, const GpuResult(_gpus));
  }
}

ThemeData _theme(Brightness brightness, TargetPlatform platform) {
  final theme = brightness == Brightness.light
      ? GhostTheme.light(klabautermannThemeStyle, platform: platform)
      : GhostTheme.dark(klabautermannThemeStyle, platform: platform);
  return theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamily: goldenFontFamily),
  );
}

Future<_Panel> _pump(
  WidgetTester tester, {
  Size size = _wide,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  TargetPlatform platform = TargetPlatform.linux,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final engine = FakeEngineClient();
  final monitoring = MonitoringController(engine);
  final admin = AdminController(engine);
  addTearDown(() async {
    admin.dispose();
    monitoring.dispose();
    await engine.close();
  });

  final serverId = ValueNotifier(_serverId);
  addTearDown(serverId.dispose);

  final theme = _theme(brightness, platform);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: Scaffold(
          body: RepaintBoundary(
            child: ColoredBox(
              color: theme.colorScheme.surface,
              child: AdminScope(
                admin: admin,
                child: ValueListenableBuilder(
                  valueListenable: serverId,
                  builder: (context, serverId, _) =>
                      SystemPanel(monitoring: monitoring, serverId: serverId),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Panel(engine, serverId: serverId);
}

Finder _inSection(SystemSection section, Finder finder) =>
    find.descendant(of: find.byKey(ValueKey(section)), matching: finder);

Finder _row(String mountPoint) => find.byKey(ValueKey('disks.row.$mountPoint'));

/// Tabs past the sortable headers to the mounts table's body.
Future<void> _tabToTable(WidgetTester tester) async {
  for (var stop = 0; stop < 10; stop++) {
    if (FocusManager.instance.primaryFocus?.debugLabel == 'SortableTable') {
      return;
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
  }
}

/// The mount points the table shows, top to bottom.
List<String> _mountOrder(WidgetTester tester) {
  const prefix = 'disks.row.';
  return [
    for (final element in find.byType(Semantics).evaluate())
      if (element.widget.key case ValueKey<String>(
        :final value,
      ) when value.startsWith(prefix))
        value.substring(prefix.length),
  ];
}

/// 03 §10.2's System tab: SYS-01, SYS-04, BOOT-01, DSK-01, DSK-02 and
/// NET-01 from the identity, core and fs streams and the probe's profile.
void main() {
  setUpAll(() async {
    if (goldensCompareHere) await loadGoldenFonts();
  });

  testWidgets('the desktop System tab samples its streams and shows them', (
    tester,
  ) async {
    final harness = await pumpApp(
      tester,
      servers: twoServers,
      size: const Size(1280, 1000),
    );
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    final tab = find.descendant(
      of: find.byType(TabBar),
      matching: find.text('System'),
    );
    await tester.ensureVisible(tab);
    await tester.tap(tab);
    await tester.pumpAndSettle();

    final system = harness.engine
        .sentOfType<Subscribe>()
        .cast<Subscribe>()
        .last;
    expect(system.streams, ServerPanel.system.streams);
    expect(find.text('Waiting for the first reading.'), findsNWidgets(5));

    await _Panel(harness.engine).all(tester, _vm);
    expect(find.text('Waiting for the first reading.'), findsNothing);
    expect(find.text('Debian GNU/Linux 12 (bookworm)'), findsOneWidget);
    expect(find.text('Virtual machine (kvm)'), findsOneWidget);
    expect(find.text('21 GiB of 50 GiB'), findsOneWidget);
  });

  testWidgets('SYS-01 and BOOT-01 word identity, uptime and boot time', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final panel = await _pump(tester);
    await panel.all(tester, _vm);

    for (final text in [
      'web-1',
      'Debian GNU/Linux 12 (bookworm)',
      'Linux 6.1.0-26-amd64',
      'x86_64',
      'Virtual machine (kvm)',
      '12 days, 3 hours',
      DateFormat.yMMMd('en').add_jm().format(_booted),
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    // A label and its value are one node (A11Y-03's "column: value" in
    // fact form).
    expect(
      find.bySemanticsLabel(RegExp(r'^Up for\n12 days, 3 hours$')),
      findsOneWidget,
    );
    expect(find.textContaining('This server is a container'), findsNothing);
    handle.dispose();
  });

  testWidgets('NET-01 sums every interface in IEC units, and an unknown '
      'rate is never zero', (tester) async {
    final panel = await _pump(tester);
    await panel.sample(tester, SampleStream.core, _core());
    expect(
      _inSection(SystemSection.network, find.text('1.5 MiB/s')),
      findsOneWidget,
    );
    expect(
      _inSection(SystemSection.network, find.text('300 KiB/s')),
      findsOneWidget,
    );

    // The first reading after a reset has no rates to give.
    await panel.sample(tester, SampleStream.core, _core(network: null));
    expect(
      _inSection(SystemSection.network, find.text('Unknown')),
      findsNWidgets(2),
    );
    expect(
      _inSection(SystemSection.network, find.textContaining('0 B/s')),
      findsNothing,
    );
  });

  testWidgets('DSK-03 and DSK-04 show each disk\'s throughput, requests, '
      'wait and busy share; what a reading lacks reads unknown', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.sample(tester, SampleStream.core, _core());
    Finder activity(String text) =>
        _inSection(SystemSection.diskActivity, find.text(text));

    expect(activity('nvme0n1'), findsOneWidget);
    expect(activity('2.5 MiB/s'), findsOneWidget);
    expect(activity('3 MiB/s'), findsOneWidget);
    expect(activity('812'), findsOneWidget);
    expect(activity('140'), findsOneWidget);
    expect(activity('0.4 ms'), findsOneWidget);
    expect(activity('1.9 ms'), findsOneWidget);
    expect(activity('38%'), findsOneWidget);
    // sda's reading has no timings: its waits and busy share are unknown,
    // never zero.
    expect(activity('512 KiB/s'), findsOneWidget);
    expect(activity('Unknown'), findsNWidgets(3));

    // The first reading after a reset has no rates yet.
    await panel.sample(tester, SampleStream.core, _core(disks: null));
    expect(activity('Rates show from the second reading.'), findsOneWidget);
    await panel.sample(tester, SampleStream.core, _core(disks: const {}));
    expect(activity('No disk has done any I/O yet.'), findsOneWidget);
  });

  testWidgets('HW-01 lists each sensor with its reading and limits; a '
      'host without sensors, or a container, shows no section', (tester) async {
    final panel = await _pump(tester);
    Finder temps(String text) =>
        _inSection(SystemSection.temperatures, find.text(text));

    // No reading yet: no section rather than a wait for one that VMs
    // never send.
    expect(find.text('Temperatures'), findsNothing);

    await panel.sample(tester, SampleStream.temps, const TempsResult(_temps));
    expect(find.text('Temperatures'), findsOneWidget);
    expect(temps('coretemp: Package id 0'), findsOneWidget);
    expect(temps('48 °C'), findsOneWidget);
    expect(temps('84 °C'), findsOneWidget);
    expect(temps('100 °C'), findsOneWidget);
    expect(temps('drivetemp'), findsOneWidget);
    expect(temps('39 °C'), findsOneWidget);
    expect(temps('Unknown'), findsNWidgets(2));

    await panel.sample(
      tester,
      SampleStream.temps,
      const TempsResult(TempsSnapshot([])),
    );
    expect(find.text('Temperatures'), findsNothing);

    await panel.sample(tester, SampleStream.temps, const TempsResult(_temps));
    await panel.profile(tester, _container);
    expect(find.text('Temperatures'), findsNothing);
  });

  testWidgets('HW-03 lists each GPU with its busy share, memory, '
      'temperature and power; a failed nvidia-smi says so; no GPU, no '
      'section', (tester) async {
    final panel = await _pump(tester);
    Finder gpus(String text) => _inSection(SystemSection.gpus, find.text(text));
    expect(find.text('GPUs'), findsNothing);

    await panel.sample(tester, SampleStream.gpu, const GpuResult(_gpus));
    expect(find.text('GPUs'), findsOneWidget);
    expect(gpus('NVIDIA GeForce RTX 3080'), findsOneWidget);
    expect(gpus('12%'), findsOneWidget);
    expect(gpus('1 GiB of 10 GiB'), findsOneWidget);
    expect(gpus('45 °C'), findsOneWidget);
    expect(gpus('35 W'), findsOneWidget);
    expect(gpus('card1'), findsOneWidget);
    expect(gpus('512 MiB of 8 GiB'), findsOneWidget);
    expect(gpus('Unknown'), findsOneWidget);

    await panel.sample(
      tester,
      SampleStream.gpu,
      const GpuResult(
        GpuSnapshot(
          [],
          nvidiaFailure:
              'NVIDIA-SMI has failed because it couldn\'t communicate with '
              'the NVIDIA driver.',
        ),
      ),
    );
    expect(
      gpus(
        'nvidia-smi is installed but failed: NVIDIA-SMI has failed because '
        'it couldn\'t communicate with the NVIDIA driver.',
      ),
      findsOneWidget,
    );

    await panel.sample(
      tester,
      SampleStream.gpu,
      const GpuResult(GpuSnapshot([])),
    );
    expect(find.text('GPUs'), findsNothing);
  });

  testWidgets('HW-04 reads drive health on request in admin mode, with '
      'each drive\'s verdict and figures, or why nothing was read', (
    tester,
  ) async {
    // Wide enough for every column of the drive table.
    final panel = await _pump(tester, size: const Size(1100, 1200));
    Finder drives(String text) =>
        _inSection(SystemSection.driveHealth, find.text(text));
    expect(
      drives(
        'Turn on admin mode to read drive health: smartctl needs the '
        'drives\' device nodes.',
      ),
      findsOneWidget,
    );
    expect(drives('Read drive health'), findsNothing);

    panel.engine.emit(const AdminModeState(_serverId, AdminModePhase.on));
    await tester.pumpAndSettle();
    await tester.ensureVisible(drives('Read drive health'));
    await tester.tap(drives('Read drive health'));
    await tester.pumpAndSettle();
    expect(drives('Reading drive health…'), findsOneWidget);
    final read = panel.engine.sentOfType<ReadSmart>().cast<ReadSmart>().single;
    expect(read.serverId, _serverId);

    panel.engine.emit(
      SmartReport(
        serverId: _serverId,
        requestId: read.requestId,
        disks: const [
          SmartDisk(
            device: '/dev/nvme0',
            verdict: SmartVerdict.passed,
            model: 'WD Blue SN570 1TB',
            celsius: 38,
            percentageUsed: 3,
            powerOnHours: 1000,
          ),
          SmartDisk(
            device: '/dev/sda',
            verdict: SmartVerdict.warning,
            model: 'Samsung SSD 860 EVO 500GB',
            badSectors: 8,
            powerOnHours: 12345,
          ),
          SmartDisk(device: '/dev/sdb', verdict: SmartVerdict.asleep),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(drives('WD Blue SN570 1TB'), findsOneWidget);
    expect(drives('Passed'), findsOneWidget);
    expect(drives('38 °C'), findsOneWidget);
    expect(drives('3%'), findsOneWidget);
    expect(drives('1,000 h'), findsOneWidget);
    expect(drives('Warning'), findsOneWidget);
    expect(drives('8'), findsOneWidget);
    expect(drives('12,345 h'), findsOneWidget);
    expect(drives('/dev/sdb'), findsNWidgets(2));
    expect(drives('Asleep'), findsOneWidget);
    expect(drives('Read again'), findsOneWidget);

    await tester.tap(drives('Read again'));
    await tester.pumpAndSettle();
    final again = panel.engine.sentOfType<ReadSmart>().cast<ReadSmart>().last;
    panel.engine.emit(
      SmartReport(
        serverId: _serverId,
        requestId: again.requestId,
        failure: SmartReportFailure.missing,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      drives('smartmontools is not installed on this server.'),
      findsOneWidget,
    );
  });

  testWidgets('where every column does not fit, the disk activity table '
      'keeps throughput and busy share and drops the counts and waits', (
    tester,
  ) async {
    final panel = await _pump(tester, size: _phone);
    await panel.sample(tester, SampleStream.core, _core());
    Finder activity(String text) =>
        _inSection(SystemSection.diskActivity, find.text(text));

    expect(activity('2.5 MiB/s'), findsOneWidget);
    expect(activity('38%'), findsOneWidget);
    expect(activity('812'), findsNothing);
    expect(activity('0.4 ms'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SYS-04: inside a container without lxcfs the host\'s uptime '
      'and boot time read as unknown with the reason', (tester) async {
    final handle = tester.ensureSemantics();
    final panel = await _pump(tester);
    await panel.all(tester, _container);

    expect(find.text('Container (lxc)'), findsOneWidget);
    expect(
      find.text(
        'This server is a container. Figures that would come from its host '
        'read as unknown.',
      ),
      findsOneWidget,
    );
    const reason =
        'Inside this container this figure would be the host\'s, so it is '
        'not shown.';
    expect(
      _inSection(SystemSection.uptime, find.text(reason)),
      findsNWidgets(2),
    );
    expect(find.text('12 days, 3 hours'), findsNothing);
    expect(
      find.bySemanticsLabel(RegExp('^Up for\nUnknown\n$reason\$')),
      findsOneWidget,
    );
    // The container's own namespaces stay as measured (D50).
    expect(find.text('1.5 MiB/s'), findsOneWidget);
    expect(find.text('21 GiB of 50 GiB'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('SYS-04: lxcfs serves the container\'s own uptime but not its '
      'boot time', (tester) async {
    final handle = tester.ensureSemantics();
    final panel = await _pump(tester);
    await panel.all(
      tester,
      HostProfile(
        virtualization: 'lxc',
        container: 'lxc',
        lxcfsMounts: const ['/proc/uptime', '/proc/meminfo', '/proc/stat'],
      ),
    );

    expect(find.text('12 days, 3 hours'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'^Booted\nUnknown\nInside this container')),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('DSK-01 and DSK-02 list usage and inodes per mount, pseudo '
      'filesystems on request, and a missing timeout guard', (tester) async {
    final handle = tester.ensureSemantics();
    final panel = await _pump(tester);
    await panel.sample(tester, SampleStream.fs, FsResult(_fs));

    expect(_mountOrder(tester), ['/', '/mnt/backup', '/data']);
    expect(
      tester.getSemantics(_row('/mnt/backup')),
      isSemantics(
        label:
            'Mount: /mnt/backup\nType: nfs4\nUsed: 1.7 TiB of 2 TiB\n'
            'Use: 84%\nInodes: Unknown',
      ),
    );

    await tester.tap(find.text('Show pseudo filesystems (1)'));
    await tester.pumpAndSettle();
    expect(_mountOrder(tester), ['/', '/run', '/mnt/backup', '/data']);

    // Use sorts its largest first.
    await tester.tap(find.byKey(const ValueKey('disks.column.use')));
    await tester.pumpAndSettle();
    expect(_mountOrder(tester), ['/mnt/backup', '/', '/data', '/run']);

    const noTimeout =
        'This server has no timeout command, so a network mount that stops '
        'answering can stall disk readings.';
    expect(find.text(noTimeout), findsNothing);
    final unguarded = FsSnapshot(_fs.mounts, timeoutAbsent: true);
    await panel.sample(tester, SampleStream.fs, FsResult(unguarded));
    expect(find.text(noTimeout), findsOneWidget);
    handle.dispose();
  });

  // At 200 % in the narrowest desktop window, a 398 px panel, the table
  // also scrolls sideways.
  for (final (textScale, count, width) in [
    (1.0, 40, 718.0),
    (2.0, 16, 398.0),
  ]) {
    testWidgets('the keyboard\'s active mount row stays on screen while the '
        'page scrolls the table, at ${textScale}x text', (tester) async {
      final handle = tester.ensureSemantics();
      final panel = await _pump(
        tester,
        size: Size(width, 600),
        textScale: textScale,
      );
      final many = FsSnapshot([
        for (var index = 0; index < count; index++)
          _mount('/dev/vd$index', 'ext4', '/m$index', (10, 1, 9), 10, 1),
      ]);
      await panel.sample(tester, SampleStream.fs, FsResult(many));

      await _tabToTable(tester);
      final view = tester.getRect(find.byType(SystemPanel));
      int active() => [
        for (var index = 0; index < count; index++)
          if (isSemantics(
            isFocused: true,
          ).matches(tester.getSemantics(_row('/m$index')), {}))
            index,
      ].single;
      void expectShown() {
        final row = tester.getRect(_row('/m${active()}'));
        expect(
          row.top >= view.top && row.bottom <= view.bottom,
          isTrue,
          reason: '/m${active()} at $row in $view',
        );
      }

      expectShown();
      for (final (key, expected) in [
        (LogicalKeyboardKey.end, count - 1),
        (LogicalKeyboardKey.home, 0),
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
        expect(active(), expected);
        expectShown();
      }

      // A page is what the screen shows, not the whole table.
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(active(), inExclusiveRange(1, count - 1));
      expectShown();
      handle.dispose();
    });
  }

  testWidgets('at 200 % text a 1280 px window\'s mounts table keeps the '
      'keyboard\'s mount point on screen', (tester) async {
    final panel = await _pump(tester, size: const Size(718, 600), textScale: 2);
    await panel.sample(tester, SampleStream.fs, FsResult(_fs));

    await _tabToTable(tester);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'SortableTable');
    final view = tester.getRect(find.byType(SystemPanel));
    final mount = tester.getRect(
      find.descendant(of: _row('/'), matching: find.text('/')),
    );
    expect(
      mount.left >= view.left && mount.right <= view.right,
      isTrue,
      reason: '/ at $mount in $view',
    );
  });

  testWidgets('focus handed back to the table leaves the page where it '
      'was read', (tester) async {
    final panel = await _pump(tester, size: const Size(718, 600));
    await panel.sample(
      tester,
      SampleStream.fs,
      FsResult(
        FsSnapshot([
          for (var index = 0; index < 40; index++)
            _mount('/dev/vd$index', 'ext4', '/m$index', (10, 1, 9), 10, 1),
        ]),
      ),
    );
    await tester.ensureVisible(_row('/m20'));
    await tester.tap(_row('/m20'));
    await tester.pumpAndSettle();
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'SortableTable');

    // The reader wheels up to Identity; the table keeps focus.
    final page = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(SystemPanel),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    page.jumpTo(0);
    await tester.pumpAndSettle();

    // Flutter parks focus over an inactive window on desktop only.
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pumpAndSettle();
    }
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'SortableTable');
    expect(page.pixels, 0, reason: 'another window and back');

    unawaited(
      showDialog<void>(
        context: tester.element(find.byType(SystemPanel)),
        builder: (context) => const Dialog(child: SizedBox.square()),
      ),
    );
    await tester.pumpAndSettle();
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'SortableTable');
    expect(page.pixels, 0, reason: 'a dialog opened and closed');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('a narrow table opens a mount\'s bytes and device in a sheet', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final panel = await _pump(
      tester,
      size: _phone,
      platform: TargetPlatform.android,
    );
    await panel.sample(tester, SampleStream.fs, FsResult(_fs));
    expect(
      tester.getSemantics(_row('/mnt/backup')),
      isSemantics(
        label: 'Mount: /mnt/backup\nUse: 84%\nInodes: Unknown',
        isButton: true,
      ),
    );

    await tester.tap(_row('/mnt/backup'));
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    for (final text in ['nas:/export/backup', 'nfs4', '1.7 TiB of 2 TiB']) {
      expect(
        find.descendant(of: sheet, matching: find.text(text)),
        findsOneWidget,
      );
    }
    handle.dispose();
  });

  testWidgets('a df that timed out keeps the last listed mounts, their '
      'usage unknown', (tester) async {
    final handle = tester.ensureSemantics();
    final panel = await _pump(tester);
    await panel.sample(
      tester,
      SampleStream.fs,
      const CollectorUnavailable(CollectorUnavailableReason.timeout),
    );
    const timedOut =
        'Disk usage did not finish in time. A network mount (NFS or SMB) '
        'that stopped answering is the usual cause.';
    expect(find.text(timedOut), findsOneWidget);
    expect(_mountOrder(tester), isEmpty, reason: 'no earlier reading');

    final listedAt = DateTime(2026, 10, 15, 14, 29);
    await panel.sample(tester, SampleStream.fs, FsResult(_fs), at: listedAt);
    await panel.sample(
      tester,
      SampleStream.fs,
      const CollectorUnavailable(CollectorUnavailableReason.timeout),
    );
    expect(find.text(timedOut), findsOneWidget);
    expect(
      find.text(
        'These mounts are from the reading at '
        '${DateFormat.yMMMd('en').add_jm().format(listedAt)}; their usage is unknown now.',
      ),
      findsOneWidget,
    );
    expect(_mountOrder(tester), ['/', '/mnt/backup', '/data']);
    expect(
      tester.getSemantics(_row('/')),
      // Which mount hung is not known, so none is said to have timed out.
      isSemantics(label: 'Mount: /\nType: ext4\nUsage: Unknown'),
    );
    expect(find.text('21 GiB of 50 GiB'), findsNothing);

    // The sheet gives the reason too, not a bare unknown.
    await tester.tap(_row('/'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('This reading did not finish in time.'),
      ),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('a server switch shows the new server\'s readings only', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.sample(tester, SampleStream.identity, _identity);
    await panel.sample(tester, SampleStream.fs, FsResult(_fs));
    expect(find.text('Debian GNU/Linux 12 (bookworm)'), findsOneWidget);

    panel.serverId!.value = 'srv-2';
    await tester.pumpAndSettle();
    expect(find.text('Debian GNU/Linux 12 (bookworm)'), findsNothing);
    expect(find.text('Waiting for the first reading.'), findsNWidgets(5));

    // A timeout there lists none of the first server's mounts.
    await panel.sample(
      tester,
      SampleStream.fs,
      const CollectorUnavailable(CollectorUnavailableReason.timeout),
      server: 'srv-2',
    );
    expect(find.textContaining('Disk usage did not finish'), findsOneWidget);
    expect(_mountOrder(tester), isEmpty);

    await panel.sample(
      tester,
      SampleStream.identity,
      const IdentityResult(osPrettyName: 'Alpine Linux v3.20'),
      server: 'srv-2',
    );
    expect(find.text('Alpine Linux v3.20'), findsOneWidget);
  });

  testWidgets('a tab opened on a df timeout lists the mounts read before '
      'it', (tester) async {
    final panel = await _pump(tester);
    panel.serverId!.value = 'srv-2';
    await tester.pumpAndSettle();
    // Read while the tab showed another server, as while only Overview
    // samples the stream.
    await panel.sample(tester, SampleStream.fs, FsResult(_fs));
    await panel.sample(
      tester,
      SampleStream.fs,
      const CollectorUnavailable(CollectorUnavailableReason.timeout),
    );

    panel.serverId!.value = _serverId;
    await tester.pumpAndSettle();
    expect(find.textContaining('Disk usage did not finish'), findsOneWidget);
    expect(_mountOrder(tester), ['/', '/mnt/backup', '/data']);
  });

  testWidgets('a collector without a value says why, with the host\'s '
      'output', (tester) async {
    final panel = await _pump(tester);
    await panel.sample(
      tester,
      SampleStream.identity,
      const CollectorUnavailable(
        CollectorUnavailableReason.denied,
        detail: 'hostnamectl: Permission denied',
      ),
    );
    expect(
      _inSection(
        SystemSection.identity,
        find.text('The server refused this reading.'),
      ),
      findsOneWidget,
    );
    expect(find.text('hostnamectl: Permission denied'), findsOneWidget);
  });

  for (final (name, size, platform) in [
    ('desktop', _wide, TargetPlatform.linux),
    ('phone', _phone, TargetPlatform.android),
  ]) {
    testWidgets('lays out without overflow at 200 % text on the $name, '
        'and a row opens its mount point in full', (tester) async {
      final panel = await _pump(
        tester,
        size: size,
        platform: platform,
        textScale: 2,
      );

      /// The mount column may cut a mount point short; its details do not.
      Future<void> expectDetails(
        List<String> texts, {
        List<String> absent = const [],
      }) async {
        await tester.ensureVisible(_row('/mnt/backup'));
        await tester.tap(_row('/mnt/backup'));
        await tester.pumpAndSettle();
        final sheet = find.byType(BottomSheet);
        for (final text in ['/mnt/backup', 'nas:/export/backup', ...texts]) {
          expect(
            find.descendant(of: sheet, matching: find.text(text)),
            findsOneWidget,
            reason: text,
          );
        }
        for (final text in absent) {
          expect(
            find.descendant(of: sheet, matching: find.text(text)),
            findsNothing,
            reason: text,
          );
        }
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pumpAndSettle();
      }

      await panel.all(tester, _container);
      expect(tester.takeException(), isNull);
      await expectDetails(['1.7 TiB of 2 TiB']);

      await panel.sample(
        tester,
        SampleStream.fs,
        const CollectorUnavailable(CollectorUnavailableReason.timeout),
      );
      expect(tester.takeException(), isNull);
      // The kept mount's figures are not current.
      await expectDetails(['Unknown'], absent: ['1.7 TiB of 2 TiB', '84%']);
      expect(find.text('1.7 TiB of 2 TiB'), findsNothing);
    });
  }

  group('golden', () {
    // 03 §11.1: the desktop scene is a virtual machine in full health; the
    // phone scene an LXC container without lxcfs, whose host figures read
    // as unknown, and the narrow mounts table.
    for (final brightness in Brightness.values) {
      testWidgets('desktop, ${brightness.name}', (tester) async {
        final panel = await _pump(tester, brightness: brightness);
        await panel.all(tester, _vm);
        await expectLater(
          find.byType(SystemPanel),
          matchesGoldenFile(
            'goldens/system_panel_desktop_${brightness.name}.png',
          ),
        );
      }, skip: !goldensCompareHere);

      testWidgets('phone, ${brightness.name}', (tester) async {
        final panel = await _pump(
          tester,
          size: _phone,
          brightness: brightness,
          platform: TargetPlatform.android,
        );
        await panel.all(tester, _container);
        await expectLater(
          find.byType(SystemPanel),
          matchesGoldenFile(
            'goldens/system_panel_phone_${brightness.name}.png',
          ),
        );
      }, skip: !goldensCompareHere);
    }
  });
}
