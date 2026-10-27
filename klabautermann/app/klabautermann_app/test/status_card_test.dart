// PLT-08: a server's status card from its last readings, exported through
// LOG-10's sheet with the server left unnamed unless the user names it.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/logs/log_export.dart';
import 'package:klabautermann_app/ui/status_card.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/docker.dart';
import 'support/fake_engine.dart';

const _serverId = 'srv-1';
final _now = DateTime.utc(2026, 10, 27, 12);

final class _ExportHost implements LogExportHost {
  final saved = <(String, String)>[];

  @override
  bool get canShare => false;

  @override
  Future<bool> save(String fileName, Uint8List bytes) async {
    saved.add((fileName, utf8.decode(bytes)));
    return true;
  }

  @override
  Future<void> share(String fileName, Uint8List bytes, {Rect? origin}) async {}
}

FsMount _mount(String mountPoint, int use) => FsMount(
  device: '/dev/sda1',
  type: 'ext4',
  mountPoint: mountPoint,
  sizeBytes: 100,
  usedBytes: use,
  availBytes: 100 - use,
  capacityPercent: use,
  inodeUsePercent: 1,
);

SystemdUnit _unit(String name) =>
    SystemdUnit(unit: name, load: 'loaded', active: 'failed', sub: 'failed');

final _core = CoreResult(
  cpu: CpuPercentages(const [], 12.5),
  memory: const MemoryUsage(usedBytes: 1 << 30, totalBytes: 4 << 30),
  load: const LoadAvg(load1: 0.5, load5: 0.25, load15: 0.125),
  uptime: const Duration(days: 3, hours: 4),
);

const _identity = IdentityResult(
  hostname: 'web-1.internal',
  osPrettyName: 'Debian GNU/Linux 13 (trixie)',
);

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  // The heading's date format needs the locale's data, which the app's
  // delegates load.
  setUpAll(() => GlobalMaterialLocalizations.delegate.load(const Locale('en')));

  test('the card says what was read, the fullest mounts first, and names '
      'the server only when asked', () {
    final card = StatusCard(
      readAt: _now,
      serverName: 'web-1',
      core: _core,
      fs: FsSnapshot([_mount('/', 40), _mount('/var', 91)]),
      failedUnits: [_unit('nginx.service')],
      identity: _identity,
      docker: dockerSummary([
        dockerContainer('a'),
        dockerContainer('b', health: HealthStatus.unhealthy),
        dockerContainer('c', state: 'exited'),
      ], const []),
    );

    final unnamed = card.lines(l10n, named: false);
    expect(unnamed.first, startsWith('Server status at '));
    expect(unnamed.skip(1), [
      'System: Debian GNU/Linux 13 (trixie)',
      'Up for 3 days, 4 hours',
      'CPU: 13% busy',
      'Load: 0.50, 0.25, 0.13',
      'Memory: 1 GiB of 4 GiB used (25%)',
      'Disk /var: 91% used',
      'Disk /: 40% used',
      '1 failed unit',
      'Containers: 2 of 3 running',
      '1 container unhealthy',
    ]);
    expect(unnamed.join('\n'), isNot(contains('web-1')));

    final named = card.lines(l10n, named: true);
    expect(named.sublist(1, 3), ['Server: web-1', 'Host name: web-1.internal']);
    expect(named.skip(3), unnamed.skip(1));
  });

  test('a card before any reading says so, and one withheld figure is '
      'left out', () {
    expect(const StatusCard(readAt: null).lines(l10n, named: true), [
      'Nothing has been read from the server yet.',
    ]);
    final lines = StatusCard(
      readAt: _now,
      core: _core,
      uptimeWithheld: true,
    ).lines(l10n, named: false);
    expect(lines.where((line) => line.startsWith('Up for')), isEmpty);
  });

  testWidgets('the button exports the last readings, redacted, and names '
      'the server once the switch is on', (tester) async {
    final engine = FakeEngineClient();
    final monitoring = MonitoringController(engine);
    final host = _ExportHost();
    addTearDown(() async {
      monitoring.dispose();
      await engine.close();
    });
    engine
      ..emit(
        Sample(
          serverId: _serverId,
          stream: SampleStream.core,
          seq: 1,
          at: _now,
          result: _core,
        ),
      )
      ..emit(
        Sample(
          serverId: _serverId,
          stream: SampleStream.identity,
          seq: 2,
          at: _now,
          result: _identity,
        ),
      );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LogExportScope(
          host: host,
          child: Scaffold(
            body: StatusCardButton(
              monitoring: monitoring,
              serverId: _serverId,
              serverName: 'web-1',
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Share status…'));
    await tester.pumpAndSettle();
    expect(find.text('Status card'), findsOneWidget);
    expect(
      find.text("The card leaves out the server's name and host name."),
      findsOneWidget,
    );

    await tester.tap(find.text('Save…'));
    await tester.pump();
    final unnamed = engine.sentOfType<RedactLines>().single as RedactLines;
    expect(unnamed.lines, contains('CPU: 13% busy'));
    expect(unnamed.lines.join('\n'), isNot(contains('web-1')));
    engine.emit(RedactedLines(unnamed.requestId, 'redacted'));
    await tester.pumpAndSettle();
    expect(host.saved, [('status.txt', 'redacted\n')]);

    await tester.tap(find.text('Share status…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name the server'));
    await tester.pump();
    expect(
      find.text('The card names the server and its host name.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Save…'));
    await tester.pump();
    final named = engine.sentOfType<RedactLines>().last as RedactLines;
    expect(
      named.lines,
      containsAll(['Server: web-1', 'Host name: web-1.internal']),
    );
  });
}
