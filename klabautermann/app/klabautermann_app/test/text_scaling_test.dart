// A11Y-09: at the operating system's 200% text scale, every server panel
// and Settings tab lays out without overflowing, on a phone and on the
// desktop, with readings in place.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/server_surfaces.dart' show ServerPanel;
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/harness.dart';
import 'support/sync_sign_in.dart';

const _serverId = 'srv-1';
final _at = DateTime.utc(2026, 10, 27, 12);

/// The readings the Overview and System panels show values from.
void _emitReadings(AppHarness harness) {
  var seq = 0;
  void sample(SampleStream stream, SampleResult result) => harness.engine.emit(
    Sample(
      serverId: _serverId,
      stream: stream,
      seq: ++seq,
      at: _at,
      result: result,
    ),
  );
  harness.engine.emit(const LinkState(_serverId, LinkReady()));
  sample(
    SampleStream.core,
    CoreResult(
      cpu: CpuPercentages(const [], 12.5),
      memory: const MemoryUsage(usedBytes: 3 << 30, totalBytes: 16 << 30),
      load: const LoadAvg(load1: 10.25, load5: 8.5, load15: 4.125),
      uptime: const Duration(days: 412, hours: 23),
    ),
  );
  sample(
    SampleStream.identity,
    const IdentityResult(
      hostname: 'a-rather-long-host-name.internal.example.org',
      osPrettyName: 'Debian GNU/Linux 13 (trixie)',
    ),
  );
  sample(
    SampleStream.fs,
    FsResult(
      FsSnapshot([
        const FsMount(
          device: '/dev/mapper/vg0-a-very-long-logical-volume-name',
          type: 'ext4',
          mountPoint: '/srv/data/with/a/deep/mount/point',
          sizeBytes: 1 << 40,
          usedBytes: 900 << 30,
          availBytes: 124 << 30,
          capacityPercent: 88,
          inodeUsePercent: 41,
        ),
      ]),
    ),
  );
}

void main() {
  Future<void> settle(WidgetTester tester) async {
    // Spinners never settle, so step the clock instead of pumpAndSettle.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets('every desktop panel lays out at 200% text', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final harness = await pumpApp(
      tester,
      size: const Size(1280, 800),
      servers: twoServers,
    );
    await tester.tap(find.text('web-1'));
    await settle(tester);
    _emitReadings(harness);
    await settle(tester);
    expect(find.textContaining('trixie'), findsWidgets, reason: 'read');

    final tabs = DefaultTabController.of(tester.element(find.byType(TabBar)));
    for (final panel in ServerPanel.values) {
      tabs.index = panel.index;
      await settle(tester);
      expect(tester.takeException(), isNull, reason: panel.name);
    }
  });

  testWidgets('every phone panel and More lays out at 200% text', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final harness = await pumpApp(
      tester,
      size: const Size(390, 844),
      servers: twoServers,
    );
    await tester.tap(find.text('web-1'));
    await settle(tester);
    _emitReadings(harness);
    await settle(tester);

    final bar = find.byType(NavigationBar);
    final destinations = tester.widget<NavigationBar>(bar).destinations.length;
    for (var index = 0; index < destinations; index++) {
      tester.widget<NavigationBar>(bar).onDestinationSelected!(index);
      await settle(tester);
      expect(tester.takeException(), isNull, reason: 'destination $index');
    }
  });

  testWidgets('every phone Settings tab lays out at 200% text', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpApp(tester, size: const Size(390, 844), servers: twoServers);
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);

    final tabs =
        tester.widget<TabBar>(find.byType(TabBar)).controller ??
        DefaultTabController.of(tester.element(find.byType(TabBar)));
    for (var index = 0; index < tabs.length; index++) {
      tabs.index = index;
      await settle(tester);
      expect(tester.takeException(), isNull, reason: 'tab $index');
    }
  });

  testWidgets('the server editor lays out at 200% text on a phone', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    // The editor opens while an account is enrolled (P16).
    await pumpApp(
      tester,
      size: const Size(390, 844),
      servers: twoServers,
      syncAccount: testSyncAccount,
    );
    await tester.tap(find.byTooltip('Add server'));
    await settle(tester);
    expect(find.byType(Dialog), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Every field, scrolled through, as the editor's rows lay out.
    final scrollable = find
        .descendant(
          of: find.descendant(
            of: find.byType(Dialog),
            matching: find.byType(SingleChildScrollView),
          ),
          matching: find.byType(Scrollable),
        )
        .first;
    for (var i = 0; i < 12; i++) {
      await tester.drag(scrollable, const Offset(0, -300));
      await settle(tester);
      expect(tester.takeException(), isNull, reason: 'scroll $i');
    }
  });
}
