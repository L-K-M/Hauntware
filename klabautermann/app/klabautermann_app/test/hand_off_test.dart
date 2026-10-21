// Hand-offs to Séance and Poltergeist (X-03, X-04, X-10; M5 plan M31).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart'
    show FleetServer;
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/services/hand_off.dart';
import 'package:klabautermann_app/ui/docker/stacks_panel.dart'
    show StackOverview;
import 'package:klabautermann_app/ui/hand_off_actions.dart';
import 'package:klabautermann_app/ui/logs/logs_panel.dart' show LogFilePicker;
import 'package:klabautermann_core/klabautermann_core.dart'
    show HostResult, VarLogFiles;
import 'package:klabautermann_host/klabautermann_host.dart' show LogFileEntry;

import 'support/docker.dart';
import 'support/fake_engine.dart';
import 'support/harness.dart';

const _catalogId = '123e4567-e89b-42d3-a456-426614174000';

/// The keys a sender might use to smuggle a command (X8).
const _commandKeys = ['cmd', 'command', 'exec', 'run', 'script', 'snippet'];

void main() {
  group('links', () {
    test('a Séance link names the server and the folder, nothing else', () {
      final bare = seanceHandOff(_catalogId.toUpperCase())!;
      expect(bare.scheme, 'seance');
      expect(bare.host, 'connect');
      expect(bare.queryParameters, {'serverId': _catalogId});

      final inFolder = seanceHandOff(_catalogId, folder: '/srv/app; rm -rf ~')!;
      expect(inFolder.queryParameters, {
        'serverId': _catalogId,
        'cwd': '/srv/app; rm -rf ~',
      });
      for (final link in [bare, inFolder]) {
        expect(
          link.queryParameters.keys,
          isNot(anyElement(isIn(_commandKeys))),
        );
      }
    });

    test('a Poltergeist link names the server and the path, nothing else', () {
      final link = poltergeistHandOff(_catalogId, path: '/var/log/syslog')!;
      expect(link.scheme, 'poltergeist');
      expect(link.host, 'browse');
      expect(link.queryParameters, {
        'serverId': _catalogId,
        'path': '/var/log/syslog',
      });
    });

    test('a server or folder the siblings cannot name gets no link', () {
      // An ssh_config import's id only this app knows.
      expect(seanceHandOff('ssh-config:web'), isNull);
      expect(seanceHandOff(_catalogId, folder: 'relative'), isNull);
      expect(seanceHandOff(_catalogId, folder: '/srv/\nreboot'), isNull);
      expect(poltergeistHandOff(_catalogId, path: '/srv/'), isNull);
      expect(poltergeistHandOff('ssh-config:web', path: '/'), isNull);
    });
  });

  group('availability', () {
    test('follows where each sibling registers its scheme', () {
      final table = {
        for (final platform in TargetPlatform.values)
          platform: {
            for (final target in HandOffTarget.values)
              if (handOffIntakeOn(target, platform)) target,
          },
      };
      expect(table, {
        TargetPlatform.android: HandOffTarget.values.toSet(),
        TargetPlatform.iOS: HandOffTarget.values.toSet(),
        TargetPlatform.macOS: HandOffTarget.values.toSet(),
        TargetPlatform.linux: {HandOffTarget.poltergeist},
        TargetPlatform.windows: {HandOffTarget.poltergeist},
        TargetPlatform.fuchsia: <HandOffTarget>{},
      });
    });

    test('needs both an intake and a handler, and a failed probe is no '
        'handler', () async {
      final probed = <Uri>[];
      final errors = <Object>[];
      final launcher = await UrlHandOffLauncher.probe(
        platform: TargetPlatform.linux,
        onError: (error, _) => errors.add(error),
        probe: (uri) async {
          probed.add(uri);
          return true;
        },
        open: (_) async => true,
      );
      // Séance has no Linux intake, so it is not even asked about.
      expect(probed, [Uri.parse('poltergeist://browse')]);
      expect(launcher.available(HandOffTarget.seance), isFalse);
      expect(launcher.available(HandOffTarget.poltergeist), isTrue);

      final failing = await UrlHandOffLauncher.probe(
        platform: TargetPlatform.macOS,
        onError: (error, _) => errors.add(error),
        probe: (uri) async =>
            uri.scheme == 'seance' ? throw StateError('no probe') : false,
        open: (_) async => true,
      );
      expect(failing.available(HandOffTarget.seance), isFalse);
      expect(failing.available(HandOffTarget.poltergeist), isFalse);
      expect(errors, [isStateError]);
    });
  });

  group('the server header', () {
    testWidgets('opens the server in Séance where it can take the link', (
      tester,
    ) async {
      final launcher = _Launcher({HandOffTarget.seance});
      await _openServer(tester, launcher, id: _catalogId);

      await tester.tap(find.text('Open terminal in Séance'));
      await tester.pumpAndSettle();

      expect(launcher.opened, [
        Uri.parse('seance://connect?serverId=$_catalogId'),
      ]);
    });

    testWidgets('says so when the OS refuses the link', (tester) async {
      final launcher = _Launcher({HandOffTarget.seance}, opens: false);
      await _openServer(tester, launcher, id: _catalogId);

      await tester.tap(find.text('Open terminal in Séance'));
      await tester.pumpAndSettle();

      expect(find.text('Séance did not open the link.'), findsOneWidget);
    });

    testWidgets('offers nothing without an intake, a handler or a catalog '
        'id', (tester) async {
      await _openServer(tester, _Launcher({}), id: _catalogId);
      expect(find.text('Open terminal in Séance'), findsNothing);

      await _openServer(
        tester,
        _Launcher({HandOffTarget.seance}),
        id: 'ssh-config:web',
      );
      expect(find.text('Open terminal in Séance'), findsNothing);
    });

    testWidgets('offers nothing without a launcher', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: OpenInSeanceButton(serverId: _catalogId)),
      );
      expect(find.byType(TextButton), findsNothing);
    });
  });

  group('folders (X-04)', () {
    testWidgets('open a terminal there in Séance and the folder in '
        'Poltergeist', (tester) async {
      final launcher = _Launcher({
        HandOffTarget.seance,
        HandOffTarget.poltergeist,
      });
      await _folder(tester, launcher, folder: '/srv/web');

      await tester.tap(find.text('Open terminal here'));
      await tester.tap(find.text('Open in Poltergeist'));
      await tester.pumpAndSettle();

      expect(launcher.opened, [
        Uri.parse('seance://connect?serverId=$_catalogId&cwd=%2Fsrv%2Fweb'),
        Uri.parse(
          'poltergeist://browse?serverId=$_catalogId&path=%2Fsrv%2Fweb',
        ),
      ]);
    });

    testWidgets('each follows its own app, and says when the OS refuses', (
      tester,
    ) async {
      final launcher = _Launcher({HandOffTarget.poltergeist}, opens: false);
      await _folder(tester, launcher, folder: '/srv/web');
      expect(find.text('Open terminal here'), findsNothing);

      await tester.tap(find.text('Open in Poltergeist'));
      await tester.pumpAndSettle();
      expect(find.text('Poltergeist did not open the link.'), findsOneWidget);
    });

    testWidgets('a folder or server the siblings cannot name offers '
        'nothing', (tester) async {
      final launcher = _Launcher({
        HandOffTarget.seance,
        HandOffTarget.poltergeist,
      });
      await _folder(tester, launcher, folder: 'srv/web');
      expect(find.byType(TextButton), findsNothing);

      await _folder(tester, launcher, folder: '/srv/web', id: 'ssh-config:web');
      expect(find.byType(TextButton), findsNothing);
    });

    testWidgets("a stack's overview offers its working directory", (
      tester,
    ) async {
      final engine = FakeEngineClient();
      final monitoring = MonitoringController(engine);
      addTearDown(() async {
        monitoring.dispose();
        await engine.close();
      });
      final launcher = _Launcher({
        HandOffTarget.seance,
        HandOffTarget.poltergeist,
      });
      await tester.pumpWidget(
        _localized(
          HandOffScope(
            launcher: launcher,
            child: StackOverview(
              monitoring: monitoring,
              serverId: _catalogId,
              project: 'web',
            ),
          ),
        ),
      );
      engine.emit(
        dockerStackList(_catalogId, [
          dockerStack('web', []),
        ], at: DateTime(2026, 10, 21)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open in Poltergeist'));
      await tester.pumpAndSettle();
      expect(launcher.opened.single.queryParameters['path'], '/srv/web');
    });
  });

  group('log folders and files (X-04, X-10)', () {
    Future<void> browse(WidgetTester tester, HandOffLauncher? launcher) async {
      final picker = SingleChildScrollView(
        child: LogFilePicker(
          serverId: _catalogId,
          selected: '/var/log/syslog',
          files: Future.value(
            HostResult(
              serverId: _catalogId,
              queryId: 'var-log',
              payload: VarLogFiles([
                LogFileEntry(
                  path: '/var/log/syslog',
                  bytes: 2048,
                  modified: DateTime.utc(2026, 10, 21),
                  readable: true,
                ),
              ]),
            ),
          ),
        ),
      );
      await tester.pumpWidget(
        _localized(
          launcher == null
              ? picker
              : HandOffScope(launcher: launcher, child: picker),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the /var/log browser opens the folder and each file', (
      tester,
    ) async {
      final launcher = _Launcher({
        HandOffTarget.seance,
        HandOffTarget.poltergeist,
      });
      await browse(tester, launcher);
      expect(find.text('Open terminal here'), findsOneWidget);

      await tester.tap(find.byTooltip('Open in Poltergeist'));
      await tester.pumpAndSettle();
      expect(launcher.opened, [
        Uri.parse(
          'poltergeist://browse?serverId=$_catalogId&path=%2Fvar%2Flog%2Fsyslog',
        ),
      ]);
    });

    testWidgets('without a launcher the browser offers no hand-off', (
      tester,
    ) async {
      await browse(tester, null);
      expect(find.text('/var/log/syslog'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byTooltip('Open in Poltergeist'), findsNothing);
    });
  });
}

Widget _localized(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

Future<void> _folder(
  WidgetTester tester,
  HandOffLauncher launcher, {
  required String folder,
  String id = _catalogId,
}) async {
  await tester.pumpWidget(
    _localized(
      HandOffScope(
        launcher: launcher,
        child: FolderHandOffs(serverId: id, folder: folder),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openServer(
  WidgetTester tester,
  HandOffLauncher launcher, {
  required String id,
}) async {
  await pumpApp(
    tester,
    servers: [
      FleetServer(id: id, displayName: 'web-1', address: 'web-1.example'),
    ],
    handOff: launcher,
  );
  await tester.tap(find.text('web-1'));
  await tester.pumpAndSettle();
}

final class _Launcher implements HandOffLauncher {
  _Launcher(this._available, {this.opens = true});

  final Set<HandOffTarget> _available;
  final bool opens;
  final opened = <Uri>[];

  @override
  bool available(HandOffTarget target) => _available.contains(target);

  @override
  Future<bool> open(Uri link) async {
    opened.add(link);
    return opens;
  }
}
