import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/connection_status_controller.dart';
import 'package:poltergeist_app/ui/connections/connections_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../../app/poltergeist_app/test/support/fake_bookmark_store.dart';
import '../../../app/poltergeist_app/test/support/fake_connection_state_bridge.dart';

// Isolated evidence harness; product source stays at the reviewed head.
class _HeldRoute extends MaterialPageRoute<void> {
  _HeldRoute({required super.builder});
  final decision = Completer<RoutePopDisposition>();
  @override
  Future<RoutePopDisposition> willPop() => decision.future;
}

void main() {
  late FakeConnectionStateBridge bridge;
  late ConnectionStatusController controller;
  late NavigatorState navigator;
  late MaterialPageRoute<void> route;
  late List<String> opened;

  setUp(() {
    bridge = FakeConnectionStateBridge();
    final now = DateTime.utc(2026, 9, 13);
    final store = FakeBookmarkStore()..bookmarks = [Bookmark(
      id: 'a', kind: BookmarkKind.remotePath, label: 'web',
      server: BookmarkServerRef(identity: EmbeddedHostIdentity(
        host: 'web.example.com', port: 2222, username: 'deploy',
        authMethod: AuthMethod.password,
      )), remotePath: '/', sortKey: 'a', createdAt: now, updatedAt: now,
    )];
    controller = ConnectionStatusController(bookmarks: store, bridge: bridge);
    opened = [];
  });
  tearDown(() async {
    controller.dispose();
    await bridge.close();
  });

  Future<void> mount(WidgetTester tester,
      MaterialPageRoute<void> Function(WidgetBuilder) makeRoute) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: Text('shell')),
    ));
    navigator = tester.state<NavigatorState>(find.byType(Navigator));
    route = makeRoute((_) => ConnectionsView(controller,
      onOpenInPane: (server) => opened.add(server.serverId)));
    unawaited(navigator.push<void>(route));
    await controller.loadServers();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('connection.open.a')), findsOneWidget);
    expect(route.isCurrent, isTrue);
    expect(route.isActive, isTrue);
  }

  testWidgets('animated pop opens before disposal while isActive is false', (tester) async {
    await mount(tester, (builder) => MaterialPageRoute<void>(builder: builder));
    await tester.tap(find.byKey(const ValueKey('connection.open.a')));
    await tester.pump();
    expect(opened, ['a']);
    expect(route.isActive, isFalse);
    expect(route.isCurrent, isFalse);
    expect(route.navigator, same(navigator), reason: 'not disposed yet');
    expect(route.animation!.status, AnimationStatus.reverse);
    expect(route.animation!.value, greaterThan(0));
    await tester.pumpAndSettle();
    expect(find.text('shell'), findsOneWidget);
  });

  testWidgets('PopScope veto stays active and never opens', (tester) async {
    await mount(tester, (builder) => MaterialPageRoute<void>(
      builder: (context) => PopScope(canPop: false, child: builder(context))));
    await tester.tap(find.byKey(const ValueKey('connection.open.a')));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(route.isActive, isTrue);
    expect(route.isCurrent, isTrue);
  });

  testWidgets('local history consumes first pop; second opens the pane', (tester) async {
    await mount(tester, (builder) => MaterialPageRoute<void>(builder: builder));
    var removed = 0;
    route.addLocalHistoryEntry(LocalHistoryEntry(onRemove: () => removed++));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('connection.open.a')));
    await tester.pumpAndSettle();
    expect(removed, 1);
    expect(opened, isEmpty);
    expect(route.isActive, isTrue);
    expect(route.isCurrent, isTrue);
    await tester.tap(find.byKey(const ValueKey('connection.open.a')));
    await tester.pump();
    expect(opened, ['a']);
    expect(route.isActive, isFalse);
    await tester.pumpAndSettle();
  });

  testWidgets('covering route during maybePop preserves both routes and does not open', (tester) async {
    await mount(tester, (builder) => _HeldRoute(builder: builder));
    final held = route as _HeldRoute;
    await tester.tap(find.byKey(const ValueKey('connection.open.a')));
    await tester.pump();
    expect(opened, isEmpty);
    final covering = MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('covering')));
    unawaited(navigator.push<void>(covering));
    await tester.pumpAndSettle();
    held.decision.complete(RoutePopDisposition.pop);
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(route.isActive, isTrue);
    expect(route.isCurrent, isFalse, reason: 'isCurrent would wrongly permit opening');
    expect(covering.isCurrent, isTrue);
    expect(find.text('covering'), findsOneWidget);
  });
}
