import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpConnectionInfo, HttpStatus, stderr;
import 'dart:math' show min;
import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'package:seance_protocol/seance_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'config.dart';
import 'client_address.dart';
import 'favicon.dart';
import 'inbox_docs.dart';
import 'legacy_migration_validation.dart';
import 'rate_limiter.dart';
import 'storage.dart';

part 'inbox_handlers.dart';

/// The Séance sync server. A dumb, breach-tolerant blob store: it authenticates
/// devices, stores end-to-end encrypted records, and resolves conflicts with
/// the same last-write-wins rule the client uses. It can decrypt nothing.
class SyncServer {
  /// SQLite sequence values are signed 64-bit integers. Size probes use the
  /// widest value a stored row can acquire so a write accepted today remains
  /// pullable after the account has accumulated more revisions.
  static const int _maxStorageSequence = 0x7fffffffffffffff;
  static const _inboxPurgeInterval = Duration(hours: 1);

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

  final Storage storage;
  final ServerSettings settings;
  final RateLimiter loginLimiter;
  final RateLimiter authGlobalLimiter;
  final RateLimiter authSourceLimiter;
  final String Function(Request) _sourceFor;
  late final PushLimits _advertisedPushLimits;

  /// Deposits per inbox app, keyed by app id (docs/INBOX.md: 30 a minute).
  final RateLimiter inboxLimiter;

  /// The clock inbox retention is measured with; injectable for tests.
  final DateTime Function() _now;

  SyncServer({
    required this.storage,
    required this.settings,
    RateLimiter? loginLimiter,
    RateLimiter? authGlobalLimiter,
    RateLimiter? authSourceLimiter,
    String Function(Request)? sourceFor,
    RateLimiter? inboxLimiter,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _sourceFor =
           sourceFor ??
           ((request) {
             final info = request.context['shelf.io.connection_info'];
             final peer = info is HttpConnectionInfo
                 ? info.remoteAddress.address
                 : 'unknown';
             return ClientAddressResolver(settings.trustedProxies).resolve(
               peerAddress: peer,
               forwardedFor: request.headers['x-forwarded-for'],
             );
           }),
       authGlobalLimiter =
           authGlobalLimiter ??
           RateLimiter(
             maxAttempts: settings.authGlobalMaxAttempts,
             window: settings.authGlobalWindow,
             maxBuckets: 1,
             now: now,
           ),
       authSourceLimiter =
           authSourceLimiter ??
           RateLimiter(
             maxAttempts: settings.authSourceMaxAttempts,
             window: settings.authSourceWindow,
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
           ) {
    _advertisedPushLimits = _deriveAdvertisedPushLimits();
    _validatePullPageSettings();
  }

  PushLimits _deriveAdvertisedPushLimits() {
    final configured = settings.pushLimits;
    final withoutSequence = EncryptedRecord(
      id: '',
      updatedAt: 0,
      deviceId: '',
      deleted: false,
      seq: null,
      blob: Uint8List(0),
    );
    final sequenceGrowth =
        withoutSequence.withSeq(_maxStorageSequence).encodedJsonBytes() -
        withoutSequence.encodedJsonBytes();
    final fixedPullBytes = PullResponse.bodyBytesFor(
      recordCount: 1,
      recordBytes: sequenceGrowth,
      latestSeq: _maxStorageSequence,
      recordEnvelopeFloor: kCurrentRecordEnvelopeVersion,
      throughSeq: _maxStorageSequence,
      hasMore: false,
      limits: configured,
    );
    final pullSafeRecordBytes = settings.maxPullBodyBytes - fixedPullBytes;
    final pullSafeBodyBytes = pullSafeRecordBytes <= 0
        ? 1
        : PushRequest.bodyBytesFor(
            recordCount: 1,
            recordBytes: pullSafeRecordBytes,
          );
    return PushLimits(
      maxBodyBytes: min(configured.maxBodyBytes, pullSafeBodyBytes),
      maxRecordsPerPush: configured.maxRecordsPerPush,
      maxBlobBytes: configured.maxBlobBytes,
    );
  }

  void _validatePullPageSettings() {
    final emptyRecordPage = PullResponse.bodyBytesFor(
      recordCount: 0,
      recordBytes: 0,
      latestSeq: _maxStorageSequence,
      throughSeq: _maxStorageSequence,
      hasMore: false,
      limits: _advertisedPushLimits,
    );
    final emptyInboxPage = InboxPage.bodyBytesFor(
      itemCount: 0,
      itemBytes: 0,
      throughReceived: _maxStorageSequence,
      nextReceived: _maxStorageSequence,
      hasMore: false,
    );
    final minimum = emptyRecordPage > emptyInboxPage
        ? emptyRecordPage
        : emptyInboxPage;
    if (settings.maxPullBodyBytes < minimum) {
      throw ArgumentError.value(
        settings.maxPullBodyBytes,
        'settings.maxPullBodyBytes',
        'must be at least $minimum bytes so an empty page fits',
      );
    }
  }

  bool _recordFitsPullPage(EncryptedRecord incoming) {
    final stored = incoming.withSeq(_maxStorageSequence);
    return PullResponse.bodyBytesFor(
          recordCount: 1,
          recordBytes: stored.encodedJsonBytes(),
          latestSeq: _maxStorageSequence,
          recordEnvelopeFloor: kCurrentRecordEnvelopeVersion,
          throughSeq: _maxStorageSequence,
          hasMore: false,
          limits: _advertisedPushLimits,
        ) <=
        settings.maxPullBodyBytes;
  }

  bool _inboxItemFitsPullPage(String appId, String itemId, Uint8List blob) {
    final item = InboxItem(
      appId: appId,
      itemId: itemId,
      received: _maxStorageSequence,
      blob: blob,
    );
    return InboxPage.bodyBytesFor(
          itemCount: 1,
          itemBytes: item.encodedJsonBytes(),
          throughReceived: _maxStorageSequence,
          nextReceived: _maxStorageSequence,
          hasMore: false,
        ) <=
        settings.maxPullBodyBytes;
  }

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
      ..get('/v1/records/legacy', _legacyRecords)
      ..put('/v1/records/legacy', _migrateLegacyRecords)
      ..delete('/v1/session', _revokeSession)
      ..delete('/v1/sessions', _revokeAllSessions)
      ..put('/v1/account/vault-key-check', _initializeVaultKeyCheck)
      ..delete('/v1/account', _deleteAccount)
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

  Future<HttpServerLike> start({
    Timer Function(Duration, void Function())? timerFactory,
  }) async {
    // Purge before advertising a healthy listener. Request-time purges remain
    // a correctness backstop, while this bounds storage for abandoned users.
    await _purgeExpiredInbox();
    final server = await shelf_io.serve(
      handler,
      settings.bindAddress,
      settings.port,
      poweredByHeader: null,
    );
    final retention = _InboxRetentionPurge(
      interval: _inboxPurgeInterval,
      purge: _purgeExpiredInbox,
      timerFactory: timerFactory ?? Timer.new,
      onError: (error, _) {
        stderr.writeln('Inbox retention purge failed: $error');
      },
    );
    try {
      retention.start();
    } catch (_) {
      await server.close(force: true);
      rethrow;
    }

    Future<void>? closeFuture;
    Future<void> close() => closeFuture ??= () async {
      retention.cancel();
      try {
        await server.close(force: true);
      } finally {
        await retention.done;
      }
    }();

    return HttpServerLike(server.address.host, server.port, close);
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
    final vaultKeyCheck = _tryBase64Decode(r.vaultKeyCheck);
    if (authVerifier == null ||
        authVerifier.length != _authVerifierBytes ||
        argonSalt == null ||
        argonSalt.length < _minArgonSaltBytes ||
        vaultKeyCheck == null ||
        vaultKeyCheck.length < 40 ||
        vaultKeyCheck.length > 1024) {
      return _error(400, 'bad_request', 'Invalid register payload');
    }
    final verifierSalt = secureRandomBytes(16);
    final hash = VaultCrypto.hashAuthVerifier(authVerifier, verifierSalt);
    final now = _nowMs;
    final token = await storage.registerAccount(
      Account(
        username: r.username,
        generation: base64Url.encode(secureRandomBytes(16)),
        authVerifierHash: hash,
        verifierSalt: base64.encode(verifierSalt),
        argonSalt: r.argonSalt,
        argonParams: r.argonParams,
        vaultKeyCheck: r.vaultKeyCheck,
      ),
      issuedAt: now,
      expiresAt: now + settings.sessionDuration.inMilliseconds,
      maxSessions: settings.maxSessionsPerAccount,
    );
    if (token == null) {
      return _error(409, 'account_exists', 'Username already registered');
    }
    return _json(
      LoginResponse(
        token: token,
        vaultKeyCheck: r.vaultKeyCheck,
        recordEnvelopeFloor: kCurrentRecordEnvelopeVersion,
      ).toJson(),
    );
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
    // Before the limiter, whose keys outlive this request by a whole window.
    if (!_usernameInBounds(r.username)) return _usernameOutOfBounds();
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
      final decision = loginLimiter.check('login:${r.username}');
      if (!decision.allowed) return _rateLimited(decision);
      return _error(401, 'invalid_credentials', 'Invalid credentials');
    }
    final now = _nowMs;
    final token = await storage.createTokenFor(
      account,
      issuedAt: now,
      expiresAt: now + settings.sessionDuration.inMilliseconds,
      maxSessions: settings.maxSessionsPerAccount,
    );
    if (token == null) {
      return _error(401, 'invalid_credentials', 'Invalid credentials');
    }
    loginLimiter.reset('login:${r.username}');
    return _json(
      LoginResponse(
        token: token,
        vaultKeyCheck: account.vaultKeyCheck,
        recordEnvelopeFloor: account.recordEnvelopeFloor,
      ).toJson(),
    );
  }

  Future<Response> _sync(Request req) => _withAuth(req, (principal) async {
    final protocolVersion = int.tryParse(
      req.headers['x-seance-protocol-version'] ?? '',
    );
    if (protocolVersion != kProtocolVersion) {
      return _error(
        400,
        'protocol_version',
        'Client protocol v${protocolVersion ?? 'missing'} != server '
            'v$kProtocolVersion',
      );
    }
    final since = int.tryParse(req.url.queryParameters['since'] ?? '0');
    if (since == null || since < 0) {
      return _error(400, 'bad_request', 'Invalid sync cursor');
    }
    final page = req.url.queryParameters['page'];
    if (page != null && page != '1') {
      return _error(400, 'bad_request', 'Invalid sync page flag');
    }
    final throughText = req.url.queryParameters['through'];
    final through = throughText == null ? null : int.tryParse(throughText);
    if (throughText != null && (through == null || through < 0)) {
      return _error(400, 'bad_request', 'Invalid sync watermark');
    }
    final snapshot = await storage.pullPageFor(
      principal,
      since,
      throughSeq: page == '1' ? through : null,
      limits: PullPageLimits(
        maxRecords: settings.maxRecordsPerPull,
        maxBodyBytes: settings.maxPullBodyBytes,
      ),
      advertisedLimits: _advertisedPushLimits,
    );
    // A request without the page flag predates pagination: its response shape
    // has no field that could announce a cut, so an answer too large for one
    // page is refused rather than silently truncated.
    if (page != '1' && snapshot.hasMore) {
      return _error(
        400,
        'pagination_required',
        'The account no longer fits one response; retry with page=1',
      );
    }
    // Every round pulls before it pushes, so this is where a client learns how
    // to size the push it is about to make — see [PushLimits].
    return _json(
      PullResponse(
        records: snapshot.records,
        latestSeq: snapshot.latestSeq,
        recordEnvelopeFloor: snapshot.recordEnvelopeFloor,
        throughSeq: page == '1' ? snapshot.throughSeq : null,
        hasMore: snapshot.hasMore,
        limits: _advertisedPushLimits,
      ).toJson(),
    );
  });

  Future<Response> _push(Request req) => _withAuth(req, (principal) async {
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
      if (incoming.envelopeVersion != 2) {
        return _error(
          400,
          'record_envelope_version',
          'Only authenticated record envelope v2 is accepted',
        );
      }
      if (incoming.blob.length > settings.maxBlobBytes) {
        return _error(
          413,
          'payload_too_large',
          'A record blob exceeds the ${settings.maxBlobBytes}-byte limit',
        );
      }
      if (!_recordFitsPullPage(incoming)) {
        return _error(
          413,
          'payload_too_large',
          'A stored record would exceed the configured pull page limit',
        );
      }
    }
    final pushed = await storage.pushRecordsFor(
      principal,
      r.records,
      quota: AccountQuota(
        maxRecords: settings.maxRecordsPerAccount,
        maxBytes: settings.maxAccountBytes,
      ),
    );
    return _json(pushed.toJson());
  });

  Future<Response> _legacyRecords(Request req) =>
      _withAuth(req, (principal) async {
        final protocolVersion = int.tryParse(
          req.headers['x-seance-protocol-version'] ?? '',
        );
        if (protocolVersion != kProtocolVersion) {
          return _error(400, 'protocol_version', 'Protocol version mismatch');
        }
        final afterId = req.url.queryParameters['after'];
        final page = await storage.legacyRecordPageFor(
          principal,
          afterId: afterId,
          limits: PullPageLimits(
            maxRecords: settings.maxRecordsPerPull,
            maxBodyBytes: settings.maxPullBodyBytes,
          ),
        );
        return _json(page.toJson());
      });

  Future<Response> _migrateLegacyRecords(Request req) =>
      _withAuth(req, (principal) async {
        final body = await _readJson(
          req,
          settings.maxBodyBytes + settings.maxPullBodyBytes,
        );
        if (body == null) {
          return _error(400, 'bad_request', 'Malformed JSON');
        }
        final LegacyMigrationRequest migration;
        try {
          migration = LegacyMigrationRequest.fromJson(body);
          validateLegacyMigrationBatch(migration.migrations);
        } catch (_) {
          return _error(400, 'bad_request', 'Invalid migration payload');
        }
        if (migration.protocolVersion != kProtocolVersion) {
          return _error(400, 'protocol_version', 'Protocol version mismatch');
        }
        if (migration.migrations.length > settings.maxRecordsPerPush) {
          return _error(
            413,
            'payload_too_large',
            'Too many records in one migration batch',
          );
        }
        for (final candidate in migration.migrations) {
          if (candidate.replacement.blob.length > settings.maxBlobBytes ||
              !_recordFitsPullPage(candidate.replacement)) {
            return _error(
              413,
              'payload_too_large',
              'A replacement record exceeds the configured limit',
            );
          }
        }
        final result = await storage.migrateLegacyRecordsFor(
          principal,
          migration.migrations,
          finalize: migration.finalize,
          quota: AccountQuota(
            maxRecords: settings.maxRecordsPerAccount,
            maxBytes: settings.maxAccountBytes,
          ),
        );
        return _json(result.toJson());
      });

  Future<Response> _revokeSession(Request req) =>
      _withAuth(req, (principal) async {
        if (!await storage.revokeSession(principal)) {
          throw const StalePrincipalException();
        }
        return Response(204);
      });

  Future<Response> _revokeAllSessions(Request req) =>
      _withAuth(req, (principal) async {
        if (!await storage.revokeAllSessions(principal)) {
          throw const StalePrincipalException();
        }
        return Response(204);
      });

  Future<Response> _initializeVaultKeyCheck(Request req) => _withAuth(req, (
    principal,
  ) async {
    final body = await _readJson(req, _authBodyCap);
    final encoded = body?['vaultKeyCheck'];
    if (encoded is! String) {
      return _error(400, 'bad_request', 'Invalid vault key check');
    }
    final decoded = _tryBase64Decode(encoded);
    if (decoded == null || decoded.length < 40 || decoded.length > 1024) {
      return _error(400, 'bad_request', 'Invalid vault key check');
    }
    final stored = await storage.initializeVaultKeyCheckFor(principal, encoded);
    return _json({'vaultKeyCheck': stored});
  });

  Future<Response> _deleteAccount(Request req) =>
      _withAuth(req, (principal) async {
        if (!await storage.deleteAccountFor(principal)) {
          throw const StalePrincipalException();
        }
        return _json({'ok': true});
      });

  // --- Helpers ---

  Response? _limitAuthentication(Request request) {
    final source = authSourceLimiter.check('source:${_sourceFor(request)}');
    if (!source.allowed) return _rateLimited(source);
    // A source already denied by its tighter limit must not consume global
    // capacity and turn one abusive address into an outage for everyone.
    final global = authGlobalLimiter.check('authentication');
    if (!global.allowed) return _rateLimited(global);
    return null;
  }

  Response _rateLimited(RateLimitDecision decision) {
    final duration = decision.retryAfter ?? const Duration(seconds: 1);
    final seconds = (duration.inMilliseconds / 1000).ceil().clamp(
      1,
      0x7fffffff,
    );
    return _json(
      const ApiError(
        code: 'rate_limited',
        message: 'Too many authentication attempts',
      ).toJson(),
      status: HttpStatus.tooManyRequests,
      headers: {'retry-after': '$seconds'},
    );
  }

  Future<Response> _withAuth(
    Request req,
    Future<Response> Function(AuthPrincipal principal) fn,
  ) async {
    final auth = req.headers['authorization'];
    if (auth == null || !auth.startsWith('Bearer ')) {
      return _error(401, 'unauthorized', 'Missing bearer token');
    }
    final principal = await storage.principalForToken(
      auth.substring(7),
      now: _nowMs,
    );
    if (principal == null) {
      return _error(401, 'unauthorized', 'Invalid token');
    }
    return fn(principal);
  }

  int get _nowMs => _now().millisecondsSinceEpoch;

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
      } on StorageCursorRejectedException {
        return _error(409, 'cursor_rejected', 'Sync cursor is no longer valid');
      } on StoragePageTooSmallException {
        return _error(
          500,
          'pull_limit_too_small',
          'The configured pull body limit cannot hold one stored item',
        );
      } on StorageEnvelopeFloorViolationException {
        return _error(
          500,
          'record_envelope_floor_violation',
          'The record envelope checkpoint is inconsistent',
        );
      } on AccountQuotaExceededException {
        return _error(
          413,
          'account_quota_exceeded',
          'The account has reached its record storage quota',
        );
      } on StalePrincipalException {
        return _error(401, 'unauthorized', 'Invalid token');
      } on VaultKeyCheckInitializationException {
        return _error(
          409,
          'account_not_empty',
          'A non-empty legacy account must verify its existing records first',
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

  Response _json(
    Object body, {
    int status = 200,
    Map<String, String> headers = const {},
  }) => Response(
    status,
    body: jsonEncode(body),
    headers: {'content-type': 'application/json', ...headers},
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

/// A one-shot retention loop. Scheduling only after each purge settles keeps
/// slow storage from accumulating overlapping global delete transactions.
class _InboxRetentionPurge {
  final Duration interval;
  final Future<void> Function() purge;
  final Timer Function(Duration, void Function()) timerFactory;
  final void Function(Object, StackTrace) onError;

  Timer? _timer;
  Future<void>? _running;
  bool _cancelled = false;

  _InboxRetentionPurge({
    required this.interval,
    required this.purge,
    required this.timerFactory,
    required this.onError,
  });

  void start() => _schedule();

  void _schedule() {
    if (_cancelled) return;
    _timer = timerFactory(interval, _run);
  }

  void _run() {
    if (_cancelled) return;
    _timer = null;
    final running = _purgeOnce();
    _running = running;
    unawaited(
      running.whenComplete(() {
        if (identical(_running, running)) _running = null;
        if (_cancelled) return;
        try {
          _schedule();
        } catch (error, stackTrace) {
          onError(error, stackTrace);
        }
      }),
    );
  }

  Future<void> _purgeOnce() async {
    try {
      await purge();
    } catch (error, stackTrace) {
      onError(error, stackTrace);
    }
  }

  void cancel() {
    _cancelled = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> get done async {
    final running = _running;
    if (running != null) await running;
  }
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
