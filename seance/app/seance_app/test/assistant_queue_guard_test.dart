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

class _BlockingVault extends SecretVault {
  _BlockingVault(super.store, super.vaultKey);
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> putLocalSecret(Secret secret, {required int updatedAt}) async {
    entered.complete();
    await release.future;
    await super.putLocalSecret(secret, updatedAt: updatedAt);
  }
}

class _HookState extends AppState {
  _HookState(super.services);
  Future<void> Function()? beforeRefresh;
  @override
  Future<void> refreshLlmConfigured() async {
    final hook = beforeRefresh;
    beforeRefresh = null;
    await hook?.call();
    llmConfigured = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('queued opt-out precedes switch-on stamp', () async {
    final directory = await Directory.systemTemp.createTemp('assistant-queue-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
    final services = await AppServices.initialize();
    addTearDown(() async {
      await services.probe.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      FlutterSecureStorage.setMockInitialValues({});
      await directory.delete(recursive: true);
    });
    services.settings.syncBaseUrl = 'https://sync.test';
    services.settings.syncUsername = 'user';
    services.settings.syncAssistant = true;
    services.settings.autoSync = false;
    services.settings.assistantUpdatedAt = 0;
    await services.masterKeys.putApiKey('sync.token', 'session-token');
    final vault = _BlockingVault(InMemoryVaultStore(), services.vaultKey!);
    services.vault = vault;
    final state = _HookState(services);
    addTearDown(state.dispose);
    final hookReady = Completer<void>();
    late Future<void> saving;
    late Future<({bool wasSyncingAssistant, String? saveError})> optingOut;
    state.beforeRefresh = () async {
      saving = state.saveServer(
        const ServerConfig(
          id: 'held',
          label: 'held',
          host: 'held.test',
          username: 'me',
          secretRef: 'held',
          createdAt: 1,
          updatedAt: 1,
        ),
        secret: const Secret(
          id: 'held',
          kind: SecretKind.password,
          value: 'pw',
        ),
      );
      await vault.entered.future;
      optingOut = state.saveSyncPreferences(
        autoSync: false,
        syncSecrets: false,
        syncAssistant: false,
      );
      hookReady.complete();
    };
    var seq = 0;
    final client = MockClient((request) async {
      if (request.method == 'GET' && request.url.path.endsWith('/legacy')) {
        return http.Response(
          jsonEncode(
            const LegacyRecordPage(
              records: [],
              nextId: null,
              hasMore: false,
              recordEnvelopeFloor: kCurrentRecordEnvelopeVersion,
            ).toJson(),
          ),
          200,
        );
      }
      if (request.method == 'GET') {
        return http.Response(
          jsonEncode(
            PullResponse(
              records: const [],
              latestSeq: seq,
              recordEnvelopeFloor: kCurrentRecordEnvelopeVersion,
            ).toJson(),
          ),
          200,
        );
      }
      final records = PushRequest.fromJson(
        jsonDecode(request.body) as Map<String, dynamic>,
      ).records;
      return http.Response(
        jsonEncode(
          PushResponse(
            results: [
              for (final record in records)
                PushResult(id: record.id, seq: ++seq, accepted: true),
            ],
            latestSeq: seq,
          ).toJson(),
        ),
        200,
      );
    });
    await http.runWithClient(() async {
      final enabling = state.assistantSyncSwitchedOn();
      await hookReady.future;
      await Future<void>.delayed(Duration.zero);
      vault.release.complete();
      await saving;
      expect((await optingOut).saveError, isNull);
      await enabling;
    }, () => client);
    expect(services.settings.syncAssistant, isFalse);
    expect(
      services.settings.assistantUpdatedAt,
      0,
      reason: 'A queued opt-out must prevent switch-on from minting a stamp',
    );
  });
}
