// DSK-05 and DSK-14: a mount's details add its source and options, read
// when they open, and the Swap section lists the swap devices, used first
// at the top, and reads again on request.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/mounts.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _server = 'srv-1';

MountsRead _read({List<SwapDevice> swaps = const []}) => MountsRead(
  mounts: [
    MountEntry(
      target: '/',
      source: '/dev/sda1',
      type: 'ext4',
      options: const ['rw', 'relatime'],
    ),
    MountEntry(
      target: '/srv',
      source: '/dev/sdb1',
      type: 'xfs',
      options: const ['ro', 'noatime'],
    ),
  ],
  swaps: swaps,
);

void main() {
  late FakeEngineClient engine;
  late MonitoringController monitoring;

  setUp(() {
    engine = FakeEngineClient();
    monitoring = MonitoringController(engine);
  });

  tearDown(() async {
    monitoring.dispose();
    await engine.close();
  });

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );

  List<HostQuery> queries() =>
      engine.sentOfType<HostQuery>().cast<HostQuery>().toList();

  Future<void> answer(WidgetTester tester, HostPayload payload) async {
    engine.emit(
      HostResult(
        serverId: _server,
        queryId: queries().last.queryId,
        payload: payload,
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Widget options(String mountPoint) => MountOptions(
    monitoring: monitoring,
    serverId: _server,
    mountPoint: mountPoint,
    fact: (label, value) => Text('$label: $value'),
  );

  testWidgets('a mount shows its source and options, and a read-only one '
      'says so', (tester) async {
    await pump(tester, options('/srv'));
    expect(find.text('Reading mount options…'), findsOneWidget);
    expect(queries().single.query, isA<MountsQuery>());

    await answer(tester, Mounts(_read()));
    expect(find.text('Mounted read-only'), findsOneWidget);
    expect(find.text('Source: /dev/sdb1'), findsOneWidget);
    expect(find.text('Options: ro, noatime'), findsOneWidget);
  });

  testWidgets('a mount the read no longer lists, and a failed read, say '
      'so', (tester) async {
    await pump(tester, options('/mnt/gone'));
    await answer(tester, Mounts(_read()));
    expect(find.text('Nothing is mounted here any more.'), findsOneWidget);

    await pump(tester, Column(key: UniqueKey(), children: [options('/')]));
    await answer(tester, const HostQueryFailed(HostQueryFailure.noLink));
    expect(
      find.text(
        'Mount options could not be read. Not connected to the server.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('the Swap section lists devices used first at the top, and '
      'reads again on request', (tester) async {
    await pump(tester, SwapSection(monitoring: monitoring, serverId: _server));
    expect(find.text('Reading swap devices…'), findsOneWidget);

    await answer(
      tester,
      Mounts(
        _read(
          swaps: const [
            SwapDevice(
              path: '/dev/sda3',
              kind: SwapKind.partition,
              sizeBytes: 4 * 1024 * 1024 * 1024,
              usedBytes: 512 * 1024 * 1024,
              priority: -2,
            ),
            SwapDevice(
              path: '/swapfile',
              kind: SwapKind.file,
              sizeBytes: 1024 * 1024 * 1024,
              usedBytes: 0,
              priority: 10,
            ),
          ],
        ),
      ),
    );
    expect(find.text('512 MiB used of 4 GiB'), findsOneWidget);
    expect(find.text('Partition, priority -2'), findsOneWidget);
    expect(find.text('File, priority 10'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('/swapfile')).dy,
      lessThan(tester.getTopLeft(find.text('/dev/sda3')).dy),
    );

    await tester.tap(find.text('Read again'));
    await tester.pump();
    expect(queries(), hasLength(2));
    await answer(tester, Mounts(_read()));
    expect(find.text('No swap devices are in use.'), findsOneWidget);
  });
}
