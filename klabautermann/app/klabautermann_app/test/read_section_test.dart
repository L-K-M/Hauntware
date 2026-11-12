// The shared read-section mixins: a host read lands only for the newest
// read and starts over on a server switch; an admin read runs once per
// server and forgets its report on a switch.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/admin_controller.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/ui/read_section.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _a = 'srv-a';
const _b = 'srv-b';

class _HostProbe extends StatefulWidget implements HostReadSection {
  const _HostProbe({required this.monitoring, required this.serverId});

  @override
  final MonitoringController monitoring;

  @override
  final String serverId;

  @override
  State<_HostProbe> createState() => _HostProbeState();
}

class _HostProbeState extends State<_HostProbe>
    with HostReadSectionState<_HostProbe> {
  @override
  HostQuerySpec get hostQuery => const OomKillsQuery();

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(switch (hostRead) {
        null => 'none',
        HostQueryFailed(:final failure) => 'failed ${failure.name}',
        _ => 'read',
      }),
      Text(hostReading ? 'reading' : 'idle'),
      TextButton(onPressed: readHost, child: const Text('again')),
    ],
  );
}

class _AdminProbe extends StatefulWidget implements AdminReadSection {
  const _AdminProbe({
    required this.admin,
    required this.serverId,
    required this.reads,
  });

  final AdminController admin;

  @override
  final String serverId;
  final Map<String, Completer<String>> reads;

  @override
  State<_AdminProbe> createState() => _AdminProbeState();
}

class _AdminProbeState extends State<_AdminProbe>
    with AdminReadSectionState<_AdminProbe, String> {
  @override
  Future<String> readReport(AdminController admin, String serverId) =>
      (widget.reads[serverId] = Completer<String>()).future;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(adminReport ?? 'no report'),
      Text(adminReading ? 'reading' : 'idle'),
      TextButton(
        onPressed: () => unawaited(readAdmin(widget.admin)),
        child: const Text('read'),
      ),
    ],
  );
}

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

  List<HostQuery> queries() =>
      engine.sentOfType<HostQuery>().cast<HostQuery>().toList();

  Future<void> answer(WidgetTester tester, HostQuery query) async {
    engine.emit(
      HostResult(
        serverId: query.serverId,
        queryId: query.queryId,
        payload: const HostQueryFailed(HostQueryFailure.denied),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a host read lands only for the newest read', (tester) async {
    final serverId = ValueNotifier(_a);
    addTearDown(serverId.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder(
          valueListenable: serverId,
          builder: (context, id, _) =>
              _HostProbe(monitoring: monitoring, serverId: id),
        ),
      ),
    );
    expect(queries().single.serverId, _a);
    expect(queries().single.query, isA<OomKillsQuery>());
    expect(find.text('reading'), findsOne);

    serverId.value = _b;
    await tester.pump();
    expect(queries().map((query) => query.serverId), [_a, _b]);

    // The first server's late answer is dropped.
    await answer(tester, queries().first);
    expect(find.text('none'), findsOne);
    expect(find.text('reading'), findsOne);

    await answer(tester, queries().last);
    expect(find.text('failed denied'), findsOne);
    expect(find.text('idle'), findsOne);

    await tester.tap(find.text('again'));
    await tester.pump();
    expect(queries(), hasLength(3));
    expect(find.text('reading'), findsOne);
    // The answer held stays in view while it reads again.
    expect(find.text('failed denied'), findsOne);
  });

  testWidgets('an admin read runs once per server and forgets on a switch', (
    tester,
  ) async {
    final admin = AdminController(engine);
    addTearDown(admin.dispose);
    final reads = <String, Completer<String>>{};
    final serverId = ValueNotifier(_a);
    addTearDown(serverId.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder(
          valueListenable: serverId,
          builder: (context, id, _) =>
              _AdminProbe(admin: admin, serverId: id, reads: reads),
        ),
      ),
    );

    await tester.tap(find.text('read'));
    await tester.pump();
    final first = reads[_a]!;
    await tester.tap(find.text('read'));
    await tester.pump();
    expect(identical(reads[_a], first), isTrue, reason: 'no second read');
    expect(find.text('reading'), findsOne);

    reads[_a]!.complete('report a');
    await tester.pump();
    expect(find.text('report a'), findsOne);

    // A switch forgets the report; a read out for the other server still
    // shows once the section is back on it, and lands only there.
    serverId.value = _b;
    await tester.pump();
    expect(find.text('no report'), findsOne);
    await tester.tap(find.text('read'));
    await tester.pump();
    serverId.value = _a;
    await tester.pump();
    expect(find.text('idle'), findsOne);
    reads[_b]!.complete('report b');
    await tester.pump();
    expect(find.text('no report'), findsOne);
    serverId.value = _b;
    await tester.pump();
    expect(find.text('no report'), findsOne);
    expect(find.text('idle'), findsOne);
  });
}
