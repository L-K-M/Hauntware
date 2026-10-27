// CRT-01: the System tab's Certificates section, which checks the
// endpoints listed for a server from this device through the engine, and
// the list's parser and store.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/controllers/tls_endpoints.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/certificates.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _server = 'srv-1';
const _web = TlsEndpoint('example.com', 443);
const _mail = TlsEndpoint('mail.example.com', 993);
const _admin = TlsEndpoint('192.0.2.10', 8443);

/// Noon UTC, so local dates match across the runner's time zones.
final _now = DateTime.utc(2026, 10, 26, 12);

TlsEndpointCheck _valid(TlsEndpoint endpoint, DateTime notAfter) =>
    TlsEndpointCheck(
      endpoint: endpoint,
      certificate: TlsCertificateFacts(
        subject: '/CN=${endpoint.host}',
        issuer: "/C=US/O=Let's Encrypt/CN=R11",
        notBefore: DateTime.utc(2026, 9, 1),
        notAfter: notAfter,
      ),
      trusted: true,
    );

void main() {
  group('parseTlsEndpoints', () {
    test('takes one per line, drops blanks and repeats', () {
      final (:endpoints, :problem) = parseTlsEndpoints(
        'example.com\n\n mail.example.com:993\nexample.com:443\n',
      );
      expect(problem, isNull);
      expect(endpoints, [_web, _mail]);
    });

    test('refuses a line that is not an endpoint, or too many', () {
      expect(
        parseTlsEndpoints('example.com\nhttps://example.com').problem,
        TlsEndpointsProblem.notEndpoint,
      );
      expect(
        parseTlsEndpoints(
          [
            for (var i = 0; i <= kTlsEndpointsMax; i++) 'h$i.example',
          ].join('\n'),
        ).problem,
        TlsEndpointsProblem.tooMany,
      );
    });
  });

  test('TlsEndpoints saves a change and removes an empty list', () async {
    final saved = <(String, List<TlsEndpoint>)>[];
    final endpoints = TlsEndpoints(
      stored: {
        _server: [_web],
      },
      save: (server, list) async => saved.add((server, list)),
    );
    expect(endpoints.endpointsFor(_server), [_web]);
    await endpoints.setEndpoints(_server, [_web, _mail]);
    expect(endpoints.endpointsFor(_server), [_web, _mail]);
    await endpoints.setEndpoints(_server, const []);
    expect(endpoints.endpointsFor(_server), isEmpty);
    expect(saved.map((s) => s.$2.length), [2, 0]);
  });

  late FakeEngineClient engine;
  late MonitoringController monitoring;
  late TlsEndpoints endpoints;

  setUp(() {
    engine = FakeEngineClient();
    endpoints = TlsEndpoints(
      stored: {
        _server: [_web, _mail, _admin],
      },
    );
    monitoring = MonitoringController(engine, tlsEndpoints: endpoints);
  });

  tearDown(() async {
    monitoring.dispose();
    await engine.close();
  });

  Future<void> pump(WidgetTester tester, {String server = _server}) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: CertificatesSection(
              monitoring: monitoring,
              serverId: server,
              now: () => _now,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  List<CheckTlsEndpoints> checks() =>
      engine.sentOfType<CheckTlsEndpoints>().cast<CheckTlsEndpoints>().toList();

  Future<void> answer(WidgetTester tester, List<TlsEndpointCheck> list) async {
    engine.emit(TlsEndpointsChecked(checks().last.requestId, list));
    await tester.pumpAndSettle();
  }

  testWidgets('each listed endpoint shows its expiry, issuer and trust, '
      'checked when the section shows', (tester) async {
    await pump(tester);
    expect(checks().single.endpoints, [_web, _mail, _admin]);
    expect(find.text('Checking…'), findsNWidgets(3));

    await answer(tester, [
      _valid(_web, DateTime.utc(2026, 12, 25, 12)),
      TlsEndpointCheck(
        endpoint: _mail,
        certificate: TlsCertificateFacts(
          subject: '/CN=mail.example.com',
          issuer: '/CN=mail.example.com',
          notBefore: DateTime.utc(2025, 10, 1),
          notAfter: DateTime.utc(2026, 10, 1, 12),
        ),
      ),
      const TlsEndpointCheck(
        endpoint: _admin,
        failure: TlsCheckFailure.connect,
        detail: 'SocketException: Connection refused',
      ),
    ]);
    expect(find.text('Expires Dec 25, 2026, in 60 days'), findsOneWidget);
    expect(find.text("Issued by /C=US/O=Let's Encrypt/CN=R11"), findsOneWidget);
    expect(find.text('Expired Oct 1, 2026'), findsOneWidget);
    expect(
      find.textContaining('This device does not trust this certificate'),
      findsOneWidget,
    );
    expect(find.text('This device could not connect.'), findsOneWidget);
    expect(find.text('SocketException: Connection refused'), findsOneWidget);
    // Two of three lines warn: the expired one and the failed one.
    expect(find.byIcon(Icons.warning_amber), findsNWidgets(2));
    expect(find.byIcon(Icons.verified_outlined), findsOneWidget);
    // The warning icons take the error colour; a good line stays muted.
    final scheme = Theme.of(
      tester.element(find.text('Check again')),
    ).colorScheme;
    expect(
      {
        for (final icon in tester.widgetList<Icon>(
          find.byIcon(Icons.warning_amber),
        ))
          icon.color,
      },
      {scheme.error},
    );
    expect(
      tester.widget<Icon>(find.byIcon(Icons.verified_outlined)).color,
      scheme.onSurfaceVariant,
    );

    await tester.tap(find.text('Check again'));
    await tester.pump();
    expect(checks(), hasLength(2));
  });

  testWidgets('editing the list saves it and checks the new endpoints', (
    tester,
  ) async {
    endpoints = TlsEndpoints();
    monitoring.dispose();
    monitoring = MonitoringController(engine, tlsEndpoints: endpoints);
    await pump(tester);
    expect(checks(), isEmpty);
    expect(
      find.textContaining('List the host names and ports'),
      findsOneWidget,
    );

    await tester.tap(find.text('Edit endpoints…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://example.com');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Each line needs a host name or address, with an optional :port.',
      ),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField), 'example.com');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(endpoints.endpointsFor(_server), [_web]);
    expect(checks().single.endpoints, [_web]);
    await answer(tester, [_valid(_web, DateTime.utc(2026, 11, 2, 12))]);
    expect(find.text('Expires Nov 2, 2026, in 7 days'), findsOneWidget);
    // Within two weeks: it warns.
    expect(find.byIcon(Icons.warning_amber), findsOneWidget);
  });

  testWidgets('a server switch checks the new server\'s list', (tester) async {
    await pump(tester);
    await pump(tester, server: 'srv-2');
    // srv-2 lists none: nothing more is sent.
    expect(checks(), hasLength(1));
    expect(
      find.textContaining('List the host names and ports'),
      findsOneWidget,
    );
  });
}
