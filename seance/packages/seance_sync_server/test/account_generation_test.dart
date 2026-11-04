import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

final class _Gate {
  var _armed = false;
  Completer<void>? _entered;
  Completer<void>? _release;

  void arm() {
    _armed = true;
    _entered = Completer<void>();
    _release = Completer<void>();
  }

  Future<void> get entered => _entered!.future;

  void release() => _release!.complete();

  Future<void> pauseIfArmed() async {
    if (!_armed) return;
    _armed = false;
    _entered!.complete();
    await _release!.future;
  }
}

final class _GatedMemoryStorage extends InMemoryStorage {
  final authGate = _Gate();
  final issueGate = _Gate();

  @override
  Future<AccountPrincipal?> authenticateToken(String token) async {
    final account = await super.authenticateToken(token);
    await authGate.pauseIfArmed();
    return account;
  }

  @override
  Future<AccountTokenIssueResult> issueToken(AccountPrincipal account) async {
    await issueGate.pauseIfArmed();
    return super.issueToken(account);
  }
}

final class _GatedSqliteStorage extends SqliteStorage {
  final authGate = _Gate();
  final issueGate = _Gate();

  _GatedSqliteStorage(super.database);

  @override
  Future<AccountPrincipal?> authenticateToken(String token) async {
    final account = await super.authenticateToken(token);
    await authGate.pauseIfArmed();
    return account;
  }

  @override
  Future<AccountTokenIssueResult> issueToken(AccountPrincipal account) async {
    await issueGate.pauseIfArmed();
    return super.issueToken(account);
  }
}

final class _Harness {
  final _Gate authGate;
  final _Gate issueGate;
  final Handler target;
  final Handler control;
  final Future<void> Function() close;

  _Harness({
    required this.authGate,
    required this.issueGate,
    required this.target,
    required this.control,
    required this.close,
  });
}

Future<_Harness> _openHarness(
  String backend, {
  RateLimiter? inboxLimiter,
}) async {
  const settings = ServerSettings(openRegistration: true);
  if (backend == 'in-memory') {
    final storage = _GatedMemoryStorage();
    return _Harness(
      authGate: storage.authGate,
      issueGate: storage.issueGate,
      target: SyncServer(
        storage: storage,
        settings: settings,
        inboxLimiter: inboxLimiter,
      ).handler,
      control: SyncServer(storage: storage, settings: settings).handler,
      close: () async {},
    );
  }

  final directory = await Directory.systemTemp.createTemp(
    'seance-account-generation-',
  );
  final path = '${directory.path}/sync.sqlite';
  final targetStorage = _GatedSqliteStorage(sqlite3.open(path));
  final controlStorage = SqliteStorage.open(path);
  return _Harness(
    authGate: targetStorage.authGate,
    issueGate: targetStorage.issueGate,
    target: SyncServer(
      storage: targetStorage,
      settings: settings,
      inboxLimiter: inboxLimiter,
    ).handler,
    control: SyncServer(storage: controlStorage, settings: settings).handler,
    close: () async {
      targetStorage.close();
      controlStorage.close();
      await directory.delete(recursive: true);
    },
  );
}

final class _Reply {
  final int status;
  final Map<String, dynamic> body;

  const _Reply(this.status, this.body);
}

RegisterRequest _registration(String marker) => RegisterRequest(
  username: 'alice',
  authVerifier: base64.encode(
    Uint8List.fromList(List<int>.filled(32, marker.codeUnitAt(0))),
  ),
  argonSalt: base64.encode(
    Uint8List.fromList(List<int>.filled(16, marker.codeUnitAt(0))),
  ),
  argonParams: const Argon2Params(),
);

EncryptedRecord _record(String id) => EncryptedRecord(
  id: id,
  updatedAt: 1,
  deviceId: 'device',
  deleted: false,
  seq: null,
  blob: Uint8List.fromList([1, 2, 3]),
);

Future<_Reply> _request(
  Handler handler,
  String method,
  String path, {
  String? token,
  Object? body,
}) async {
  final response = await handler(
    Request(
      method,
      Uri.parse('http://localhost$path'),
      headers: {
        if (token != null) 'authorization': 'Bearer $token',
        if (body != null) 'content-type': 'application/json',
      },
      body: body == null ? null : jsonEncode(body),
    ),
  );
  final text = await response.readAsString();
  return _Reply(
    response.statusCode,
    text.isEmpty
        ? const <String, dynamic>{}
        : (jsonDecode(text) as Map).cast<String, dynamic>(),
  );
}

Future<String> _register(Handler handler, RegisterRequest registration) async {
  final reply = await _request(
    handler,
    'POST',
    '/v1/register',
    body: registration.toJson(),
  );
  expect(reply.status, 200);
  return reply.body['token'] as String;
}

Future<_Reply> _deposit(Handler handler, String appId, String token) async {
  final response = await handler(
    Request(
      'POST',
      Uri.parse('http://localhost/v1/inbox/$appId'),
      headers: {'authorization': 'Bearer $token'},
      body: List<int>.filled(40, 0),
    ),
  );
  final text = await response.readAsString();
  return _Reply(
    response.statusCode,
    text.isEmpty
        ? const <String, dynamic>{}
        : (jsonDecode(text) as Map).cast<String, dynamic>(),
  );
}

enum _AccountAction { push, delete, sync }

void main() {
  for (final backend in ['in-memory', 'SQLite']) {
    test('login verified before delete and re-registration is rejected with '
        '$backend', () async {
      final harness = await _openHarness(backend);
      addTearDown(harness.close);
      final oldRegistration = _registration('o');
      final oldToken = await _register(harness.control, oldRegistration);
      harness.issueGate.arm();

      final login = _request(
        harness.target,
        'POST',
        '/v1/login',
        body: LoginRequest(
          username: 'alice',
          authVerifier: oldRegistration.authVerifier,
        ).toJson(),
      );
      await harness.issueGate.entered;

      expect(
        (await _request(
          harness.control,
          'DELETE',
          '/v1/account',
          token: oldToken,
        )).status,
        200,
      );
      final newToken = await _register(harness.control, _registration('n'));
      harness.issueGate.release();

      final reply = await login;
      expect(reply.status, 401);
      expect(reply.body['error'], 'invalid_credentials');
      expect(
        (await _request(
          harness.control,
          'GET',
          '/v1/sync',
          token: newToken,
        )).status,
        200,
      );
    });

    for (final action in _AccountAction.values) {
      test('${action.name} authorized before delete and re-registration cannot '
          'reach the new generation with $backend', () async {
        final harness = await _openHarness(backend);
        addTearDown(harness.close);
        final oldToken = await _register(harness.control, _registration('o'));
        harness.authGate.arm();

        final Future<_Reply> stale = switch (action) {
          _AccountAction.push => _request(
            harness.target,
            'PUT',
            '/v1/records',
            token: oldToken,
            body: PushRequest(records: [_record('stale')]).toJson(),
          ),
          _AccountAction.delete => _request(
            harness.target,
            'DELETE',
            '/v1/account',
            token: oldToken,
          ),
          _AccountAction.sync => _request(
            harness.target,
            'GET',
            '/v1/sync',
            token: oldToken,
          ),
        };
        await harness.authGate.entered;

        expect(
          (await _request(
            harness.control,
            'DELETE',
            '/v1/account',
            token: oldToken,
          )).status,
          200,
        );
        final newToken = await _register(harness.control, _registration('n'));
        if (action == _AccountAction.sync) {
          expect(
            (await _request(
              harness.control,
              'PUT',
              '/v1/records',
              token: newToken,
              body: PushRequest(records: [_record('new')]).toJson(),
            )).status,
            200,
          );
        }
        harness.authGate.release();

        final staleReply = await stale;
        expect(staleReply.status, 401);
        expect(staleReply.body['error'], 'unauthorized');
        final current = await _request(
          harness.control,
          'GET',
          '/v1/sync',
          token: newToken,
        );
        expect(current.status, 200);
        final records = PullResponse.fromJson(current.body).records;
        expect(
          records.map((record) => record.id),
          action == _AccountAction.sync ? ['new'] : isEmpty,
        );
      });
    }

    test('inbox mutation authorized before re-registration cannot delete the '
        'new generation app with $backend', () async {
      final harness = await _openHarness(backend);
      addTearDown(harness.close);
      final oldToken = await _register(harness.control, _registration('o'));
      final appId = newInboxAppId();
      harness.authGate.arm();
      final staleDelete = _request(
        harness.target,
        'DELETE',
        '/v1/apps/$appId',
        token: oldToken,
      );
      await harness.authGate.entered;

      expect(
        (await _request(
          harness.control,
          'DELETE',
          '/v1/account',
          token: oldToken,
        )).status,
        200,
      );
      final newToken = await _register(harness.control, _registration('n'));
      expect(
        (await _request(
          harness.control,
          'POST',
          '/v1/apps',
          token: newToken,
          body: CreateInboxAppRequest(
            appId: appId,
            name: 'new',
            token: newInboxToken(),
          ).toJson(),
        )).status,
        201,
      );
      harness.authGate.release();

      expect((await staleDelete).status, 401);
      final apps = await _request(
        harness.control,
        'GET',
        '/v1/apps',
        token: newToken,
      );
      expect(apps.status, 200);
      expect((apps.body['apps'] as List).single['app'], appId);
    });

    test('recreated app generation gets a fresh deposit rate-limit bucket '
        'with $backend', () async {
      final harness = await _openHarness(
        backend,
        inboxLimiter: RateLimiter(
          maxAttempts: 1,
          window: const Duration(days: 1),
        ),
      );
      addTearDown(harness.close);
      final accountToken = await _register(
        harness.control,
        _registration('o'),
      );
      final appId = newInboxAppId();
      final oldDepositToken = newInboxToken();
      expect(
        (await _request(
          harness.control,
          'POST',
          '/v1/apps',
          token: accountToken,
          body: CreateInboxAppRequest(
            appId: appId,
            name: 'old',
            token: oldDepositToken,
          ).toJson(),
        )).status,
        201,
      );
      expect(
        (await _deposit(harness.target, appId, oldDepositToken)).status,
        201,
      );

      expect(
        (await _request(
          harness.control,
          'DELETE',
          '/v1/apps/$appId',
          token: accountToken,
        )).status,
        204,
      );
      final newDepositToken = newInboxToken();
      expect(
        (await _request(
          harness.control,
          'POST',
          '/v1/apps',
          token: accountToken,
          body: CreateInboxAppRequest(
            appId: appId,
            name: 'new',
            token: newDepositToken,
          ).toJson(),
        )).status,
        201,
      );

      expect(
        (await _deposit(harness.target, appId, newDepositToken)).status,
        201,
      );
      expect(
        (await _deposit(harness.target, appId, newDepositToken)).status,
        429,
      );
    });

    test('deposit authorized for a removed app cannot reach its replacement '
        'with $backend', () async {
      final harness = await _openHarness(backend);
      addTearDown(harness.close);
      final oldToken = await _register(harness.control, _registration('o'));
      final appId = newInboxAppId();
      final oldDepositToken = newInboxToken();
      expect(
        (await _request(
          harness.target,
          'POST',
          '/v1/apps',
          token: oldToken,
          body: CreateInboxAppRequest(
            appId: appId,
            name: 'old',
            token: oldDepositToken,
          ).toJson(),
        )).status,
        201,
      );

      final readingBody = Completer<void>();
      final body = StreamController<List<int>>(onListen: readingBody.complete);
      final depositResponse = harness.target(
        Request(
          'POST',
          Uri.parse('http://localhost/v1/inbox/$appId'),
          headers: {'authorization': 'Bearer $oldDepositToken'},
          body: body.stream,
        ),
      );
      await readingBody.future;

      expect(
        (await _request(
          harness.control,
          'DELETE',
          '/v1/account',
          token: oldToken,
        )).status,
        200,
      );
      final newToken = await _register(harness.control, _registration('n'));
      expect(
        (await _request(
          harness.control,
          'POST',
          '/v1/apps',
          token: newToken,
          body: CreateInboxAppRequest(
            appId: appId,
            name: 'new',
            token: newInboxToken(),
          ).toJson(),
        )).status,
        201,
      );
      body.add(List<int>.filled(40, 0));
      await body.close();

      final response = await depositResponse;
      expect(response.statusCode, 401);
      expect(
        (await _request(
          harness.control,
          'GET',
          '/v1/inbox',
          token: newToken,
        )).body['items'],
        isEmpty,
      );
    });
  }
}
