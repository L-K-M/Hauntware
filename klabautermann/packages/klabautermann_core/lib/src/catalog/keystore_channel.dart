import 'dart:async';
import 'dart:typed_data';

import '../engine/protocol.dart';
import 'sync_credentials.dart' show SyncKeystore;

/// The app refused a keystore write the engine asked for (03 §4.5).
final class SyncKeystoreRefusedException implements Exception {
  const SyncKeystoreRefusedException(this.detail);

  final String detail;

  @override
  String toString() => 'SyncKeystoreRefusedException: $detail';
}

/// The engine's [SyncKeystore] over the protocol (03 §10.1, D62): each call
/// goes out as a [KeystoreRequest] and completes with the app's
/// [AnswerKeystore], since the keystore plugin answers only the app's root
/// isolate. Reads that come back refused or of the wrong shape read as
/// none, as the port's contract asks; writes that do throw.
final class ChannelSyncKeystore implements SyncKeystore {
  ChannelSyncKeystore(this._emit);

  final void Function(EngineEvent event) _emit;
  final Map<int, Completer<KeystoreResult>> _waiting = {};
  var _nextRequestId = 0;

  /// Completes the call [answer] names. An answer nobody waits for, such
  /// as a second one for the same request, is dropped.
  void answer(AnswerKeystore answer) =>
      _waiting.remove(answer.requestId)?.complete(answer.result);

  Future<KeystoreResult> _ask(KeystoreOperation operation) {
    final requestId = _nextRequestId++;
    final answer = Completer<KeystoreResult>();
    _waiting[requestId] = answer;
    _emit(KeystoreRequest(requestId, operation));
    return answer.future;
  }

  Future<void> _write(KeystoreOperation operation) async {
    switch (await _ask(operation)) {
      case KeystoreDone():
        return;
      case KeystoreRefused(:final detail):
        throw SyncKeystoreRefusedException(detail);
      case final other:
        throw SyncKeystoreRefusedException('unexpected answer $other');
    }
  }

  @override
  Future<void> putApiKey(String name, String value) =>
      _write(KeystorePutApiKey(name, value));

  @override
  Future<String?> getApiKey(String name) async =>
      switch (await _ask(KeystoreGetApiKey(name))) {
        KeystoreApiKey(:final value) => value,
        _ => null,
      };

  /// Completes whatever the app answers: sign-out must finish while the
  /// keystore is down.
  @override
  Future<void> deleteApiKey(String name) async {
    await _ask(KeystoreDeleteApiKey(name));
  }

  @override
  Future<List<int>?> readMasterKey() async =>
      switch (await _ask(const KeystoreReadMasterKey())) {
        KeystoreMasterKey(:final key) => key,
        _ => null,
      };

  @override
  Future<void> writeMasterKey(List<int> key) =>
      _write(KeystoreWriteMasterKey(Uint8List.fromList(key)));
}
