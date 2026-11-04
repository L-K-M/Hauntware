import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpConnectionInfo, HttpStatus;
import 'dart:math' show min;
import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'package:seance_protocol/seance_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'client_address.dart';
import 'config.dart';
import 'favicon.dart';
import 'inbox_docs.dart';
import 'rate_limiter.dart';
import 'storage.dart';

part 'inbox_handlers.dart';

/// The Séance sync server. A dumb, breach-tolerant blob store: it authenticates
/// devices, stores end-to-end encrypted records, and resolves conflicts with
/// the same last-write-wins rule the client uses. It can decrypt nothing.
class SyncServer {
  /// Cap on a body read before any authentication (register, prelogin,
  /// login). The largest of them, a register body, is under 1 KiB; without
  /// this they inherited the push cap, so anyone could make the server buffer
  /// megabytes per request. Never above [ServerSettings.maxBodyBytes], so
  /// lowering that still lowers this.
  static const _maxAuthBodyBytes = 16 * 1024;

  /// Longest username, in UTF-8 bytes. Enough for any email address (RFC 5321
  /// caps one at 256 octets, brackets included) while keeping login limiter
  /// keys, which live for a whole window, small.
  static const _maxUsernameBytes = 256;

  /// C0 controls, DEL, C1 controls, and the format characters that render as
  /// nothing: soft hyphen, zero-width spaces and joiners, bidi marks,
  /// embeddings, overrides and isolates, and the byte-order mark. None belongs
  /// in a name, and one stored verbatim garbles or disguises the name wherever
  /// it is later displayed.
  static final _controlCharacter = RegExp(
    '[\u0000-\u001f\u007f-\u009f\u00ad\u200b-\u200f\u2028-\u202e'
    '\u2060-\u206f\ufeff]',
  );

  /// What every client has always sent: `VaultCrypto` derives a 32-byte
  /// verifier, and clients mint 16-byte Argon2 salts (a minimum, as a longer
  /// salt is still a valid one). An empty verifier would create an account
  /// anyone could sign in to with an empty one.
  static const _authVerifierBytes = 32;
  static const _minArgonSaltBytes = 16;
  static const _sessionTokenBytes = 32;
  static const _maxDeviceIdBytes = 128;
  static const _maxDeviceNameBytes = 128;
  static const _sessionTouchInterval = Duration(hours: 1);
  static final _deviceIdPattern = RegExp(r'^[A-Za-z0-9._:-]+$');

  final Storage storage;
  final ServerSettings settings;
  final RateLimiter authGlobalLimiter;
  final RateLimiter authClientLimiter;
  final RateLimiter loginLimiter;

  /// Deposits per inbox app, keyed by app id (docs/INBOX.md: 30 a minute).
  final RateLimiter inboxLimiter;
  final String Function(Request request) _clientAddress;

  /// The clock inbox retention is measured with; injectable for tests.
  final DateTime Function() _now;

  SyncServer({
    required this.storage,
    required this.settings,
    RateLimiter? authGlobalLimiter,
    RateLimiter? authClientLimiter,
    RateLimiter? loginLimiter,
    RateLimiter? inboxLimiter,
    String Function(Request request)? clientAddress,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       authGlobalLimiter =
           authGlobalLimiter ??
           RateLimiter(
             maxAttempts: settings.authGlobalMaxAttempts,
             window: settings.loginWindow,
             maxBuckets: 1,
             now: now,
           ),
       authClientLimiter =
           authClientLimiter ??
           RateLimiter(
             maxAttempts: settings.authClientMaxAttempts,
             window: settings.loginWindow,
             maxBuckets: settings.rateLimitMaxBuckets,
             now: now,
           ),
       loginLimiter =
           loginLimiter ??
           RateLimiter(
             maxAttempts: settings.loginMaxAttempts,
             window: settings.loginWindow,
             maxBuckets: settings.rateLimitMaxBuckets,
             now: now,
           ),
       inboxLimiter =
           inboxLimiter ??
           RateLimiter(
             maxAttempts: _inboxDepositsPerWindow,
             window: _inboxDepositWindow,
             maxBuckets: settings.rateLimitMaxBuckets,
             now: now,
           ),
       _clientAddress =
           clientAddress ?? _clientAddressFromRequest(settings.trustedProxies);

  Handler get handler {
    final router = Router()
      ..get('/healthz', (Request r) => Response.ok('ok'))
      // A browser hitting the server sees what it is instead of a 404 (the
      // API itself lives under /v1/); the favicon is embedded in the binary.
      ..get(
        '/',
        (Request r) => Response.ok(
          _landingPage,
          headers: {'content-type': 'text/html; charset=utf-8'},
        ),
      )
      ..get(
        '/favicon.ico',
        (Request r) =>
            Response.ok(faviconPng, headers: {'content-type': 'image/png'}),
      )
      ..post('/v1/register', _register)
      ..post('/v1/prelogin', _prelogin)
      ..post('/v1/login', _login)
      ..get('/v1/sync', _sync)
      ..put('/v1/records', _push)
      ..delete('/v1/account', _deleteAccount)
      ..get('/v1/sessions', _listSessions)
      ..delete('/v1/sessions/current', _revokeCurrentSession)
      ..delete('/v1/sessions', _revokeAllSessions)
      // Static routes must be registered before this parameter route, so the
      // words `current` and the collection itself cannot be mistaken for ids.
      ..delete('/v1/sessions/<sessionId>', _revokeSession)
      // The command inbox (docs/INBOX.md). The producer's only route is the
      // POST; every other inbox route needs a session, so a deposit token
      // can add items and do nothing else.
      ..post('/v1/apps', _createInboxApp)
      ..get('/v1/apps', _listInboxApps)
      ..delete('/v1/apps/<appId>', _deleteInboxApp)
      ..get('/v1/inbox', _listInbox)
      ..post('/v1/inbox/<appId>', _deposit)
      ..delete('/v1/inbox/<appId>/<itemId>', _deleteInboxItem)
      // Static documentation for producers, which have only a pairing
      // string. App ids are base64url and so never contain a dot: these
      // paths cannot shadow an app.
      ..get('/llms.txt', (Request r) => _static(inboxLlmsTxt, 'text/plain'))
      ..get(
        '/v1/inbox/openapi.json',
        (Request r) => _static(inboxOpenApiJson, 'application/json'),
      )
      ..get(
        '/v1/inbox/seance-propose.py',
        (Request r) => _static(inboxProposePy, 'text/x-python'),
      );

    return const Pipeline()
        .addMiddleware(_errorToJson())
        .addHandler(router.call);
  }

  Future<HttpServerLike> start() async {
    final server = await shelf_io.serve(
      handler,
      settings.bindAddress,
      settings.port,
      poweredByHeader: null,
    );
    return HttpServerLike(
      server.address.host,
      server.port,
      () => server.close(force: true),
    );
  }

  // --- Handlers ---

  Future<Response> _register(Request req) async {
    final limited = _limitAuthentication(req);
    if (limited != null) return limited;
    final body = await _readJson(req, _authBodyCap);
    if (body == null) return _error(400, 'bad_request', 'Malformed JSON');
    final RegisterRequest r;
    try {
      r = RegisterRequest.fromJson(body);
    } catch (_) {
      return _error(400, 'bad_request', 'Invalid register payload');
    }
    if (r.protocolVersion != kProtocolVersion) {
      return _error(
        400,
        'protocol_version',
        'Client protocol v${r.protocolVersion} != server v$kProtocolVersion',
      );
    }
    final device = _deviceFromRequest(req);
    if (device == null) return _badDevice();
    if (!settings.openRegistration) {
      return _error(403, 'registration_closed', 'Registration is disabled');
    }
    if (!_isRegistrableUsername(r.username)) {
      return _error(
        400,
        'bad_username',
        'Username must be 1 to $_maxUsernameBytes bytes of UTF-8 without '
            'control characters',
      );
    }
    final authVerifier = _tryBase64Decode(r.authVerifier);
    // Decoded with the same decoder a client uses at prelogin, so a salt
    // stored here is one every client can read back.
    final argonSalt = _tryBase64Decode(r.argonSalt);
    if (authVerifier == null ||
        authVerifier.length != _authVerifierBytes ||
        argonSalt == null ||
        argonSalt.length < _minArgonSaltBytes) {
      return _error(400, 'bad_request', 'Invalid register payload');
    }
    final verifierSalt = secureRandomBytes(16);
    final hash = VaultCrypto.hashAuthVerifier(authVerifier, verifierSalt);
    final now = _now().millisecondsSinceEpoch;
    final issued = await storage.createAccountAndSession(
      Account(
        username: r.username,
        authVerifierHash: hash,
        verifierSalt: base64.encode(verifierSalt),
        argonSalt: r.argonSalt,
        argonParams: r.argonParams,
      ),
      device,
      now: now,
      expiresAt: now + settings.sessionTtl.inMilliseconds,
      maxSessions: settings.maxSessionsPerAccount,
    );
    if (issued == null) {
      return _error(409, 'account_exists', 'Username already registered');
    }
    return _json(LoginResponse(token: issued.token).toJson());
  }

  Future<Response> _prelogin(Request req) async {
    final limited = _limitAuthentication(req);
    if (limited != null) return limited;
    final body = await _readJson(req, _authBodyCap);
    final username = body?['username'];
    if (username == null) return _error(400, 'bad_request', 'Missing username');
    if (username is! String) {
      return _error(400, 'bad_request', 'Invalid prelogin payload');
    }
    if (!_usernameInBounds(username)) return _usernameOutOfBounds();
    final account = await storage.getAccount(username);
    if (account == null) {
      return _error(404, 'no_account', 'No such account');
    }
    return _json(
      PreloginResponse(
        argonSalt: account.argonSalt,
        argonParams: account.argonParams,
      ).toJson(),
    );
  }

  Future<Response> _login(Request req) async {
    final limited = _limitAuthentication(req);
    if (limited != null) return limited;
    final body = await _readJson(req, _authBodyCap);
    if (body == null) return _error(400, 'bad_request', 'Malformed JSON');
    final LoginRequest r;
    try {
      r = LoginRequest.fromJson(body);
    } catch (_) {
      return _error(400, 'bad_request', 'Invalid login payload');
    }
    if (r.protocolVersion != kProtocolVersion) {
      return _error(400, 'protocol_version', 'Protocol version mismatch');
    }
    final device = _deviceFromRequest(req);
    if (device == null) return _badDevice();
    // Before the limiter, whose keys outlive this request by a whole window.
    if (!_usernameInBounds(r.username)) return _usernameOutOfBounds();
    if (!loginLimiter.allow('login:${r.username}')) {
      return _error(429, 'rate_limited', 'Too many login attempts');
    }
    final account = await storage.getAccount(r.username);
    // Always compute against *some* stored hash to keep timing uniform.
    final expected = account?.authVerifierHash ?? '';
    final authVerifier = _tryBase64Decode(r.authVerifier);
    if (authVerifier == null) {
      return _error(400, 'bad_request', 'Invalid login payload');
    }
    final verifierSalt = account == null
        ? null
        : _tryBase64Decode(account.verifierSalt);
    if (account != null && verifierSalt == null) {
      throw StateError(
        'Stored verifier salt is invalid for ${account.username}',
      );
    }
    final provided = account == null
        ? ''
        : VaultCrypto.hashAuthVerifier(authVerifier, verifierSalt!);
    if (account == null || !_constantTimeEquals(provided, expected)) {
      return _error(401, 'invalid_credentials', 'Invalid credentials');
    }
    final now = _now().millisecondsSinceEpoch;
    final issued = await storage.createSession(
      r.username,
      device,
      now: now,
      expiresAt: now + settings.sessionTtl.inMilliseconds,
      maxSessions: settings.maxSessionsPerAccount,
    );
    if (issued == null) {
      return _error(401, 'invalid_credentials', 'Invalid credentials');
    }
    loginLimiter.reset('login:${r.username}');
    return _json(LoginResponse(token: issued.token).toJson());
  }

  Future<Response> _sync(Request req) => _withAuth(req, (username) async {
    final since = int.tryParse(req.url.queryParameters['since'] ?? '0') ?? 0;
    final snapshot = await storage.pullSnapshot(username, since);
    // Every round pulls before it pushes, so this is where a client learns how
    // to size the push it is about to make — see [PushLimits].
    return _json(
      PullResponse(
        records: snapshot.records,
        latestSeq: snapshot.latestSeq,
        limits: settings.pushLimits,
      ).toJson(),
    );
  });

  Future<Response> _push(Request req) => _withAuth(req, (username) async {
    final body = await _readJson(req, settings.maxBodyBytes);
    if (body == null) return _error(400, 'bad_request', 'Malformed JSON');
    final PushRequest r;
    try {
      r = PushRequest.fromJson(body);
    } catch (_) {
      return _error(400, 'bad_request', 'Invalid push payload');
    }
    if (r.protocolVersion != kProtocolVersion) {
      return _error(400, 'protocol_version', 'Protocol version mismatch');
    }
    if (r.records.length > settings.maxRecordsPerPush) {
      return _error(
        413,
        'payload_too_large',
        'Too many records in one push (max ${settings.maxRecordsPerPush})',
      );
    }
    for (final incoming in r.records) {
      if (incoming.blob.length > settings.maxBlobBytes) {
        return _error(
          413,
          'payload_too_large',
          'A record blob exceeds the ${settings.maxBlobBytes}-byte limit',
        );
      }
    }
    final pushed = await storage.pushRecords(username, r.records);
    return _json(pushed.toJson());
  });

  Future<Response> _deleteAccount(Request req) =>
      _withAuth(req, (username) async {
        await storage.deleteAccount(username);
        return _json({'ok': true});
      });

  Future<Response> _listSessions(Request req) =>
      _withSession(req, (current) async {
        final sessions = await storage.listSessions(
          current.username,
          now: _now().millisecondsSinceEpoch,
        );
        return _json(
          SyncSessionsResponse(
            sessions: [
              for (final session in sessions)
                SyncSessionInfo(
                  id: session.id,
                  deviceId: session.deviceId,
                  deviceName: session.deviceName,
                  createdAt: session.createdAt,
                  expiresAt: session.expiresAt,
                  lastUsedAt: session.lastUsedAt,
                  legacy: session.legacy,
                  current: session.id == current.id,
                ),
            ],
          ).toJson(),
        );
      });

  Future<Response> _revokeCurrentSession(Request req) =>
      _withSession(req, (current) async {
        // Authentication proved it existed. Treat a concurrent same-account
        // revocation as success too: the requested end state already holds.
        await storage.revokeSession(current.username, current.id);
        return _json(
          const RevokeSessionResponse(revoked: true, current: true).toJson(),
        );
      });

  Future<Response> _revokeAllSessions(Request req) =>
      _withSession(req, (current) async {
        await storage.revokeAllSessions(current.username);
        return _json(
          const RevokeSessionResponse(revoked: true, current: true).toJson(),
        );
      });

  Future<Response> _revokeSession(Request req, String sessionId) =>
      _withSession(req, (current) async {
        final revoked = await storage.revokeSession(
          current.username,
          sessionId,
        );
        if (!revoked) {
          return _error(404, 'not_found', 'No such session');
        }
        return _json(
          RevokeSessionResponse(
            revoked: true,
            current: sessionId == current.id,
          ).toJson(),
        );
      });

  // --- Helpers ---

  Response? _limitAuthentication(Request req) {
    if (!authGlobalLimiter.allow('authentication')) {
      return _error(429, 'rate_limited', 'Too many authentication requests');
    }
    final client = _clientAddress(req);
    if (!authClientLimiter.allow('authentication:$client')) {
      return _error(429, 'rate_limited', 'Too many authentication requests');
    }
    return null;
  }

  static String Function(Request request) _clientAddressFromRequest(
    Set<String> trustedProxies,
  ) {
    final resolver = ClientAddressResolver(trustedProxies);
    return (request) {
      final connection = request.context['shelf.io.connection_info'];
      final peer = connection is HttpConnectionInfo
          ? connection.remoteAddress.address
          : 'unknown';
      return resolver.resolve(
        peerAddress: peer,
        forwardedFor: request.headers['x-forwarded-for'],
      );
    };
  }

  Future<Response> _withAuth(
    Request req,
    Future<Response> Function(String username) fn,
  ) => _withSession(req, (session) => fn(session.username));

  Future<Response> _withSession(
    Request req,
    Future<Response> Function(StoredSession session) fn,
  ) async {
    final auth = req.headers['authorization'];
    if (auth == null || !auth.startsWith('Bearer ')) {
      return _error(401, 'unauthorized', 'Missing bearer token');
    }
    final token = auth.substring(7);
    if (!_isCanonicalSessionToken(token)) {
      return _error(401, 'unauthorized', 'Invalid token');
    }
    final now = _now().millisecondsSinceEpoch;
    final session = await storage.authenticateSession(
      token,
      now: now,
      touchBefore: now - _sessionTouchInterval.inMilliseconds,
    );
    if (session == null) {
      return _error(401, 'unauthorized', 'Invalid token');
    }
    return fn(session);
  }

  static bool _isCanonicalSessionToken(String token) {
    // A padded base64url encoding of 32 bytes is exactly 44 ASCII characters.
    // Bound before decoding so an attacker cannot make validation allocate in
    // proportion to an arbitrary Authorization header.
    if (token.length != 44) return false;
    try {
      final bytes = base64Url.decode(token);
      return bytes.length == _sessionTokenBytes &&
          base64Url.encode(bytes) == token;
    } on FormatException {
      return false;
    }
  }

  SessionDevice? _deviceFromRequest(Request req) {
    final id = req.headers['x-seance-device-id'];
    final name = req.headers['x-seance-device-name'];
    if (id == null ||
        name == null ||
        id.isEmpty ||
        name.isEmpty ||
        id.trim() != id ||
        name.trim() != name ||
        utf8.encode(id).length > _maxDeviceIdBytes ||
        utf8.encode(name).length > _maxDeviceNameBytes ||
        !_deviceIdPattern.hasMatch(id) ||
        _controlCharacter.hasMatch(name)) {
      return null;
    }
    return SessionDevice(id: id, name: name);
  }

  Response _badDevice() => _error(
    400,
    'bad_device',
    'Valid X-Seance-Device-Id and X-Seance-Device-Name headers are required',
  );

  int get _authBodyCap => min(settings.maxBodyBytes, _maxAuthBodyBytes);

  /// Whether a new account may take [username]. Registration only: names were
  /// never checked before, so a stored one may break this rule, and login and
  /// prelogin keep answering for it with just [_usernameInBounds].
  static bool _isRegistrableUsername(String username) =>
      _usernameInBounds(username) && !_controlCharacter.hasMatch(username);

  static bool _usernameInBounds(String username) =>
      username.isNotEmpty && utf8.encode(username).length <= _maxUsernameBytes;

  Response _usernameOutOfBounds() => _error(
    400,
    'bad_username',
    'Username must be 1 to $_maxUsernameBytes bytes of UTF-8',
  );

  Future<Map<String, dynamic>?> _readJson(Request req, int maxBytes) async {
    // Reject an oversized body before reading it (a lying/omitted Content-Length
    // is still caught while streaming below). Throws _PayloadTooLarge, which the
    // error middleware maps to 413.
    final declared = req.contentLength;
    if (declared != null && declared > maxBytes) {
      throw const _PayloadTooLarge();
    }
    final String text;
    try {
      text = await _readBounded(req, maxBytes);
    } on _PayloadTooLarge {
      rethrow;
    } catch (_) {
      return null;
    }
    if (text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<String> _readBounded(Request req, int maxBytes) async =>
      utf8.decode(await _readBoundedBytes(req, maxBytes));

  Future<Uint8List> _readBoundedBytes(Request req, int maxBytes) async {
    // Keeps the received chunks as they are. A growable List<int> spends a
    // word per byte plus growth slack, which made one body just under the
    // 8 MiB push cap cost over 100 MiB of heap.
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in req.read()) {
      bytes.add(chunk);
      if (bytes.length > maxBytes) throw const _PayloadTooLarge();
    }
    return bytes.takeBytes();
  }

  List<int>? _tryBase64Decode(String value) {
    try {
      return base64.decode(value);
    } on FormatException {
      return null;
    }
  }

  Middleware _errorToJson() => (Handler inner) {
    return (Request req) async {
      try {
        return await inner(req);
      } on StorageUnavailableException catch (e) {
        return _error(
          HttpStatus.serviceUnavailable,
          'storage_unavailable',
          e.toString(),
        );
      } on StorageBusyException {
        return _error(
          HttpStatus.serviceUnavailable,
          'storage_busy',
          'Storage is busy; retry shortly.',
        );
      } on _PayloadTooLarge {
        return _error(413, 'payload_too_large', 'Request body too large');
      } on FormatException {
        return _error(400, 'bad_request', 'Invalid request payload');
      } catch (e) {
        return _error(500, 'internal_error', 'Internal server error');
      }
    };
  };

  Response _json(Object body, {int status = 200}) => Response(
    status,
    body: jsonEncode(body),
    headers: {'content-type': 'application/json'},
  );

  Response _error(int status, String code, String message) => _json(
    ApiError(code: code, message: message).toJson(),
    status: status,
  );

  static const _landingPage = '''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Séance sync server</title>
<link rel="icon" type="image/png" href="/favicon.ico">
</head>
<body style="font-family: system-ui, sans-serif; margin: 3em auto; max-width: 34em;">
<h1>Séance sync server</h1>
<p>A breach-tolerant blob store for the <strong>Séance</strong> SSH client:
it holds only end-to-end encrypted records and can decrypt nothing.
Configure this server's URL in the app's sync settings.</p>
<p>Handed an inbox pairing string to propose commands? Read
<a href="/llms.txt">/llms.txt</a> or use the reference client,
<a href="/v1/inbox/seance-propose.py">seance-propose.py</a>.</p>
</body>
</html>
''';

  static bool _constantTimeEquals(String a, String b) {
    final ab = utf8.encode(a);
    final bb = utf8.encode(b);
    if (ab.length != bb.length) return false;
    var diff = 0;
    for (var i = 0; i < ab.length; i++) {
      diff |= ab[i] ^ bb[i];
    }
    return diff == 0;
  }
}

/// Signals that a request body exceeded its route's cap. Mapped to HTTP 413 by
/// the error middleware.
class _PayloadTooLarge implements Exception {
  const _PayloadTooLarge();
}

/// Minimal handle to a running server so callers can read the bound port and
/// stop it, without leaking the shelf `HttpServer` type through the API.
class HttpServerLike {
  final String host;
  final int port;
  final Future<void> Function() _close;
  HttpServerLike(this.host, this.port, this._close);
  Future<void> close() => _close();
}
