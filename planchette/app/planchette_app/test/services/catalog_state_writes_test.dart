import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/services/workspace_catalog.dart';

// The catalog state's changes run one at a time, each from what the last
// one committed, as the siblings' stores do: overlapping changes no longer
// both start from one state, so neither drops the other's.
void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('planchette-catalog-');
    file = File('${directory.path}/state.json');
  });

  tearDown(() => directory.delete(recursive: true));

  test('overlapping tripwire changes keep both', () async {
    final state = debugCatalogState(file);
    await state.load();

    await Future.wait([state.tripwires.trip('a'), state.tripwires.trip('b')]);

    expect(await state.tripwires.trippedIds(), {'a', 'b'});
    final reopened = debugCatalogState(file);
    await reopened.load();
    expect(await reopened.tripwires.trippedIds(), {'a', 'b'});
  });

  test('overlapping pin changes keep both', () async {
    final state = debugCatalogState(file);
    await state.load();

    await Future.wait([
      state.pins.addNegativePin('host-a'),
      state.pins.addNegativePin('host-b'),
    ]);

    final stored = jsonDecode(await file.readAsString()) as Map;
    expect(stored['negativePins'], ['host-a', 'host-b']);
  });

  test('two first device-id reads agree on one id', () async {
    final state = debugCatalogState(file);
    await state.load();

    final ids = await Future.wait([
      state.enrollment.deviceId(),
      state.enrollment.deviceId(),
    ]);

    expect(ids.toSet(), hasLength(1));
    final stored = jsonDecode(await file.readAsString()) as Map;
    expect(stored['deviceId'], ids.first);
  });
}
