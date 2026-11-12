import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:seance_protocol/seance_protocol.dart';

import '../inbox/inbox_api.dart';
import 'legacy_envelope_migration.dart';
import 'stall_guarded_transfer.dart';
import 'sync_engine.dart';

/// HTTP client for the Séance sync server. Handles account setup and auth, then
/// serves as the [SyncApi] the [SyncEngine] drives. All record payloads are
/// already end-to-end encrypted before they reach this layer.
class HttpSyncClient
    implements
        SyncApi,
        PagedSyncApi,
        LegacyMigrationApi,
        InboxApi,
        PagedInboxApi {
  final String baseUrl;
  final http.Client _client;
  final bool _ownsClient;
  bool _closed = false;

  /// Descriptive installation metadata for newly issued sessions. Omit both
  /// fields when communicating for a client without a stable installation id.
  final String? deviceId;
  final String? deviceName;

  /// Per-request timeout. Without one, a hung connection would leave
  /// `AppState.syncing` stuck true forever (spinner frozen, auto-sync wedged
  /// because it early-returns while a round is "in progress").
  ///
  /// Record and inbox pages and pushes can be several MiB, more than a slow
  /// link moves in this time, so for them it is an idle limit instead: the
  /// longest wait for the next upload chunk, the response headers or the next
  /// response chunk. [maxTransferDuration] bounds the whole of such a
  /// transfer.
  final Duration timeout;

  /// Upper bound on one record or inbox transfer that keeps making progress.
  /// Ten minutes moves an 8 MiB page at about 115 kbit/s.
  final Duration maxTransferDuration;

  /// The session bearer token, set by [register]/[login]. Public so the app can
  /// persist and restore it across launches.
  String? token;

  HttpSyncClient({
    required String baseUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    this.maxTransferDuration = const Duration(minutes: 10),
    this.deviceId,
    this.deviceName,
  }) : baseUrl = normalizeBaseUrl(baseUrl),
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  /// Release owned connections. Injected clients remain caller-owned.
  /// Repeated calls are harmless; this wrapper cannot be reused afterwards.
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close();
  }

  /// Paths are appended verbatim, so a pasted "https://host/" would produce
  /// "https://host//v1/..." and 404.
  static String normalizeBaseUrl(String url) {
    var normalized = url.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  Map<String, String> get _authHeaders => {
        'content-type': 'application/json',
        'x-seance-protocol-version': '$kProtocolVersion',
        if (token != null) 'authorization': 'Bearer $token',
      };

  Map<String, String> get _enrollmentHeaders => {
    'content-type': 'application/json',
    if (deviceId != null) 'x-seance-device-id': deviceId!,
    if (deviceName != null) 'x-seance-device-name': deviceName!,
  };

  /// A record or inbox page or push: see [timeout].
  Future<http.Response> _transfer(String method, Uri url, {String? body}) =>
      sendStallGuarded(
        _client,
        method: method,
        url: url,
        // `package:http` adds the charset when it encodes a string body.
        headers: {
          ..._authHeaders,
          if (body != null) 'content-type': 'application/json; charset=utf-8',
        },
        body: body == null ? null : utf8.encode(body),
        idleTimeout: timeout,
        totalTimeout: maxTransferDuration,
      );

  Uri _uri(String path, [Map<String, String>? query]) {
    if (_closed) throw StateError('Sync client is closed');
    return Uri.parse('$baseUrl$path').replace(queryParameters: query);
  }

  Never _fail(http.Response res) {
    // The server's own errors are JSON with an `error` code. Anything else —
    // an HTML error page, a CDN's plain-text body, a JSON scalar — came from
    // whatever sits in front of the server (or from a URL that is not a
    // Séance server), so describe the failure instead of echoing the body.
    Object? decoded;
    try {
      decoded = jsonDecode(res.body);
    } catch (_) {
      decoded = null;
    }
    if (decoded is Map<String, dynamic> && decoded['error'] is String) {
      throw ApiError.fromJson(decoded);
    }
    throw ApiError(
      code: 'http_${res.statusCode}',
      message: _describeHttpFailure(res.statusCode, res.body),
    );
  }

  static String _describeHttpFailure(int status, String body) {
    switch (status) {
      case 502:
        return 'The reverse proxy could not reach the sync server — it looks '
            'stopped, crashed, or unreachable on its published port.';
      case 503:
        return 'The sync server is unavailable — it may be restarting or '
            'overloaded.';
      case 504:
        return 'The reverse proxy timed out waiting for the sync server.';
      default:
        final snippet = _sanitizeBody(body);
        return snippet.isEmpty
            ? 'Unexpected response with an empty body.'
            : 'Unexpected response: $snippet';
    }
  }

  /// Strip markup and collapse whitespace so a proxy's HTML error page renders
  /// as one short readable line in the app, not tag soup.
  static String _sanitizeBody(String body) {
    var text = body
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    const cap = 160;
    if (text.length > cap) text = '${text.substring(0, cap)}…';
    return text;
  }

  /// Create an account and receive a session token.
  Future<LoginResponse> register(RegisterRequest request) async {
    final res = await _client
        .post(
          _uri('/v1/register'),
          headers: _enrollmentHeaders,
          body: jsonEncode(request.toJson()),
        )
        .timeout(timeout);
    if (res.statusCode >= 400) _fail(res);
    final response = LoginResponse.fromJson(
      jsonDecode(res.body) as Map<String, dynamic>,
    );
    token = response.token;
    return response;
  }

  /// Fetch the KDF salt/params for a username so a new device can derive keys.
  Future<PreloginResponse> prelogin(String username) async {
    final res = await _client
        .post(_uri('/v1/prelogin'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'username': username}))
        .timeout(timeout);
    if (res.statusCode >= 400) _fail(res);
    return PreloginResponse.fromJson(
        jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Exchange the auth verifier for a session token.
  Future<LoginResponse> login(LoginRequest request) async {
    final res = await _client
        .post(
          _uri('/v1/login'),
          headers: _enrollmentHeaders,
          body: jsonEncode(request.toJson()),
        )
        .timeout(timeout);
    if (res.statusCode >= 400) _fail(res);
    final response = LoginResponse.fromJson(
      jsonDecode(res.body) as Map<String, dynamic>,
    );
    token = response.token;
    return response;
  }

  Future<void> deleteAccount() async {
    final res = await _client
        .delete(_uri('/v1/account'), headers: _authHeaders)
        .timeout(timeout);
    if (res.statusCode >= 400) _fail(res);
    token = null;
  }

  /// Revoke this device's bearer session without affecting other devices.
  Future<void> revokeSession() async {
    final res = await _client
        .delete(_uri('/v1/session'), headers: _authHeaders)
        .timeout(timeout);
    if (res.statusCode >= 400) _fail(res);
    token = null;
  }

  /// Revoke every bearer session for the account, including this one.
  Future<void> revokeAllSessions() async {
    final res = await _client
        .delete(_uri('/v1/sessions'), headers: _authHeaders)
        .timeout(timeout);
    if (res.statusCode >= 400) _fail(res);
    token = null;
  }

  Future<List<SyncSessionInfo>> listSessions() async {
    final res = await _client
        .get(_uri('/v1/sessions'), headers: _authHeaders)
        .timeout(timeout);
    if (res.statusCode >= 400) _fail(res);
    return SyncSessionsResponse.fromJson(
      jsonDecode(res.body) as Map<String, dynamic>,
    ).sessions;
  }

  /// Revoke an opaque session id. Only a successful revocation of this
  /// client's own session clears the local bearer; an absent target is false.
  Future<bool> revokeSessionById(String sessionId) async {
    final res = await _client
        .delete(
          _uri('/v1/sessions/${Uri.encodeComponent(sessionId)}'),
          headers: _authHeaders,
        )
        .timeout(timeout);
    if (res.statusCode == 404) {
      try {
        _fail(res);
      } on ApiError catch (error) {
        if (error.code == _notFound) return false;
        rethrow;
      }
    }
    if (res.statusCode >= 400) _fail(res);
    final result = RevokeSessionResponse.fromJson(
      jsonDecode(res.body) as Map<String, dynamic>,
    );
    if (result.current && result.revoked) token = null;
    return result.revoked;
  }

  /// Initialize the authenticated marker for an empty legacy account.
  /// The server sets it once and returns a concurrent winner unchanged.
  Future<String> initializeVaultKeyCheck(String vaultKeyCheck) async {
    final res = await _client
        .put(
          _uri('/v1/account/vault-key-check'),
          headers: _authHeaders,
          body: jsonEncode({'vaultKeyCheck': vaultKeyCheck}),
        )
        .timeout(timeout);
    if (res.statusCode >= 400) _fail(res);
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return json['vaultKeyCheck'] as String;
  }

  @override
  Future<PullResponse> pull({required int since}) async {
    final records = <EncryptedRecord>[];
    PushLimits? limits;
    int? through;
    int? recordEnvelopeFloor;
    var cursor = since;
    var latestSeq = since;
    while (true) {
      final page = await pullPage(since: cursor, throughSeq: through);
      final pageThrough = page.throughSeq;
      if (pageThrough == null) {
        if (through != null || page.hasMore) {
          throw const FormatException('Sync page lost its snapshot watermark');
        }
      } else {
        through ??= pageThrough;
        if (pageThrough != through ||
            pageThrough < since ||
            page.latestSeq != pageThrough) {
          throw const FormatException(
              'Sync page changed its snapshot watermark');
        }
      }

      var observed = cursor;
      for (final record in page.records) {
        final seq = record.seq;
        final upper = pageThrough ?? page.latestSeq;
        if (seq == null || seq <= observed || seq > upper) {
          throw const FormatException('Sync page records are not monotonic');
        }
        observed = seq;
      }
      if (page.hasMore &&
          (pageThrough == null ||
              observed == cursor ||
              observed >= pageThrough)) {
        throw const FormatException('Sync page did not make progress');
      }

      records.addAll(page.records);
      recordEnvelopeFloor ??= page.recordEnvelopeFloor;
      if (page.recordEnvelopeFloor != recordEnvelopeFloor) {
        throw const FormatException(
          'Sync page changed its record envelope floor',
        );
      }
      limits = page.limits ?? limits;
      latestSeq = page.latestSeq;
      if (!page.hasMore) {
        return PullResponse(
          records: records,
          latestSeq: latestSeq,
          limits: limits,
          throughSeq: through,
          recordEnvelopeFloor: recordEnvelopeFloor,
        );
      }
      cursor = observed;
    }
  }

  @override
  Future<PullResponse> pullPage({required int since, int? throughSeq}) async {
    final res = await _transfer(
      'GET',
      _uri('/v1/sync', {
        'since': '$since',
        'page': '1',
        'protocolVersion': '$kProtocolVersion',
        if (throughSeq != null) 'through': '$throughSeq',
      }),
    );
    if (res.statusCode >= 400) {
      try {
        _fail(res);
      } on ApiError catch (error) {
        if (error.code == 'cursor_rejected') {
          throw SyncCursorRejectedException(error.message);
        }
        rethrow;
      }
    }
    return PullResponse.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
    final res = await _transfer(
      'PUT',
      _uri('/v1/records'),
      // Opting in to per-record refusals lets a full account still take
      // edits to records it holds. An older server ignores the field and
      // refuses the whole push instead, which the callers already handle.
      body: jsonEncode(
        PushRequest(
          records: records,
          refusalScope: PushRefusalScope.record,
        ).toJson(),
      ),
    );
    if (res.statusCode >= 400) _fail(res);
    return PushResponse.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  @override
  Future<LegacyRecordPage> pullLegacyPage({String? afterId}) async {
    final res = await _transfer(
      'GET',
      _uri('/v1/records/legacy', {
        if (afterId != null) 'after': afterId,
      }),
    );
    if (res.statusCode >= 400) _fail(res);
    return LegacyRecordPage.fromJson(
      jsonDecode(res.body) as Map<String, dynamic>,
    );
  }

  @override
  Future<LegacyMigrationResponse> migrateLegacy(
    List<LegacyRecordMigration> migrations, {
    bool finalize = false,
  }) async {
    final res = await _transfer(
      'PUT',
      _uri('/v1/records/legacy'),
      body: jsonEncode(
        LegacyMigrationRequest(
          migrations: migrations,
          finalize: finalize,
        ).toJson(),
      ),
    );
    if (res.statusCode >= 400) _fail(res);
    return LegacyMigrationResponse.fromJson(
      jsonDecode(res.body) as Map<String, dynamic>,
    );
  }

  @override
  Future<void> createApp(CreateInboxAppRequest request) async {
    final res = await _client
        .post(_uri('/v1/apps'),
            headers: _authHeaders, body: jsonEncode(request.toJson()))
        .timeout(timeout);
    if (res.statusCode >= 400) _fail(res);
  }

  @override
  Future<List<InboxAppInfo>> listApps() async {
    final res =
        await _client.get(_uri('/v1/apps'), headers: _authHeaders).timeout(
              timeout,
            );
    if (res.statusCode >= 400) _fail(res);
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return [
      for (final app in json['apps'] as List)
        InboxAppInfo.fromJson((app as Map).cast()),
    ];
  }

  @override
  Future<bool> deleteApp(String appId) =>
      _deleteReportingAbsence(_uri('/v1/apps/${Uri.encodeComponent(appId)}'));

  @override
  Future<List<InboxItem>> listItems({required int since}) async {
    final items = <InboxItem>[];
    await for (final page in listItemPages(since: since)) {
      items.addAll(page.items);
    }
    return items;
  }

  @override
  Stream<InboxPage> listItemPages({required int since}) async* {
    int? through;
    var cursor = since;
    while (true) {
      final page = await _listItemPage(since: cursor, through: through);
      final pageThrough = page.throughReceived;
      final next = page.nextReceived;
      if (pageThrough == null) {
        if (through != null || page.hasMore) {
          throw const FormatException(
              'Inbox page lost its snapshot watermark');
        }
      } else {
        through ??= pageThrough;
        if (pageThrough != through || pageThrough < since || next == null) {
          throw const FormatException(
              'Inbox page changed its snapshot watermark');
        }
      }

      var observed = cursor;
      for (final item in page.items) {
        final upper = pageThrough ?? next ?? item.received;
        if (item.received <= observed || item.received > upper) {
          throw const FormatException('Inbox page items are not monotonic');
        }
        observed = item.received;
      }
      if (next != null &&
          (next != observed ||
              next < cursor ||
              (pageThrough != null && next > pageThrough))) {
        throw const FormatException('Inbox page continuation is invalid');
      }
      final continuation = next ?? observed;
      if (page.hasMore &&
          (pageThrough == null ||
              continuation <= cursor ||
              continuation >= pageThrough)) {
        throw const FormatException('Inbox page did not make progress');
      }

      yield page;
      if (!page.hasMore) return;
      cursor = continuation;
    }
  }

  Future<InboxPage> _listItemPage({
    required int since,
    int? through,
  }) async {
    final res = await _transfer(
      'GET',
      _uri('/v1/inbox', {
        'since': '$since',
        'page': '1',
        'protocolVersion': '$kProtocolVersion',
        if (through != null) 'through': '$through',
      }),
    );
    if (res.statusCode >= 400) _fail(res);
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final items = <InboxItem>[];
    // One malformed entry must not hide every other proposal, so it is
    // skipped rather than failing the whole list.
    for (final item in json['items'] as List) {
      try {
        items.add(InboxItem.fromJson((item as Map).cast()));
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
    final throughValue = json['throughReceived'];
    if (throughValue == null) {
      if (json['hasMore'] != null || json['nextReceived'] != null) {
        throw const FormatException('Inbox page lost its snapshot watermark');
      }
      items.sort((a, b) => a.received.compareTo(b.received));
      return InboxPage(items: items);
    }
    final nextValue = json['nextReceived'];
    final hasMoreValue = json['hasMore'];
    if (throughValue is! num ||
        nextValue is! num ||
        hasMoreValue is! bool) {
      throw const FormatException('Inbox page metadata is malformed');
    }
    return InboxPage(
      items: items,
      throughReceived: throughValue.toInt(),
      nextReceived: nextValue.toInt(),
      hasMore: hasMoreValue,
    );
  }

  @override
  Future<bool> deleteItem(String appId, String itemId) =>
      _deleteReportingAbsence(_uri(
        '/v1/inbox/${Uri.encodeComponent(appId)}/'
        '${Uri.encodeComponent(itemId)}',
      ));

  /// A 404 counts as "already gone" only when the server itself says so
  /// (`not_found`). A plain 404 is a server too old to have the route, or a
  /// proxy in the way, and reading that as "another device claimed it" would
  /// quietly drop the user's proposal.
  Future<bool> _deleteReportingAbsence(Uri uri) async {
    final res =
        await _client.delete(uri, headers: _authHeaders).timeout(timeout);
    if (res.statusCode < 400) return true;
    if (res.statusCode == 404) {
      try {
        _fail(res);
      } on ApiError catch (error) {
        if (error.code == _notFound) return false;
        rethrow;
      }
    }
    _fail(res);
  }
}

const String _notFound = 'not_found';
