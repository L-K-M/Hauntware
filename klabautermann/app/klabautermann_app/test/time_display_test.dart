// A11Y-07: server times in this device's zone or in the server's, kept per
// device and set in Settings > General.
import 'dart:async' show Completer;
import 'dart:io' show FileSystemException;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/controllers/time_display.dart';
import 'package:klabautermann_app/controllers/tls_endpoints.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/certificates.dart';
import 'package:klabautermann_app/ui/charts/charts.dart';
import 'package:klabautermann_app/ui/charts/time_series_chart.dart';
import 'package:klabautermann_app/ui/time_display.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/charts.dart';
import 'support/fake_engine.dart';

const _server = 'srv-1';
const _unread = 'srv-2';

/// Far from UTC, so a server time and this machine's differ in any `TZ`
/// a runner is likely to have.
const _serverOffset = Duration(hours: 12, minutes: 45);

final _at = DateTime.utc(2026, 10, 27, 20, 30);

void main() {
  test('a change applies before it is saved, says when it was not saved, '
      'and picking it again retries the save', () async {
    final saved = <bool>[];
    var failing = true;
    final display = TimeDisplayController(
      save: (serverTimes) async {
        if (failing) throw const FileSystemException('disk full');
        saved.add(serverTimes);
      },
    );
    addTearDown(display.dispose);

    await expectLater(
      display.setTimeDisplay(TimeDisplay.server),
      throwsA(isA<TimeDisplayNotSavedException>()),
    );
    expect(display.value, TimeDisplay.server, reason: 'it still applies');

    failing = false;
    await display.setTimeDisplay(TimeDisplay.server);
    expect(saved, [true]);
    await display.setTimeDisplay(TimeDisplay.server);
    expect(saved, hasLength(1), reason: 'in force and saved');
  });

  test('overlapping changes save in order, so the last one stays', () async {
    final saved = <bool>[];
    final first = Completer<void>();
    final display = TimeDisplayController(
      save: (serverTimes) async {
        // The first save is slow, as a busy disk or the link can be.
        if (saved.isEmpty && serverTimes) await first.future;
        saved.add(serverTimes);
      },
    );
    addTearDown(display.dispose);

    final toServer = display.setTimeDisplay(TimeDisplay.server);
    final toDevice = display.setTimeDisplay(TimeDisplay.device);
    first.complete();
    await Future.wait([toServer, toDevice]);

    expect(saved, [true, false]);
    expect(display.value, TimeDisplay.device);
  });

  /// The probe's `date +%z` for [_serverOffset].
  const serverZone = '+1245';

  ValueNotifier<HostProfile?> profileOf(String? zone) =>
      ValueNotifier(zone == null ? null : HostProfile(zoneOffset: zone));

  Widget scoped(
    TimeDisplayController display,
    Widget child, {
    Map<String, ValueListenable<HostProfile?>>? profiles,
  }) {
    final known = profiles ?? {_server: profileOf(serverZone)};
    return TimeDisplayScope(
      display: display,
      serverProfile: (serverId) => known[serverId] ?? profileOf(null),
      child: child,
    );
  }

  testWidgets('a server time reads the server\'s wall clock once picked and '
      'its zone is known, and this device\'s otherwise', (tester) async {
    final display = TimeDisplayController();
    addTearDown(display.dispose);
    late DateTime known, unread;
    await tester.pumpWidget(
      scoped(
        display,
        Builder(
          builder: (context) {
            known = displayTime(context, _server, _at);
            unread = displayTime(context, _unread, _at);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(known, _at.toLocal());
    expect(unread, _at.toLocal());

    await display.setTimeDisplay(TimeDisplay.server);
    await tester.pump();
    // 20:30 UTC is 09:15 the next day at +12:45.
    expect(
      (known.day, known.hour, known.minute),
      (28, 9, 15),
      reason: 'the dependent rebuilt',
    );
    expect(unread, _at.toLocal(), reason: 'no zone read yet');
  });

  testWidgets('a server zone read after the screen built rebuilds it', (
    tester,
  ) async {
    final display = TimeDisplayController(display: TimeDisplay.server);
    final profile = profileOf(null);
    addTearDown(() {
      display.dispose();
      profile.dispose();
    });
    late DateTime shown;
    await tester.pumpWidget(
      scoped(
        display,
        Builder(
          builder: (context) {
            shown = displayTime(context, _server, _at);
            return const SizedBox();
          },
        ),
        profiles: {_server: profile},
      ),
    );
    expect(shown, _at.toLocal());

    profile.value = HostProfile(zoneOffset: serverZone);
    await tester.pump();
    expect((shown.day, shown.hour, shown.minute), (28, 9, 15));
  });

  testWidgets('a chart\'s time axis reads the zone it is given', (
    tester,
  ) async {
    final ring = TimeSeriesRing(capacity: 2, lanes: 1);
    addTearDown(ring.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SizedBox(
          width: 400,
          height: 200,
          child: TimeSeriesChart(
            data: ring,
            labels: const ['CPU'],
            unit: ChartUnit.percent,
            strings: testChartStrings,
            source: 'test',
            end: _at,
            zoneOffset: _serverOffset,
          ),
        ),
      ),
    );
    final painter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((paint) => paint.painter)
        .whereType<TimeSeriesPainter>()
        .single;
    expect(painter.zoneOffsetOf(_at), _serverOffset);
  });

  testWidgets('a server screen shows its times in the server\'s zone', (
    tester,
  ) async {
    final engine = FakeEngineClient();
    final endpoints = TlsEndpoints(
      stored: {
        _server: [const TlsEndpoint('example.com', 443)],
      },
    );
    final monitoring = MonitoringController(engine, tlsEndpoints: endpoints);
    final display = TimeDisplayController(display: TimeDisplay.server);
    addTearDown(() async {
      display.dispose();
      monitoring.dispose();
      await engine.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: scoped(
          display,
          Scaffold(
            body: CertificatesSection(
              monitoring: monitoring,
              serverId: _server,
              now: () => DateTime.utc(2026, 10, 26, 12),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final check = engine.sentOfType<CheckTlsEndpoints>().single;
    engine.emit(
      TlsEndpointsChecked((check as CheckTlsEndpoints).requestId, [
        TlsEndpointCheck(
          endpoint: const TlsEndpoint('example.com', 443),
          certificate: TlsCertificateFacts(
            subject: '/CN=example.com',
            issuer: '/CN=R11',
            notBefore: DateTime.utc(2026, 9, 1),
            // Dec 26 at the server, Dec 25 in UTC.
            notAfter: DateTime.utc(2026, 12, 25, 18),
          ),
          trusted: true,
        ),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Expires Dec 26, 2026, in 60 days'), findsOneWidget);
  });
}
