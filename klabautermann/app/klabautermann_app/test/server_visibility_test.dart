import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/app.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/controllers/prompt_controller.dart';
import 'package:klabautermann_app/ui/inspector_pane.dart';
import 'package:klabautermann_app/ui/overview_panel.dart';
import 'package:klabautermann_app/ui/server_surfaces.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';
import 'support/harness.dart';

const _desktop = Size(1280, 800);
const _phone = Size(390, 800);

/// The panels' subscriptions, without the Overview coverage card's one
/// `units` read (03 §9.5 item 3), which server_coverage_test.dart covers.
List<Subscribe> _subscribes(FakeEngineClient engine) => engine
    .sentOfType<Subscribe>()
    .cast<Subscribe>()
    .where((request) => !_coverageRead(request.subscriptionId))
    .toList();

List<Unsubscribe> _unsubscribes(FakeEngineClient engine) => engine
    .sentOfType<Unsubscribe>()
    .cast<Unsubscribe>()
    .where((request) => !_coverageRead(request.subscriptionId))
    .toList();

bool _coverageRead(String subscriptionId) =>
    subscriptionId.startsWith('coverage-');

/// The coverage card's `units` reads, in order, as "subscribe" or
/// "unsubscribe".
List<String> _coverageReads(FakeEngineClient engine) => [
  for (final request in engine.sent)
    ?switch (request) {
      Subscribe(:final subscriptionId) when _coverageRead(subscriptionId) =>
        'subscribe',
      Unsubscribe(:final subscriptionId) when _coverageRead(subscriptionId) =>
        'unsubscribe',
      _ => null,
    },
];

/// The Connect and Disconnect requests sent, in order.
List<String> _linkRequests(FakeEngineClient engine) => [
  for (final request in engine.sent)
    ?switch (request) {
      Connect(:final serverId) => 'connect $serverId',
      Disconnect(:final serverId) => 'disconnect $serverId',
      _ => null,
    },
];

/// Selects the workspace tab [label]; the scrollable strip may have to
/// bring it into view first.
Future<void> _openTab(WidgetTester tester, String label) async {
  final tab = find.descendant(
    of: find.byType(TabBar),
    matching: find.text(label),
  );
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

/// Pumps the app at [size] and opens web-1 (srv-1).
Future<AppHarness> _openWeb1(
  WidgetTester tester,
  Size size, {
  Duration linkGrace = Duration.zero,
}) async {
  final harness = await pumpApp(
    tester,
    size: size,
    servers: twoServers,
    linkGrace: linkGrace,
  );
  await _tapAndSettle(tester, find.text('web-1'));
  return harness;
}

Future<void> _tapAndSettle(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// 03 §6.4 and CN-05: the open server keeps its link, and only what the
/// user can see samples (D45: each surface under its own id).
void main() {
  testWidgets('the desktop workspace connects its server and samples only '
      'the selected tab', (tester) async {
    final harness = await _openWeb1(tester, _desktop);
    final engine = harness.engine;
    expect(_linkRequests(engine), ['connect srv-1']);
    final [overview] = _subscribes(engine);
    expect(overview.serverId, 'srv-1');
    expect(overview.streams, ServerPanel.overview.streams);
    // The shown panel only: the others are not built or not visible.
    expect(find.byType(OverviewPanel), findsOneWidget);
    expect(find.byType(PlaceholderPaneBody), findsNothing);

    // A connect the engine rejects as no server it can dial shows
    // nothing (a ConnectRejected would show a banner).
    engine.emit(
      const RequestRejected(
        'Connect',
        'no fleet server srv-1 the engine can dial',
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(SnackBar), findsNothing);

    await _openTab(tester, 'Processes');
    expect(
      _unsubscribes(engine).single.subscriptionId,
      overview.subscriptionId,
    );
    final processes = _subscribes(engine).last;
    expect(processes.streams, {SampleStream.procs});
    expect(processes.subscriptionId, isNot(overview.subscriptionId));

    // Logs follow log streams, not samples: nothing to subscribe.
    await _openTab(tester, 'Logs');
    expect(_unsubscribes(engine).last.subscriptionId, processes.subscriptionId);
    expect(_subscribes(engine), hasLength(2));

    // A kept page subscribes again under its own id.
    await _openTab(tester, 'Overview');
    expect(_subscribes(engine).last.subscriptionId, overview.subscriptionId);
    expect(
      harness.monitoring.isSubscribed('srv-1', overview.subscriptionId),
      isTrue,
    );
    expect(_linkRequests(engine), ['connect srv-1']);
  });

  // D45: the Overview's coverage card reads `units` only while it shows.
  for (final (layout, size, away) in [
    ('desktop workspace', _desktop, 'Processes'),
    ('phone screen', _phone, 'Docker'),
  ]) {
    testWidgets('the $layout\'s coverage card stops reading as its tab '
        'hides', (tester) async {
      final engine = (await _openWeb1(tester, size)).engine;
      expect(_coverageReads(engine), ['subscribe']);

      if (size == _desktop) {
        await _openTab(tester, away);
        await _openTab(tester, 'Logs');
      } else {
        await _tapAndSettle(tester, find.text(away));
      }
      expect(_coverageReads(engine), ['subscribe', 'unsubscribe']);
    });
  }

  testWidgets('selecting another server moves the link and the '
      'subscription', (tester) async {
    final harness = await _openWeb1(tester, _desktop);
    final engine = harness.engine;
    await _tapAndSettle(tester, find.text('db-1'));

    // The harness's grace is zero, so leaving disconnects at once.
    expect(_linkRequests(engine), [
      'connect srv-1',
      'connect srv-2',
      'disconnect srv-1',
    ]);
    final [first, second] = _subscribes(engine);
    expect(_unsubscribes(engine).single.serverId, 'srv-1');
    expect(second.serverId, 'srv-2');
    expect(second.streams, first.streams);

    // Deselected (the server left the fleet): everything is let go, with
    // nothing sent, since the engine dropped the link and subscription
    // with the entry (03 §5.1).
    final sent = engine.sent.length;
    engine.emit(CatalogReplaced(const []));
    await tester.pumpAndSettle();
    expect(engine.sent, hasLength(sent));
    expect(
      harness.monitoring.isSubscribed('srv-2', second.subscriptionId),
      isFalse,
    );
  });

  testWidgets('a restarted engine\'s controllers get every surface anew '
      '(D44)', (tester) async {
    final menuPushes = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.menu,
      (call) async {
        if (call.method == 'Menu.setMenus') menuPushes.add(call.arguments);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.menu,
        null,
      ),
    );
    final harness = await _openWeb1(tester, _desktop);
    final restarted = FakeEngineClient();
    final monitoring = MonitoringController(
      restarted,
      linkGrace: Duration.zero,
    );
    final prompts = PromptController(restarted);
    addTearDown(() async {
      monitoring.dispose();
      prompts.dispose();
      await restarted.close();
    });

    await tester.pumpWidget(
      KlabautermannApp(
        fleet: harness.fleet,
        monitoring: monitoring,
        prompts: prompts,
        appearance: harness.appearance,
        coverage: harness.coverage,
        announcements: harness.announcements,
      ),
    );
    await tester.pumpAndSettle();
    expect(_linkRequests(restarted), ['connect srv-1']);
    expect(_subscribes(restarted).single.streams, ServerPanel.overview.streams);
    // The first run's surfaces let go as they unmount.
    expect(_linkRequests(harness.engine), [
      'connect srv-1',
      'disconnect srv-1',
    ]);
    expect(_unsubscribes(harness.engine), hasLength(1));
    // macOS has one native menu bar: the old tree's bar clears it as it
    // goes, so the new tree's must set it after that, not before.
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      expect('${menuPushes.last}', contains('Settings…'));
    }
  }, variant: TargetPlatformVariant.all());

  testWidgets('the phone screen holds its server open and samples the '
      'selected destination', (tester) async {
    final engine = (await _openWeb1(tester, _phone)).engine;
    expect(_linkRequests(engine), ['connect srv-1']);
    final [overview] = _subscribes(engine);
    expect(overview.streams, ServerPanel.overview.streams);

    await _tapAndSettle(tester, find.text('Docker'));
    expect(
      _unsubscribes(engine).single.subscriptionId,
      overview.subscriptionId,
    );
    expect(_subscribes(engine), hasLength(1));

    await _tapAndSettle(tester, find.text('Overview'));
    expect(_subscribes(engine), hasLength(2));

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(_unsubscribes(engine), hasLength(2));
    expect(_linkRequests(engine), ['connect srv-1', 'disconnect srv-1']);
  });

  testWidgets('a server opened again within the grace keeps its link', (
    tester,
  ) async {
    final engine = (await _openWeb1(
      tester,
      _phone,
      linkGrace: kLinkLeaveGrace,
    )).engine;
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 10));
    await _tapAndSettle(tester, find.text('web-1'));
    expect(_linkRequests(engine), ['connect srv-1']);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pump(kLinkLeaveGrace);
    expect(_linkRequests(engine), ['connect srv-1', 'disconnect srv-1']);
  });

  group('app activity (03 §10.1)', () {
    List<AppActivity> told(AppHarness harness) => [
      for (final request in harness.engine.sentOfType<SetAppActivity>())
        (request as SetAppActivity).activity,
    ];

    /// Moves the app through [states]; it is resumed after the test.
    void lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      for (final state in states) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
    }

    testWidgets('a phone tells the engine when the app leaves sight and '
        'returns', (tester) async {
      final harness = await pumpApp(tester, size: _phone);

      // Shown without focus is still in sight.
      lifecycle(tester, [AppLifecycleState.inactive]);
      expect(told(harness), isEmpty);
      lifecycle(tester, [AppLifecycleState.hidden]);
      expect(told(harness), [AppActivity.background]);
      lifecycle(tester, [AppLifecycleState.paused]);
      expect(told(harness), [AppActivity.background]);

      lifecycle(tester, [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      expect(told(harness), [AppActivity.background, AppActivity.foreground]);
    });

    testWidgets('a phone app already out of sight says so as it '
        'mounts', (tester) async {
      lifecycle(tester, [AppLifecycleState.inactive, AppLifecycleState.hidden]);
      final harness = await pumpApp(tester, size: _phone);
      expect(told(harness), [AppActivity.background]);
    });

    testWidgets('a minimized desktop app stays in the foreground', (
      tester,
    ) async {
      final harness = await pumpApp(tester, size: _desktop);
      lifecycle(tester, [AppLifecycleState.inactive, AppLifecycleState.hidden]);
      expect(told(harness), isEmpty);
    }, variant: TargetPlatformVariant.desktop());
  });
}
