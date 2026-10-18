// `operations_shown.json` (03 §4.10, M4 E17b): the notes round-trip, a
// damaged file is set aside and the store starts empty, and an unguarded
// support directory is never written.
import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/catalog/sync_state_file.dart'
    show SyncStateIssueKind;
import 'package:klabautermann_core/src/operations/operations_shown.dart';
import 'package:test/test.dart';

void main() {
  late Directory support;
  late File file;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('klab-ops-shown-');
    addTearDown(() => support.delete(recursive: true));
    file = File('${support.path}/$operationsShownFileName');
  });

  Future<OperationsShownStore> open([
    SupportDirectoryAccess access = SupportDirectoryAccess.exclusive,
  ]) => OperationsShownStore.open(support, access: access);

  test('notes round-trip, launch facts included', () async {
    final store = await open();
    await store.put(
      'srv-1',
      '00000000000000d0',
      OperationNote(
        directory: OpDirectoryKind.root,
        launch: OperationLaunch(
          action: 'RedeployStack',
          targetName: 'web',
          steps: ['docker compose pull'],
          tier: ConfirmationTier.acknowledge,
          startedAt: DateTime.utc(2026, 10, 18, 9),
        ),
      ),
    );
    await store.put(
      'srv-1',
      '00000000000000a1',
      const OperationNote(directory: OpDirectoryKind.user, acknowledged: true),
    );

    final notes = (await open()).notesOf('srv-1');
    expect(
      notes.keys,
      unorderedEquals(['00000000000000d0', '00000000000000a1']),
    );
    final launched = notes['00000000000000d0']!;
    expect(launched.directory, OpDirectoryKind.root);
    expect(launched.acknowledged, isFalse);
    expect(launched.launch?.action, 'RedeployStack');
    expect(launched.launch?.steps, ['docker compose pull']);
    expect(launched.launch?.tier, ConfirmationTier.acknowledge);
    expect(launched.launch?.startedAt, DateTime.utc(2026, 10, 18, 9));
    expect(notes['00000000000000a1']?.acknowledged, isTrue);
    expect(notes['00000000000000a1']?.launch, isNull);

    final reopened = await open();
    await reopened.remove('srv-1', ['00000000000000d0', '00000000000000a1']);
    expect((await open()).notesOf('srv-1'), isEmpty);
    expect(jsonDecode(await file.readAsString()), {
      'version': 1,
      'servers': <String, Object?>{},
    });
  });

  test('a damaged file is set aside and the store starts empty', () async {
    await file.writeAsString('{"version": 1, "servers": {"srv-1": 3}}');
    final store = await open();
    expect(store.notesOf('srv-1'), isEmpty);
    expect(store.issue?.kind, SyncStateIssueKind.recovered);
    expect(await file.exists(), isFalse);
  });

  test('an unguarded support directory is read but never written', () async {
    final store = await open(SupportDirectoryAccess.unguarded);
    await store.put(
      'srv-1',
      '00000000000000d0',
      const OperationNote(directory: OpDirectoryKind.user),
    );
    expect(store.notesOf('srv-1'), hasLength(1));
    expect(await file.exists(), isFalse);
  });
}
