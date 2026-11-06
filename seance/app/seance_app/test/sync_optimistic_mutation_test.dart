import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_core/seance_core.dart';

const _baseUrl = 'https://sync.test';
const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

MockClient _currentServerClient(
  Future<http.Response> Function(http.Request) handler,
) {
  return MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/v1/records/legacy') {
      return http.Response(
        jsonEncode(
          const LegacyRecordPage(
            records: [],
            nextId: null,
            hasMore: false,
            recordEnvelopeFloor: kCurrentRecordEnvelopeVersion,
          ).toJson(),
        ),
        HttpStatus.ok,
      );
    }
    return handler(request);
  });
}

ServerConfig _server(String id, int updatedAt, {String? label}) => ServerConfig(
  id: id,
  label: label ?? id,
  host: '$id.example.com',
  username: 'deploy',
  createdAt: 1,
  updatedAt: updatedAt,
);

class _SyncServer {
  _SyncServer(EncryptedRecord seed) {
    _store[seed.id] = seed.withSeq(++_seq);
    client = _currentServerClient(_handle);
  }

  final Map<String, EncryptedRecord> _store = {};
  final firstPullStarted = Completer<void>();
  final releaseFirstPull = Completer<void>();
  late final MockClient client;
  Future<void> Function(int attempt)? beforeInitialPull;
  bool blockFirstPull = false;
  int initialPulls = 0;
  int pulls = 0;
  int _seq = 0;

  EncryptedRecord? stored(String id) => _store[id];

  Future<http.Response> _handle(http.Request request) async {
    if (request.method == 'GET') {
      pulls++;
      final since = int.parse(request.url.queryParameters['since'] ?? '0');
      if (since == 0) {
        initialPulls++;
        if (!firstPullStarted.isCompleted) firstPullStarted.complete();
        await beforeInitialPull?.call(initialPulls);
        if (blockFirstPull && initialPulls == 1) {
          await releaseFirstPull.future;
        }
      }
      final records =
          _store.values.where((record) => (record.seq ?? 0) > since).toList()
            ..sort((a, b) => a.seq!.compareTo(b.seq!));
      return http.Response(
        jsonEncode(
          PullResponse(
            records: records,
            latestSeq: _seq,
            recordEnvelopeFloor: kCurrentRecordEnvelopeVersion,
          ).toJson(),
        ),
        HttpStatus.ok,
      );
    }

    final push = PushRequest.fromJson(
      jsonDecode(request.body) as Map<String, dynamic>,
    );
    final results = <PushResult>[];
    for (final incoming in push.records) {
      final existing = _store[incoming.id];
      final accepted =
          existing == null ||
          identical(Lww.resolve(existing, incoming), incoming);
      if (accepted) {
        final stored = incoming.withSeq(++_seq);
        _store[incoming.id] = stored;
        results.add(
          PushResult(id: incoming.id, seq: stored.seq!, accepted: true),
        );
      } else {
        results.add(
          PushResult(id: incoming.id, seq: existing.seq!, accepted: false),
        );
      }
    }
    return http.Response(
      jsonEncode(PushResponse(results: results, latestSeq: _seq).toJson()),
      HttpStatus.ok,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppServices services;
  late AppState state;
  late EncryptedRecord remoteSeed;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-sync-phase-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (call) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
    services.settings
      ..syncBaseUrl = _baseUrl
      ..syncUsername = 'user'
      ..autoSync = false;
    await services.masterKeys.putApiKey('sync.token', 'session-token');
    state = AppState(services);
    remoteSeed = await RecordCodec(services.vaultKey!).encrypt(
      DecryptedRecord(
        id: 'remote',
        kind: RecordKind.serverConfig,
        updatedAt: 1,
        deviceId: 'remote-device',
        data: _server('remote', 1).toJson(),
      ),
    );
  });

  tearDown(() async {
    state.dispose();
    await services.probe.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    await directory.delete(recursive: true);
  });

  test('a blocked pull does not block a save or deletion', () async {
    await state.saveServer(_server('old', 10));
    final remote = _SyncServer(remoteSeed)..blockFirstPull = true;

    final syncing = http.runWithClient(state.syncNow, () => remote.client);
    await remote.firstPullStarted.future;

    await state
        .saveServer(_server('new', 20))
        .timeout(const Duration(seconds: 1));
    await state.deleteServer('old').timeout(const Duration(seconds: 1));
    remote.releaseFirstPull.complete();
    await syncing;

    expect(await services.configStore.getServer('old'), isNull);
    expect(await services.configStore.getServer('new'), isNotNull);
    // The durable coordinator preserves concurrent local edits for the next
    // delta round instead of restarting its full pull.
    await http.runWithClient(state.syncNow, () => remote.client);
    expect(remote.stored('old')!.deleted, isTrue);
    expect(remote.stored('new')!.deleted, isFalse);
  });

  test(
    'a manual round preserves an auto-sync queued while it was blocked',
    () async {
      services.settings.autoSync = true;
      final remote = _SyncServer(remoteSeed)..blockFirstPull = true;
      final syncing = http.runWithClient(state.syncNow, () => remote.client);
      await remote.firstPullStarted.future;

      await state.saveServer(_server('late-edit', 30));
      // Let the edit's debounce fire while the manual round still owns the
      // shared sync indicator. It should queue, not disappear with that round.
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      remote.releaseFirstPull.complete();
      await syncing;
      final pullsAfterManual = remote.pulls;
      final deadline = DateTime.now().add(const Duration(seconds: 4));
      while (remote.pulls == pullsAfterManual && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(remote.pulls, greaterThan(pullsAfterManual));
      while (state.syncing && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(state.syncing, isFalse, reason: 'the queued round completed');
    },
  );

  test(
    'an export waiting behind sync does not hold the mutation queue',
    () async {
      await state.saveRecoveryCode(state.newRecoveryCode());
      final remote = _SyncServer(remoteSeed)..blockFirstPull = true;
      final syncing = http.runWithClient(state.syncNow, () => remote.client);
      await remote.firstPullStarted.future;

      final exporting = state.exportSecrets();
      await Future<void>.delayed(Duration.zero);
      await state
          .saveServer(_server('while-export-waits', 30))
          .timeout(const Duration(seconds: 1));

      remote.releaseFirstPull.complete();
      await syncing;
      expect(await exporting, isNotEmpty);
      expect(
        await services.configStore.getServer('while-export-waits'),
        isNotNull,
      );
    },
  );
}
