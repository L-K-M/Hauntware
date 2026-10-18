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

/// A round whose pull holds a conflicting pin back and which *then* fails
/// must still put the conflict in front of the user (Séance #56): the
/// store keeps refusing the pulled key, so a push that keeps failing would
/// otherwise hide the decision for good.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppServices services;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-pin-sync-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (call) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
    services.settings.syncBaseUrl = _baseUrl;
    await services.masterKeys.putApiKey('sync.token', 'session-token');
  });

  tearDown(() async {
    await services.probe.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    await directory.delete(recursive: true);
  });

  test(
    'a round that holds a pin back and then fails still raises it',
    () async {
      const local = HostKey(
        host: 'alpha.example.com',
        type: 'ssh-ed25519',
        fingerprintSha256: 'SHA256:k1',
        pinnedAt: 10,
      );
      const pulled = HostKey(
        host: 'alpha.example.com',
        type: 'ssh-ed25519',
        fingerprintSha256: 'SHA256:k2',
        pinnedAt: 20,
      );
      await services.hostKeyStore.put(local);
      // A server this device keeps off the account: the copy arriving for it
      // is outranked and re-dated, which sends the coordinator back for a
      // pass that fails here, after the pin was held back.
      const excluded = ServerConfig(
        id: 'excluded-server',
        label: 'local only',
        host: 'local.example.com',
        username: 'me',
        excludeFromSync: true,
        createdAt: 100,
        updatedAt: 100,
      );
      await services.configStore.putServer(excluded);

      final codec = RecordCodec(services.vaultKey!);
      final records = [
        await codec.encrypt(
          DecryptedRecord(
            id: pulled.recordId,
            kind: RecordKind.hostKey,
            updatedAt: 500,
            deviceId: 'other-device',
            data: pulled.toJson(),
          ),
        ),
        await codec.encrypt(
          DecryptedRecord(
            id: excluded.id,
            kind: RecordKind.serverConfig,
            updatedAt: 500,
            deviceId: 'other-device',
            data: excluded.copyWith(label: 'from the account').toJson(),
          ),
        ),
      ];
      var gets = 0;
      final transport = MockClient((request) async {
        if (request.method == 'GET') {
          gets++;
          if (gets >= 3) {
            return http.Response('down', HttpStatus.internalServerError);
          }
          return http.Response(
            jsonEncode(
              PullResponse(
                records: gets == 1
                    ? [
                        for (var i = 0; i < records.length; i++)
                          records[i].withSeq(i + 1),
                      ]
                    : const [],
                latestSeq: records.length,
              ).toJson(),
            ),
            HttpStatus.ok,
          );
        }
        return http.Response(
          jsonEncode(
            PushResponse(results: const [], latestSeq: records.length).toJson(),
          ),
          HttpStatus.ok,
        );
      });

      final state = AppState(services);
      addTearDown(state.dispose);
      await http.runWithClient(
        () => expectLater(state.syncNow(), throwsA(isA<ApiError>())),
        () => transport,
      );

      expect(gets, greaterThanOrEqualTo(3));
      expect(
        (await services.hostKeyStore.get(
          'alpha.example.com',
          22,
        ))?.fingerprintSha256,
        'SHA256:k1',
      );
      expect(
        services.pinConflicts.single.pulled.fingerprintSha256,
        'SHA256:k2',
      );
    },
  );
}
