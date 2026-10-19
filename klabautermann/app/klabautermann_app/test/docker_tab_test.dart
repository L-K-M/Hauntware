import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/controllers/docker_notice_controller.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/access/access_panel.dart' show AccessPanel;
import 'package:klabautermann_app/ui/docker/container_details.dart';
import 'package:klabautermann_app/ui/docker/docker_endpoint.dart';
import 'package:klabautermann_app/ui/docker/docker_panel.dart';
import 'package:klabautermann_app/ui/inspector_pane.dart';
import 'package:klabautermann_app/ui/server_coverage.dart'
    show ServerCoverageDetails;
import 'package:klabautermann_app/ui/server_header.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'access/profiles.dart';
import 'support/charts.dart'
    show goldenFontFamily, goldensCompareHere, loadGoldenFonts;
import 'support/docker.dart';
import 'support/fake_engine.dart';
import 'support/harness.dart';

const _desktop = Size(1280, 800);
const _phone = Size(390, 800);

const _waitingTitle = 'Waiting for the connection';
const _noticeTitle = 'Root-equivalent access';

Finder _inHeader(Finder finder) =>
    find.descendant(of: find.byType(ServerHeader), matching: finder);

Finder _inDocker(Finder finder) =>
    find.descendant(of: find.byType(DockerPanel), matching: finder);

/// Pumps the app at [size] and opens web-1 (srv-1).
Future<AppHarness> _openWeb1(
  WidgetTester tester, {
  Size size = _desktop,
  DockerNoticeController? notice,
}) async {
  final harness = await pumpApp(
    tester,
    size: size,
    servers: twoServers,
    dockerNotice: notice,
  );
  await tester.tap(find.text('web-1'));
  await tester.pumpAndSettle();
  return harness;
}

/// Selects the desktop workspace's Docker tab.
Future<void> _openDockerTab(WidgetTester tester) async {
  final tab = find.descendant(
    of: find.byType(TabBar),
    matching: find.text('Docker'),
  );
  await tester.ensureVisible(tab.first);
  await tester.pumpAndSettle();
  await tester.tap(tab.first);
  await tester.pumpAndSettle();
}

Future<void> _emit(WidgetTester tester, AppHarness harness, EngineEvent event) {
  harness.engine.emit(event);
  return tester.pumpAndSettle();
}

List<DockerQuery> _queries(AppHarness harness) =>
    harness.engine.sentOfType<DockerQuery>().cast();

/// Every failed endpoint the engine can report, with the header's words
/// and the Docker tab's.
final _failures = <(DockerEndpointState, String, String)>[
  (
    dockerNoRoute('srv-1', DockerNoRouteReason.noRelay),
    'No Engine API route: forwarding is off and there is no relay',
    'Socket forwarding is off on this server, and it has nothing to relay '
        'through: no docker or podman command, no socat and no nc.',
  ),
  (
    dockerNoRoute('srv-1', DockerNoRouteReason.needsAdminMode),
    'No Engine API route: the socket needs admin mode',
    'Your account cannot use the engine socket. Reaching it through sudo '
        'needs admin mode, which arrives in a later milestone.',
  ),
  (
    dockerNoRoute('srv-1', DockerNoRouteReason.socketDenied),
    'No Engine API route: your account cannot use the socket',
    'Your account cannot use the engine socket, and this server has no '
        'sudo. The Access tab shows how access is granted.',
  ),
  (
    dockerNoRoute('srv-1', DockerNoRouteReason.probeFailed),
    'No Engine API route: the socket check failed',
    'Checking the engine socket failed, so Klabautermann cannot tell how to '
        'reach it.',
  ),
  (
    dockerNoRoute('srv-1', DockerNoRouteReason.noSocket),
    'No Engine API route: no engine socket found',
    'No Docker or Podman socket was found on this server.',
  ),
  (
    dockerNoRoute('srv-1', DockerNoRouteReason.socketsUnknown),
    'No Engine API route: the sockets were not checked',
    "The server's capability check has not reported its engine sockets.",
  ),
  (
    _failed(DockerEndpointFailure.unreachable),
    'Engine API: the engine did not answer',
    'A route to the engine socket opened, but the engine did not answer '
        'over it.',
  ),
  (
    _failed(DockerEndpointFailure.belowClientFloor),
    "Engine API: the engine's API version is not supported",
    "The engine's newest API version is older than 1.41, the oldest "
        'Klabautermann supports.',
  ),
  (
    _failed(DockerEndpointFailure.belowServerMinimum),
    "Engine API: the engine's API version is not supported",
    'The engine only accepts API versions newer than Klabautermann '
        'supports.',
  ),
  (
    _failed(DockerEndpointFailure.apiVersionUnknown),
    "Engine API: the engine's API version is not supported",
    'The engine did not report an API version Klabautermann can read.',
  ),
  (
    _failed(DockerEndpointFailure.linkError),
    'Engine API: the connection failed while looking for a route',
    'The connection to this server failed while Klabautermann looked for '
        'the engine.',
  ),
];

DockerEndpointState _failed(DockerEndpointFailure failure) =>
    DockerEndpointState(
      serverId: 'srv-1',
      phase: DockerEndpointPhase.failed,
      failure: failure,
    );

/// 03 §5.9 and §10.2 (M3's D12): the server header names the Docker
/// transport in every mode (E4) with SAF-08's badge, and the Docker tab
/// follows the endpoint.
void main() {
  setUpAll(() async {
    if (goldensCompareHere) await loadGoldenFonts();
  });

  group('the header transport label (E4)', () {
    test('every rank and failure has its own words', () {
      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(
        dockerTransportText(l10n, null),
        'Engine API: waiting for the '
        'connection',
      );
      final ranks = {
        for (final rank in DockerRank.values)
          rank: dockerTransportText(l10n, dockerReady('srv-1', rank: rank)),
      };
      expect(ranks, {
        DockerRank.streamlocal: 'Engine API via SSH socket forward',
        DockerRank.cliRelay:
            'Engine API via docker CLI relay (limited streams)',
        DockerRank.sudoRelay: 'Engine API via sudo relay (root-equivalent)',
        DockerRank.socketRelay: 'Engine API via socat relay',
      });
      for (final (state, header, body) in _failures) {
        expect(dockerTransportText(l10n, state), header);
        expect(dockerFailureText(l10n, state), body);
      }
    });

    testWidgets('follows the endpoint from waiting to its route', (
      tester,
    ) async {
      final harness = await _openWeb1(tester);
      expect(
        _inHeader(find.text('Engine API: waiting for the connection')),
        findsOneWidget,
      );

      await _emit(
        tester,
        harness,
        const DockerEndpointState(
          serverId: 'srv-1',
          phase: DockerEndpointPhase.resolving,
        ),
      );
      expect(
        _inHeader(find.text('Engine API: looking for a route')),
        findsOneWidget,
      );

      for (final (rank, label) in [
        (DockerRank.streamlocal, 'Engine API via SSH socket forward'),
        (
          DockerRank.cliRelay,
          'Engine API via docker CLI relay (limited streams)',
        ),
        (DockerRank.socketRelay, 'Engine API via socat relay'),
      ]) {
        await _emit(tester, harness, dockerReady('srv-1', rank: rank));
        expect(_inHeader(find.text(label)), findsOneWidget, reason: '$rank');
      }

      for (final (state, header, _) in _failures) {
        await _emit(tester, harness, state);
        expect(_inHeader(find.text(header)), findsOneWidget, reason: header);
      }

      // Another server's endpoint is not this header's.
      await _emit(tester, harness, dockerReady('srv-2'));
      expect(
        _inHeader(find.text('Engine API via SSH socket forward')),
        findsNothing,
      );
    });

    testWidgets('the phone header names it too', (tester) async {
      final harness = await _openWeb1(tester, size: _phone);
      await _emit(
        tester,
        harness,
        dockerReady('srv-1', rank: DockerRank.cliRelay),
      );
      expect(
        _inHeader(
          find.text('Engine API via docker CLI relay (limited streams)'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the runtime is the engine the API names once a route is '
        'found (M13)', (tester) async {
      final harness = await _openWeb1(tester);
      await _emit(tester, harness, HostProfileChanged('srv-1', debianHost()));
      expect(
        _inHeader(
          find.text(
            "Runtime: Docker, rootful (Podman can also answer on Docker's "
            'socket path)',
          ),
        ),
        findsOneWidget,
      );

      // Podman answering on Docker's path.
      await _emit(
        tester,
        harness,
        dockerReady('srv-1', runtime: EngineRuntime.podman),
      );
      expect(_inHeader(find.text('Runtime: Podman, rootful')), findsOneWidget);
      expect(_inHeader(find.textContaining('Podman can also')), findsNothing);

      await _emit(
        tester,
        harness,
        dockerReady(
          'srv-1',
          mode: null,
          socketPath: '/srv/engine.sock',
          rootEquivalence: DockerRootEquivalence.unclassified,
        ),
      );
      expect(_inHeader(find.text('Runtime: Docker')), findsOneWidget);
    });

    testWidgets('carries SAF-08\'s badge for the engine its route reaches', (
      tester,
    ) async {
      final harness = await _openWeb1(tester);
      expect(_inHeader(find.byType(DockerRootBadge)), findsNothing);

      await _emit(tester, harness, dockerReady('srv-1'));
      expect(
        _inHeader(find.text('Rootful socket: root-equivalent')),
        findsOneWidget,
      );

      final rootless = dockerReady(
        'srv-1',
        socketPath: '/run/user/1000/docker.sock',
        mode: EngineMode.rootless,
        rootEquivalence: DockerRootEquivalence.rootlessEngine,
      );
      await _emit(tester, harness, rootless);
      expect(
        _inHeader(find.text('Rootless engine: equals your login user')),
        findsOneWidget,
        reason: 'no probe answer names the user yet',
      );
      await _emit(tester, harness, HostProfileChanged('srv-1', debianHost()));
      expect(
        _inHeader(find.text('Rootless engine: equals user alice')),
        findsOneWidget,
      );

      await _emit(
        tester,
        harness,
        dockerReady(
          'srv-1',
          mode: null,
          socketPath: '/srv/engine.sock',
          rootEquivalence: DockerRootEquivalence.unclassified,
        ),
      );
      expect(
        _inHeader(find.text('Custom socket: root-equivalent')),
        findsOneWidget,
      );

      await _emit(
        tester,
        harness,
        dockerReady(
          'srv-1',
          rank: DockerRank.sudoRelay,
          rootEquivalence: DockerRootEquivalence.sudoRelay,
        ),
      );
      expect(
        _inHeader(find.text('Sudo relay: root-equivalent')),
        findsOneWidget,
      );

      await _emit(
        tester,
        harness,
        dockerNoRoute('srv-1', DockerNoRouteReason.noSocket),
      );
      expect(_inHeader(find.byType(DockerRootBadge)), findsNothing);
    });

    testWidgets('shows the low-session indicator while the engine reports '
        'it', (tester) async {
      final harness = await _openWeb1(tester);
      await _emit(tester, harness, dockerReady('srv-1'));
      expect(_inHeader(find.text('Low-session mode')), findsNothing);

      await _emit(
        tester,
        harness,
        dockerReady('srv-1', rank: DockerRank.cliRelay, lowSession: true),
      );
      expect(_inHeader(find.text('Low-session mode')), findsOneWidget);
    });
  });

  group('the Docker tab', () {
    testWidgets('waits for the connection, then for the route', (tester) async {
      final harness = await _openWeb1(tester);
      await _openDockerTab(tester);
      expect(find.text(_waitingTitle), findsOneWidget);
      expect(find.byType(DockerPanel), findsNothing);
      expect(find.text('Open Access'), findsNothing);

      await _emit(
        tester,
        harness,
        const DockerEndpointState(
          serverId: 'srv-1',
          phase: DockerEndpointPhase.waiting,
        ),
      );
      expect(find.text(_waitingTitle), findsOneWidget);

      await _emit(
        tester,
        harness,
        const DockerEndpointState(
          serverId: 'srv-1',
          phase: DockerEndpointPhase.resolving,
        ),
      );
      expect(find.text('Looking for the Docker engine'), findsOneWidget);
      expect(find.byType(DockerPanel), findsNothing);
    });

    testWidgets('says why no route works, links to Access and asks '
        'again', (tester) async {
      final harness = await _openWeb1(tester);
      await _openDockerTab(tester);

      for (final (state, _, body) in _failures) {
        await _emit(tester, harness, state);
        expect(
          find.text('Docker is not available on this server'),
          findsOneWidget,
        );
        expect(find.text(body), findsOneWidget, reason: body);
        expect(find.byType(DockerPanel), findsNothing);
      }

      final before = _queries(harness).length;
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(_queries(harness), hasLength(before + 1));
      expect(_queries(harness).last.serverId, 'srv-1');

      await tester.tap(find.text('Open Access'));
      await tester.pumpAndSettle();
      expect(find.byType(AccessPanel), findsOneWidget);
    });

    testWidgets('a ready endpoint shows the engine strip and the sub-tabs, '
        'and reads the engine details while it shows', (tester) async {
      final harness = await _openWeb1(tester);
      await _openDockerTab(tester);

      // The link comes up: the controller asks for the endpoint.
      await _emit(tester, harness, const LinkState('srv-1', LinkReady()));
      expect(_queries(harness), hasLength(1));
      await _emit(
        tester,
        harness,
        dockerAnswer(
          _queries(harness).single,
          const DockerQueryFailed(DockerQueryFailure.profileUnknown),
        ),
      );

      await _emit(tester, harness, dockerReady('srv-1'));
      expect(find.byType(DockerPanel), findsOneWidget);
      expect(
        _inDocker(find.text('Reading the engine details…')),
        findsOneWidget,
      );
      expect(_queries(harness), hasLength(2));
      expect(_queries(harness).last.query, isA<DockerEngineQuery>());

      await _emit(
        tester,
        harness,
        dockerAnswer(_queries(harness).last, dockerEngine()),
      );
      for (final text in [
        'Engine',
        'Docker, rootful',
        'API 1.47',
        'Docker Engine - Community 27.3.1',
        'Ubuntu 24.04.1 LTS on x86_64',
        'Containers',
        'Images',
        'Stacks',
        'Reading the containers…',
      ]) {
        expect(_inDocker(find.text(text)), findsOneWidget, reason: text);
      }

      await tester.tap(_inDocker(find.text('Stacks')));
      await tester.pumpAndSettle();
      expect(
        DefaultTabController.of(
          tester.element(_inDocker(find.text('Stacks'))),
        ).index,
        DockerSubTab.stacks.index,
      );

      // Hidden, the tab reads nothing for a new route.
      final tab = find.descendant(
        of: find.byType(TabBar),
        matching: find.text('Overview'),
      );
      await tester.tap(tab.first);
      await tester.pumpAndSettle();
      await _emit(
        tester,
        harness,
        dockerReady('srv-1', rank: DockerRank.cliRelay),
      );
      expect(_queries(harness), hasLength(2));
      await _openDockerTab(tester);
      expect(_queries(harness), hasLength(3));
    });

    testWidgets('the Containers sub-tab watches the containers while it '
        'shows (CTR-01)', (tester) async {
      final harness = await _openWeb1(tester);
      await _openDockerTab(tester);
      List<DockerWatch> watches() =>
          harness.engine.sentOfType<DockerWatch>().cast();
      List<DockerUnwatch> unwatches() =>
          harness.engine.sentOfType<DockerUnwatch>().cast();
      expect(watches(), isEmpty, reason: 'no endpoint yet');

      await _emit(tester, harness, dockerReady('srv-1'));
      expect(watches(), hasLength(1));
      expect(watches().single.serverId, 'srv-1');
      await _emit(
        tester,
        harness,
        dockerContainerList('srv-1', [
          dockerContainer('a1f3c2e4b5d6', name: 'web-frontend'),
        ], at: DateTime(2026, 10, 15, 14, 30)),
      );
      expect(_inDocker(find.text('web-frontend')), findsOneWidget);

      // Another sub-tab hides it; coming back watches anew.
      await tester.tap(_inDocker(find.text('Images')));
      await tester.pumpAndSettle();
      expect(unwatches().single.watchId, watches().single.watchId);
      expect(
        _inDocker(find.text('Available in a later milestone.')),
        findsOneWidget,
      );
      await tester.tap(_inDocker(find.text('Containers')));
      await tester.pumpAndSettle();
      expect(watches(), hasLength(2));

      // So does another server tab.
      await tester.tap(
        find
            .descendant(
              of: find.byType(TabBar),
              matching: find.text('Overview'),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(unwatches(), hasLength(2));
      expect(unwatches().last.watchId, watches().last.watchId);
    });

    testWidgets('a container row opens its details in the inspector, until '
        'closed or another server is selected (CTR-03)', (tester) async {
      final harness = await _openWeb1(tester);
      await _openDockerTab(tester);
      await _emit(tester, harness, dockerReady('srv-1'));
      await _emit(
        tester,
        harness,
        dockerContainerList('srv-1', [
          dockerContainer('b7e9d0c1a2f3', name: 'web-db'),
        ], at: DateTime(2026, 10, 15, 14, 30)),
      );
      Finder inInspector(Finder finder) =>
          find.descendant(of: find.byType(InspectorPane), matching: finder);
      List<DockerQuery> inspects() => [
        for (final query in _queries(harness))
          if (query.query is DockerContainerQuery) query,
      ];

      await tester.tap(_inDocker(find.text('web-db')));
      await tester.pumpAndSettle();
      expect(inInspector(find.byType(ContainerDetailsView)), findsOneWidget);
      expect(inInspector(find.text('web-db')), findsOneWidget);
      expect(inspects(), hasLength(1));
      await _emit(
        tester,
        harness,
        dockerAnswer(
          inspects().single,
          DockerContainerPayload(dockerContainerDetails('b7e9d0c1a2f3')),
        ),
      );
      expect(inInspector(find.text('Restart unless stopped')), findsOneWidget);

      await tester.tap(
        inInspector(find.byTooltip('Close the container details')),
      );
      await tester.pumpAndSettle();
      expect(inInspector(find.byType(ContainerDetailsView)), findsNothing);
      expect(inInspector(find.byType(ServerCoverageDetails)), findsOneWidget);

      // Another server's selection lets the container go, also once the
      // first is selected again.
      await tester.tap(_inDocker(find.text('web-db')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('db-1'));
      await tester.pumpAndSettle();
      expect(inInspector(find.byType(ContainerDetailsView)), findsNothing);
      expect(inInspector(find.byType(ServerCoverageDetails)), findsOneWidget);
      await tester.tap(find.text('web-1'));
      await tester.pumpAndSettle();
      expect(inInspector(find.byType(ContainerDetailsView)), findsNothing);
    });

    testWidgets('a phone pushes a container\'s details', (tester) async {
      final harness = await _openWeb1(tester, size: _phone);
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Docker'),
        ),
      );
      await tester.pumpAndSettle();
      await _emit(tester, harness, dockerReady('srv-1'));
      await _emit(
        tester,
        harness,
        dockerContainerList('srv-1', [
          dockerContainer('b7e9d0c1a2f3', name: 'web-db'),
        ], at: DateTime(2026, 10, 15, 14, 30)),
      );

      await tester.tap(_inDocker(find.text('web-db')));
      await tester.pumpAndSettle();
      expect(find.byType(ContainerDetailsPage), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ContainerDetailsPage), findsNothing);
      expect(find.byType(DockerPanel), findsOneWidget);
    });

    testWidgets('says when the engine details could not be read, and reads '
        'them again', (tester) async {
      final harness = await _openWeb1(tester);
      await _openDockerTab(tester);
      await _emit(tester, harness, dockerReady('srv-1'));
      await _emit(
        tester,
        harness,
        dockerAnswer(
          _queries(harness).last,
          const DockerQueryFailed(DockerQueryFailure.daemonError),
        ),
      );
      expect(
        _inDocker(find.text('The engine details could not be read.')),
        findsOneWidget,
      );

      await tester.tap(_inDocker(find.text('Try again')));
      await tester.pumpAndSettle();
      await _emit(
        tester,
        harness,
        dockerAnswer(_queries(harness).last, dockerEngine()),
      );
      expect(
        _inDocker(find.text('Docker Engine - Community 27.3.1')),
        findsOneWidget,
      );
    });

    testWidgets('the phone\'s Docker destination shows the panel once the '
        'endpoint is ready', (tester) async {
      final harness = await _openWeb1(tester, size: _phone);
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Docker'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(_waitingTitle), findsOneWidget);

      await _emit(tester, harness, dockerReady('srv-1'));
      expect(find.byType(DockerPanel), findsOneWidget);
      expect(_queries(harness), hasLength(1));
      await _emit(
        tester,
        harness,
        dockerAnswer(_queries(harness).last, dockerEngine()),
      );
      expect(
        _inDocker(find.text('Docker Engine - Community 27.3.1')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('SAF-08\'s notice (M12)', () {
    late Directory directory;
    late File file;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('klab-docker-notice-');
      file = File('${directory.path}/$deviceSettingsFileName');
    });

    tearDown(() => directory.deleteSync(recursive: true));

    Future<void> writeNow(File target, List<int> bytes) async =>
        target.writeAsBytesSync(bytes, flush: true);

    testWidgets('heads the Docker tab until dismissed, once per device, '
        'kept in settings.json', (tester) async {
      final settings = (await tester.runAsync(
        () => DeviceSettingsStore.open(file, writer: writeNow),
      ))!;
      final harness = await _openWeb1(
        tester,
        notice: DockerNoticeController(
          dismissed: settings.rootEquivalenceNoticeDismissed,
          saveDismissal: settings.dismissRootEquivalenceNotice,
        ),
      );
      await _openDockerTab(tester);
      await _emit(tester, harness, dockerReady('srv-1'));
      expect(_inDocker(find.text(_noticeTitle)), findsOneWidget);
      expect(
        _inDocker(
          find.text(
            'Using a rootful Docker or Podman socket, or a broad '
            'passwordless sudo rule, gives the same power as root on this '
            'server. A rootless engine gives only the power of the user '
            'that runs it.',
          ),
        ),
        findsOneWidget,
      );

      await tester.tap(_inDocker(find.text('Got it')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(_inDocker(find.text(_noticeTitle)), findsNothing);
      expect(harness.dockerNotice.showsNotice, isFalse);

      final nextLaunch = (await tester.runAsync(
        () => DeviceSettingsStore.open(file),
      ))!;
      expect(nextLaunch.rootEquivalenceNoticeDismissed, isTrue);
    });

    testWidgets('stays away once dismissed on this device', (tester) async {
      final harness = await _openWeb1(
        tester,
        notice: DockerNoticeController(dismissed: true),
      );
      await _openDockerTab(tester);
      await _emit(tester, harness, dockerReady('srv-1'));
      expect(find.byType(DockerPanel), findsOneWidget);
      expect(_inDocker(find.text(_noticeTitle)), findsNothing);
    });

    testWidgets('a dismissal that cannot be saved says it will return', (
      tester,
    ) async {
      final harness = await _openWeb1(
        tester,
        notice: DockerNoticeController(
          saveDismissal: () async =>
              throw const DeviceSettingsReadOnlyException(
                DeviceSettingsIssueKind.newerVersion,
              ),
        ),
      );
      await _openDockerTab(tester);
      await _emit(tester, harness, dockerReady('srv-1'));

      final previous = debugPrint;
      final printed = <String>[];
      debugPrint = (message, {wrapWidth}) => printed.add('$message');
      try {
        await tester.tap(_inDocker(find.text('Got it')));
        await tester.pumpAndSettle();
      } finally {
        debugPrint = previous;
      }

      expect(_inDocker(find.text(_noticeTitle)), findsNothing);
      expect(printed.single, contains('DeviceSettingsReadOnlyException'));
      expect(
        find.text(
          'Klabautermann could not save that you dismissed the '
          'root-equivalence note, so it shows again after a restart.',
        ),
        findsOneWidget,
      );
      // The toast's timer runs out before the test ends.
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });
  });

  group('golden', () {
    // 03 §11.1: a connected server whose Docker engine is reached over a
    // relay in low-session mode, with the rootful badge.
    for (final brightness in Brightness.values) {
      testWidgets('header, ${brightness.name}', (tester) async {
        tester.view.physicalSize = const Size(900, 200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        const server = FleetServer(
          id: 'srv-1',
          displayName: 'web-1',
          address: 'web-1.example',
        );
        final engine = FakeEngineClient();
        final fleet = FleetController(engine, servers: const [server]);
        final monitoring = MonitoringController(engine);
        addTearDown(() async {
          fleet.dispose();
          monitoring.dispose();
          await engine.close();
        });

        final base = brightness == Brightness.light
            ? GhostTheme.light(
                klabautermannThemeStyle,
                platform: TargetPlatform.linux,
              )
            : GhostTheme.dark(
                klabautermannThemeStyle,
                platform: TargetPlatform.linux,
              );
        final theme = base.copyWith(
          textTheme: base.textTheme.apply(fontFamily: goldenFontFamily),
        );
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Material(
              color: theme.colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ListenableBuilder(
                  listenable: fleet,
                  builder: (context, _) => ServerHeader(
                    server: server,
                    fleet: fleet,
                    monitoring: monitoring,
                  ),
                ),
              ),
            ),
          ),
        );
        engine
          ..emit(const LinkState('srv-1', LinkReady()))
          ..emit(HostProfileChanged('srv-1', debianHost()))
          ..emit(
            dockerReady('srv-1', rank: DockerRank.cliRelay, lowSession: true),
          );
        await tester.pumpAndSettle();

        await expectLater(
          find.byType(ServerHeader),
          matchesGoldenFile(
            'goldens/server_header_docker_${brightness.name}.png',
          ),
        );
      }, skip: !goldensCompareHere);
    }
  });
}
