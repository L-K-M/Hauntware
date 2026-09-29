part of 'server.dart';

/// Pending items one app may hold. A producer that keeps proposing while
/// nobody reads them is stopped here rather than filling the database.
const int _inboxMaxPendingPerApp = 100;

/// Apps one account may register. Without it the per-app pending cap bounds
/// nothing: a session could keep adding apps, and every one's queue lands in
/// each `GET /v1/inbox`. The check and the insert are not atomic, so two
/// concurrent registrations can pass it by one; it bounds growth, it is not
/// an exact quota.
const int _inboxMaxAppsPerAccount = 50;

const int _inboxDepositsPerWindow = 30;
const Duration _inboxDepositWindow = Duration(minutes: 1);

/// A sealed proposal is at least its 24-byte nonce and 16-byte tag. Anything
/// shorter cannot open, so it is refused before it takes a slot.
const int _inboxMinBlobBytes = 24 + 16;

/// Salt and hash for a deposit that names no known app, so that case hashes
/// exactly as much as a wrong token does and the two stay indistinguishable.
final List<int> _unknownAppSalt = secureRandomBytes(16);
final String _unknownAppHash = VaultCrypto.hashAuthVerifier(
  secureRandomBytes(32),
  _unknownAppSalt,
);

/// The command inbox handlers (docs/INBOX.md). The server stores sealed
/// blobs it cannot open: the app key lives only in the producer and the
/// user's vault, so this code checks who may *deposit* (the token) but has
/// no say in what Séance believes (the key).
extension _InboxHandlers on SyncServer {
  Future<Response> _createInboxApp(Request req) =>
      _withAuth(req, (username) async {
        final body = await _readJson(req, _authBodyCap);
        if (body == null) return _error(400, 'bad_request', 'Malformed JSON');
        final CreateInboxAppRequest r;
        try {
          r = CreateInboxAppRequest.fromJson(body);
        } catch (_) {
          return _error(400, 'bad_request', 'Invalid app payload');
        }
        if (!isValidInboxAppId(r.appId) || !isValidInboxToken(r.token)) {
          return _error(400, 'bad_request', 'Malformed app id or token');
        }
        final name = r.name.trim();
        if (name.isEmpty ||
            name.length > kInboxMaxNameChars ||
            SyncServer._controlCharacter.hasMatch(name)) {
          return _error(
            400,
            'bad_request',
            'Name must be 1 to $kInboxMaxNameChars characters without '
                'control characters',
          );
        }
        if ((await storage.listInboxApps(username)).length >=
            _inboxMaxAppsPerAccount) {
          return _error(
            429,
            'too_many_apps',
            'The account has $_inboxMaxAppsPerAccount inbox apps; remove one '
                'first',
          );
        }
        // Stored like the auth verifier: a copied database yields no token
        // that could fill the inbox.
        final salt = secureRandomBytes(16);
        final created = await storage.createInboxApp(
          StoredInboxApp(
            username: username,
            appId: r.appId,
            name: name,
            tokenHash: _hashDepositToken(r.token, salt),
            tokenSalt: base64.encode(salt),
            created: _now().millisecondsSinceEpoch,
          ),
        );
        if (!created) {
          return _error(409, 'app_exists', 'App id already registered');
        }
        return _json(const <String, Object>{}, status: 201);
      });

  Future<Response> _listInboxApps(Request req) =>
      _withAuth(req, (username) async {
        // Purged first, so pending counts leave out what already expired.
        await _purgeExpiredInbox();
        final apps = await storage.listInboxApps(username);
        return _json({
          'apps': [for (final app in apps) app.toJson()],
        });
      });

  Future<Response> _deleteInboxApp(Request req, String appId) =>
      _withAuth(req, (username) async {
        if (!await storage.deleteInboxApp(username, appId)) {
          return _error(404, 'not_found', 'No such app');
        }
        return Response(204);
      });

  Future<Response> _listInbox(Request req) => _withAuth(req, (username) async {
    final since = int.tryParse(req.url.queryParameters['since'] ?? '0') ?? 0;
    await _purgeExpiredInbox();
    final items = await storage.inboxItemsSince(username, since);
    return _json({
      'items': [for (final item in items) item.toJson()],
    });
  });

  /// A 404 here is the claim protocol's answer, not an error: the item was
  /// already deleted, usually by another device that ran or dismissed it.
  /// It must stay a 404 with `not_found` for every absent item.
  Future<Response> _deleteInboxItem(Request req, String appId, String itemId) =>
      _withAuth(req, (username) async {
        if (!await storage.deleteInboxItem(username, appId, itemId)) {
          return _error(404, 'not_found', 'No such inbox item');
        }
        return Response(204);
      });

  /// The producer endpoint, the only one a deposit token opens. Order
  /// matters: a declared oversize body is refused before any lookup, the
  /// token is checked before the body is read (so an unauthenticated caller
  /// cannot make the server buffer 96 KiB), and the rate limit counts only
  /// authenticated deposits, so a stranger cannot spend an app's budget.
  Future<Response> _deposit(Request req, String appId) async {
    final cap = min(settings.maxBodyBytes, kInboxMaxBlobBytes);
    final declared = req.contentLength;
    if (declared != null && declared > cap) throw const _PayloadTooLarge();

    if (!await _producerAuthorized(req, appId)) return _depositUnauthorized();
    if (!inboxLimiter.allow('inbox:$appId')) {
      return _error(429, 'rate_limited', 'Too many proposals; slow down');
    }

    final blob = await _readBoundedBytes(req, cap);
    if (blob.length < _inboxMinBlobBytes) {
      return _error(
        400,
        'bad_request',
        'Body must be a sealed proposal of at least $_inboxMinBlobBytes bytes',
      );
    }

    await _purgeExpiredInbox();
    final itemId = uuidV4();
    final result = await storage.addInboxItem(
      appId,
      itemId,
      blob,
      storedAt: _now().millisecondsSinceEpoch,
      maxPending: _inboxMaxPendingPerApp,
    );
    switch (result.status) {
      case InboxAddStatus.added:
        return _json({'item': itemId}, status: 201);
      case InboxAddStatus.full:
        return _error(
          429,
          'inbox_full',
          'The app has $_inboxMaxPendingPerApp pending proposals; wait for '
              'the user to handle some',
        );
      case InboxAddStatus.unknownApp:
        // Removed between the token check and the insert.
        return _depositUnauthorized();
    }
  }

  /// Whether [req] carries [appId]'s deposit token. An unknown app, a
  /// malformed id and a wrong token all cost one hash and one comparison, and
  /// all end in the same 401, so a caller learns nothing about which apps
  /// exist. (The ids are 128 random bits, so the lookup's own timing gives
  /// away nothing guessable either.)
  Future<bool> _producerAuthorized(Request req, String appId) async {
    final auth = req.headers['authorization'];
    // The scheme is case-insensitive (RFC 9110 11.1); hand-written producer
    // clients are the ones likely to send `bearer`.
    final token = auth != null && auth.toLowerCase().startsWith('bearer ')
        ? auth.substring(7).trim()
        : '';
    final app = isValidInboxAppId(appId)
        ? await storage.getInboxApp(appId)
        : null;
    final salt = app == null
        ? _unknownAppSalt
        : _tryBase64Decode(app.tokenSalt);
    if (salt == null) {
      throw StateError('Stored token salt is invalid for app $appId');
    }
    final provided = _hashDepositToken(token, salt);
    final expected = app?.tokenHash ?? _unknownAppHash;
    final matches = SyncServer._constantTimeEquals(provided, expected);
    return app != null && matches;
  }

  Response _depositUnauthorized() =>
      _error(401, 'unauthorized', 'Unknown app or wrong token');

  /// The auth verifier's scheme, sha256(salt || token), over the token as
  /// sent. It carries 256 random bits, so no slow KDF is needed.
  String _hashDepositToken(String token, List<int> salt) =>
      VaultCrypto.hashAuthVerifier(utf8.encode(token), salt);

  /// Drops items older than [kInboxRetention]. The server cannot read a
  /// proposal's own `expires`, so it keeps each item for the cap on it.
  /// Run on the inbox requests themselves, which needs no timer and keeps a
  /// list from ever returning an expired item.
  Future<void> _purgeExpiredInbox() => storage.purgeInboxItems(
    storedBefore: _now().subtract(kInboxRetention).millisecondsSinceEpoch + 1,
  );

  Response _static(String body, String type) =>
      Response.ok(body, headers: {'content-type': '$type; charset=utf-8'});
}
