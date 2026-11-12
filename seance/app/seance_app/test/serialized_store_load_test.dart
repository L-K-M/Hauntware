import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/inbox_stores.dart';
import 'package:seance_core/catalog.dart' show SyncAccountScope;
import 'package:seance_core/seance_core.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('serialized-store-load-');
  });

  tearDown(() => directory.delete(recursive: true));

  test('a cold status read loads the committed status', () async {
    final file = File('${directory.path}/statuses.json');
    final status = InboxStatus(
      appId: newInboxAppId(),
      proposalId: 'proposal',
      state: InboxStatusState.ran,
      updatedAt: 1,
    );
    await FileInboxStatusStore(file).putStatus(status);

    final reopened = FileInboxStatusStore(file);
    expect(
      (await reopened.getStatus(status.appId, 'proposal'))?.state,
      status.state,
    );
  });

  test('a cold cache save refuses an unsupported stored version', () async {
    final file = File('${directory.path}/cache.json');
    final original = jsonEncode({'version': 2});
    await file.writeAsString(original);
    final store = FileInboxCacheStore(
      file,
      scope: SyncAccountScope(baseUrl: 'https://sync.example', username: 'me'),
    );

    await expectLater(
      store.save(const InboxCache(cursor: 5)),
      throwsA(isA<FormatException>()),
    );
    expect(await file.readAsString(), original);
  });
}
