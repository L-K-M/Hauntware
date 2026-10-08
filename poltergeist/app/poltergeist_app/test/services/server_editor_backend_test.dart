import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/bookmark_backup_service.dart';
import 'package:poltergeist_app/services/atomic_file.dart';
import 'package:poltergeist_app/services/identity_file_reader.dart';
import 'package:poltergeist_app/services/server_editor_backend.dart';
import 'package:poltergeist_app/services/transfer_limits_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_sync_backup.dart';

const _targetSecretId = 'target-secret';
const _oldHopSecretId = 'old-hop-secret';
const _newHopSecretId = 'new-hop-secret';

ServerConfig _server(String id, {String? jumpHostId, String? secretRef}) =>
    ServerConfig(
      id: id,
      label: id,
      host: '$id.example.com',
      username: 'deploy',
      authMethod: AuthMethod.password,
      secretRef: secretRef,
      jumpHostId: jumpHostId,
      createdAt: 1,
      updatedAt: 1,
    );

final class _ScriptedVault extends SecretVault {
  _ScriptedVault() : super(InMemoryVaultStore(), const []);

  final reads = <String>[];
  Future<Secret?> Function(String id)? onRead;

  @override
  Future<Secret?> getSecret(String id) async {
    reads.add(id);
    return onRead?.call(id);
  }
}

final class _RecordingIdentityReader extends IdentityFileReader {
  _RecordingIdentityReader() : super(IdentityAuditLog(
          File('unused'),
          rewriteOwnerOnly: writeOwnerOnlyAtomically,
        ));

  final reads = <String>[];

  @override
  Future<String> read({
    required String serverId,
    required String serverLabel,
    required String identityFilePath,
  }) async {
    reads.add(identityFilePath);
    return 'PRIVATE KEY';
  }
}

final class _BackupHarness {
  _BackupHarness(List<ServerConfig> configs)
      : servers = FakeSyncTrackingServerStore(configs);

  final server = FakeSyncServer();
  final transports = <FakeSyncTransport>[];
  final credentials = FakeSyncCredentialStore();
  final retained = FakeRetainedSyncTokenStore();
  final state = FakeSyncEnrollmentState();
  final bookmarks = FakeSyncTrackingBookmarkStore();
  final FakeSyncTrackingServerStore servers;
  final vaultStore = InMemoryVaultStore();
  final hostKeys = InMemoryConflictAwareHostKeyStore();
  final pinVerdicts = InMemoryPinVerdictStore();
  final tripwires = InMemorySyncTripwireStore();
  var records = InMemorySyncRecordStore();

  late final service = BookmarkBackupService(
    credentials: credentials,
    retainedTokens: retained,
    enrollmentState: state,
    records: records,
    resetRecords: () async => records = InMemorySyncRecordStore(),
    bookmarks: bookmarks,
    hostKeys: hostKeys,
    pinVerdicts: pinVerdicts,
    tripwires: tripwires,
    transportFactory: fakeTransportFactory(server, transports),
    vaultKey: () async => credentials.vaultKey,
    servers: servers,
    vaultStore: vaultStore,
  );

  Future<void> load() async {
    state.enrolled = const SyncAccount(
      baseUrl: 'https://sync.example',
      username: 'fleet',
      mode: SyncAccountMode.shared,
    );
    credentials.token = 'token';
    credentials.vaultKey = List.filled(32, 9);
    await service.load();
  }
}

ServerEditorBackend _backend(
  BookmarkBackupService backups,
  _ScriptedVault vault,
  _RecordingIdentityReader identityReader,
) =>
    ServerEditorBackend(
      backups: backups,
      vault: vault,
      hostKeys: InMemoryHostKeyStore(),
      identityReader: identityReader,
      navigatorKey: GlobalKey<NavigatorState>(),
      transferLimits: TransferLimitsController(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('invalid jump route reads no credential', () async {
    final target = _server(
      'target',
      jumpHostId: 'missing',
      secretRef: _targetSecretId,
    );
    final backups = _BackupHarness(const []);
    await backups.load();
    final vault = _ScriptedVault()
      ..onRead = (id) async =>
          Secret(id: id, kind: SecretKind.password, value: 'password');
    final identityReader = _RecordingIdentityReader();

    final result = await _backend(
      backups.service,
      vault,
      identityReader,
    ).testConnection(target);

    expect(result.ok, isFalse);
    expect(result.summary, 'Jump host “missing” is missing.');
    expect(vault.reads, isEmpty);
    expect(identityReader.reads, isEmpty);
  });

  test('invalid jump route reads no identity file', () async {
    final target = ServerConfig(
      id: 'target',
      label: 'target',
      host: 'target.example.com',
      username: 'deploy',
      authMethod: AuthMethod.privateKey,
      identityFilePath: '/keys/target',
      jumpHostId: 'missing',
      createdAt: 1,
      updatedAt: 1,
    );
    final backups = _BackupHarness(const []);
    await backups.load();
    final identityReader = _RecordingIdentityReader();

    final result = await _backend(
      backups.service,
      _ScriptedVault(),
      identityReader,
    ).testConnection(target);

    expect(result.ok, isFalse);
    expect(identityReader.reads, isEmpty);
  });

  test('cyclic jump route reads no credential', () async {
    final target = _server(
      'target',
      jumpHostId: 'hop',
      secretRef: _targetSecretId,
    );
    final backups = _BackupHarness([
      _server('hop', jumpHostId: 'target', secretRef: _oldHopSecretId),
    ]);
    await backups.load();
    final vault = _ScriptedVault();

    final result = await _backend(
      backups.service,
      vault,
      _RecordingIdentityReader(),
    ).testConnection(target);

    expect(result.ok, isFalse);
    expect(
      result.summary,
      'The jump-host route contains a cycle at “target”.',
    );
    expect(vault.reads, isEmpty);
  });

  test('overlong jump route reads no credential', () async {
    final hops = [
      for (var index = 0; index < 17; index++)
        _server(
          'hop-$index',
          jumpHostId: index == 16 ? null : 'hop-${index + 1}',
          secretRef: 'secret-$index',
        ),
    ];
    final target = _server(
      'target',
      jumpHostId: hops.first.id,
      secretRef: _targetSecretId,
    );
    final backups = _BackupHarness(hops);
    await backups.load();
    final vault = _ScriptedVault();

    final result = await _backend(
      backups.service,
      vault,
      _RecordingIdentityReader(),
    ).testConnection(target);

    expect(result.ok, isFalse);
    expect(result.summary, 'The jump-host route exceeds 16 hops.');
    expect(vault.reads, isEmpty);
  });

  test('jump route uses one catalog snapshot', () async {
    final target = _server(
      'target',
      jumpHostId: 'hop',
      secretRef: _targetSecretId,
    );
    final oldHop = _server('hop', secretRef: _oldHopSecretId);
    final newHop = _server('hop', secretRef: _newHopSecretId);
    final backups = _BackupHarness([oldHop]);
    await backups.load();
    final vault = _ScriptedVault()
      ..onRead = (id) async {
        if (id == _targetSecretId) {
          backups.service.catalog!.replace([newHop]);
          return const Secret(
            id: _targetSecretId,
            kind: SecretKind.password,
            value: 'password',
          );
        }
        if (id == _oldHopSecretId) throw StateError('old snapshot');
        throw StateError('changed snapshot');
      };

    final result = await _backend(
      backups.service,
      vault,
      _RecordingIdentityReader(),
    ).testConnection(target);

    expect(result.ok, isFalse);
    expect(result.summary, contains('old snapshot'));
    expect(vault.reads, [_targetSecretId, _oldHopSecretId]);
  });
}
