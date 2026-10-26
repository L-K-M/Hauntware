// CPU-07: the System tab's processor section, its model and counts, the
// counts a container withholds, and a server switch.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/processor.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _server = 'srv-1';

CpuTopology _cpu({List<String> models = const ['AMD EPYC 7763']}) =>
    CpuTopology(
      models: models,
      vendor: 'AuthenticAMD',
      logicalCpus: 16,
      usableCpus: 4,
      sockets: 2,
      cores: 8,
      threadsPerCore: 2,
    );

/// The facts as `label=value` (`label=?` while unknown) and their notes.
final _shown = <String>[];

Widget _fact(String label, String? value, {String? note}) {
  _shown.add('$label=${value ?? '?'}${note == null ? '' : ' ($note)'}');
  return Text('$label: ${value ?? '?'}');
}

void main() {
  late FakeEngineClient engine;
  late MonitoringController monitoring;

  setUp(() {
    engine = FakeEngineClient();
    monitoring = MonitoringController(engine);
    _shown.clear();
  });

  tearDown(() async {
    monitoring.dispose();
    await engine.close();
  });

  Future<void> pump(
    WidgetTester tester, {
    String server = _server,
    bool inContainer = false,
  }) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProcessorSection(
            monitoring: monitoring,
            serverId: server,
            inContainer: inContainer,
            fact: _fact,
          ),
        ),
      ),
    ),
  );

  List<HostQuery> queries() =>
      engine.sentOfType<HostQuery>().cast<HostQuery>().toList();

  Future<void> answer(
    WidgetTester tester,
    HostPayload payload, {
    HostQuery? query,
  }) async {
    final asked = query ?? queries().last;
    engine.emit(
      HostResult(
        serverId: asked.serverId,
        queryId: asked.queryId,
        payload: payload,
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('shows the model and counts, and reads again on request', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Reading the processor…'), findsOne);
    expect(queries().single.query, isA<CpuTopologyQuery>());

    _shown.clear();
    await answer(tester, CpuTopologyRead(_cpu()));
    expect(_shown, [
      'Model=AMD EPYC 7763',
      'Sockets=2',
      'Cores=8',
      'Threads per core=2',
      'Logical CPUs=16',
      'Usable CPUs=4',
    ]);

    await tester.tap(find.text('Read again'));
    await tester.pump();
    expect(queries(), hasLength(2));
  });

  testWidgets('a container withholds the host machine\'s counts', (
    tester,
  ) async {
    await pump(tester, inContainer: true);
    _shown.clear();
    await answer(tester, CpuTopologyRead(_cpu()));
    const why =
        'Inside this container this figure would be the host\'s, so it is '
        'not shown.';
    expect(_shown, [
      'Model=AMD EPYC 7763',
      'Sockets=? ($why)',
      'Cores=? ($why)',
      'Threads per core=2',
      'Logical CPUs=? ($why)',
      'Usable CPUs=4',
    ]);
  });

  testWidgets('a processor without a model name shows its vendor', (
    tester,
  ) async {
    await pump(tester);
    _shown.clear();
    await answer(tester, CpuTopologyRead(_cpu(models: const [])));
    expect(_shown.first, 'Model=AuthenticAMD');

    await tester.tap(find.text('Read again'));
    await tester.pump();
    _shown.clear();
    await answer(
      tester,
      CpuTopologyRead(CpuTopology(models: const [], logicalCpus: 4)),
    );
    expect(
      _shown.first,
      'Model=? (This processor does not report a model name, as is common '
      'on ARM boards.)',
    );
  });

  testWidgets('a failed read says why', (tester) async {
    await pump(tester);
    await answer(tester, const HostQueryFailed(HostQueryFailure.noLink));
    expect(find.text('Not connected to the server.'), findsOne);
  });

  testWidgets('a server switch reads the new server\'s and drops the old', (
    tester,
  ) async {
    await pump(tester);
    final first = queries().single;
    await pump(tester, server: 'srv-2');
    expect(queries(), hasLength(2));
    expect(queries().last.serverId, 'srv-2');

    _shown.clear();
    await answer(tester, CpuTopologyRead(_cpu()), query: first);
    expect(_shown, isEmpty);
    expect(find.text('Reading the processor…'), findsOne);
  });
}
