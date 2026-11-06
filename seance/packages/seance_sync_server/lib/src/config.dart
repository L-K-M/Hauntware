import 'client_address.dart';

import 'package:seance_protocol/seance_protocol.dart';

/// Server settings, sourced from environment variables (with CLI overrides
/// applied in `bin/`). TLS is intentionally not handled here — run behind a
/// reverse proxy, the same shape as Atuin's deployment guidance.
class ServerSettings {
  static const int defaultMaxRecordsPerPull = kDefaultMaxRecordsPerPush;
  static const int defaultMaxPullBodyBytes = kDefaultMaxPushBodyBytes;
  static const int defaultMaxRecordsPerAccount = 5 * kDefaultMaxRecordsPerPush;
  static const int defaultMaxAccountBytes = 5 * kDefaultMaxPushBodyBytes;

  final String bindAddress;
  final int port;

  /// When false, `/v1/register` is refused — lock this down after enrolling
  /// your own devices.
  final bool openRegistration;

  /// Path to the SQLite database, or null for an ephemeral in-memory store.
  final String? dbPath;

  final int loginMaxAttempts;
  final Duration loginWindow;
  final int authGlobalMaxAttempts;
  final Duration authGlobalWindow;
  final int authSourceMaxAttempts;
  final Duration authSourceWindow;
  final int rateLimitMaxBuckets;
  final Set<String> trustedProxies;

  /// Bearer sessions expire and each account keeps only its newest sessions.
  /// Defaults to 30 days and 20 devices/browser sessions.
  final Duration sessionDuration;
  final int maxSessionsPerAccount;

  /// Hard cap on a single request body, which in practice sizes pushes: the
  /// unauthenticated routes read at most 16 KiB, or this if it is lower.
  /// Default 8 MiB.
  final int maxBodyBytes;

  /// Cap on records accepted in one push, and on a single record's encrypted
  /// blob, to bound authenticated abuse. Defaults: 1000 records, 1 MiB blob.
  final int maxRecordsPerPush;
  final int maxBlobBytes;

  /// Bounds one explicitly paged record or inbox response. Legacy record
  /// pulls remain whole-account for older clients, but the account quotas
  /// below put a hard ceiling on those responses too.
  final int maxRecordsPerPull;
  final int maxPullBodyBytes;

  /// Durable storage ceilings per account. The byte ceiling is enforced
  /// independently for sync records and pending inbox items, so a producer
  /// token cannot consume the space needed for the user's record catalog.
  final int maxRecordsPerAccount;
  final int maxAccountBytes;

  /// The push caps as the client sees them. Advertised in every pull response
  /// so a client can split a large dirty set into pushes this deployment
  /// accepts instead of guessing at env-tuned values. The server may
  /// advertise a smaller body cap when required by [maxPullBodyBytes], while
  /// preserving the configured request ceiling here.
  PushLimits get pushLimits => PushLimits(
    maxBodyBytes: maxBodyBytes,
    maxRecordsPerPush: maxRecordsPerPush,
    maxBlobBytes: maxBlobBytes,
  );

  const ServerSettings({
    this.bindAddress = '0.0.0.0',
    this.port = 8787,
    this.openRegistration = false,
    this.dbPath,
    this.loginMaxAttempts = 10,
    this.loginWindow = const Duration(minutes: 1),
    this.authGlobalMaxAttempts = 1000,
    this.authGlobalWindow = const Duration(minutes: 1),
    this.authSourceMaxAttempts = 60,
    this.authSourceWindow = const Duration(minutes: 1),
    this.rateLimitMaxBuckets = 4096,
    this.trustedProxies = const {},
    this.sessionDuration = const Duration(days: 30),
    this.maxSessionsPerAccount = 20,
    this.maxBodyBytes = kDefaultMaxPushBodyBytes,
    this.maxRecordsPerPush = kDefaultMaxRecordsPerPush,
    this.maxBlobBytes = kDefaultMaxBlobBytes,
    this.maxRecordsPerPull = defaultMaxRecordsPerPull,
    this.maxPullBodyBytes = defaultMaxPullBodyBytes,
    this.maxRecordsPerAccount = defaultMaxRecordsPerAccount,
    this.maxAccountBytes = defaultMaxAccountBytes,
  });

  factory ServerSettings.fromEnvironment(Map<String, String> env) {
    bool flag(String key, bool fallback) {
      final v = env[key]?.toLowerCase();
      if (v == null) return fallback;
      return v == '1' || v == 'true' || v == 'yes' || v == 'on';
    }

    /// A cap of zero or less accepts no push at all, and one that is not a
    /// number is a typo rather than an intent; clients now size their batches
    /// against these values, so either would surface as every sync failing
    /// with an opaque 413 — or, for the blob cap, as a DoS guard quietly
    /// weaker than the operator asked for. Refuse to start instead, naming the
    /// variable. An unset variable still takes the default, and `int.tryParse`
    /// already tolerates surrounding whitespace, so a stray newline in an env
    /// file is not a typo. Only these caps are strict; tightening the rest of
    /// this file's settings is a separate change.
    int positiveLimit(String key, int fallback) {
      final raw = env[key];
      // `KEY=` in an env file, an empty Compose interpolation and an empty
      // ConfigMap entry all arrive as the empty string and all mean "unset";
      // refusing to boot over one would be the artifact case again, not a typo.
      if (raw == null || raw.trim().isEmpty) return fallback;
      final value = int.tryParse(raw);
      if (value == null || value <= 0) {
        throw ArgumentError.value(raw, key, 'must be a positive integer');
      }
      return value;
    }

    Set<String> trustedProxyAddresses() {
      final raw = env['SEANCE_TRUSTED_PROXIES'];
      if (raw == null || raw.trim().isEmpty) return const {};
      final result = <String>{};
      for (final entry in raw.split(',')) {
        final value = entry.trim();
        final address = canonicalIpAddress(value);
        if (address == null) {
          throw ArgumentError.value(
            value,
            'SEANCE_TRUSTED_PROXIES',
            'must contain comma-separated IP addresses',
          );
        }
        result.add(address);
      }
      return Set.unmodifiable(result);
    }

    return ServerSettings(
      bindAddress: env['SEANCE_BIND'] ?? '0.0.0.0',
      port: int.tryParse(env['SEANCE_PORT'] ?? '') ?? 8787,
      openRegistration: flag('SEANCE_OPEN_REGISTRATION', false),
      dbPath: env['SEANCE_DB_PATH'],
      loginMaxAttempts: positiveLimit('SEANCE_LOGIN_MAX_ATTEMPTS', 10),
      loginWindow: Duration(
        seconds: positiveLimit('SEANCE_LOGIN_WINDOW_SECONDS', 60),
      ),
      authGlobalMaxAttempts: positiveLimit(
        'SEANCE_AUTH_GLOBAL_MAX_ATTEMPTS',
        1000,
      ),
      authGlobalWindow: Duration(
        seconds: positiveLimit('SEANCE_AUTH_GLOBAL_WINDOW_SECONDS', 60),
      ),
      authSourceMaxAttempts: positiveLimit(
        'SEANCE_AUTH_SOURCE_MAX_ATTEMPTS',
        60,
      ),
      authSourceWindow: Duration(
        seconds: positiveLimit('SEANCE_AUTH_SOURCE_WINDOW_SECONDS', 60),
      ),
      rateLimitMaxBuckets: positiveLimit('SEANCE_RATE_LIMIT_MAX_BUCKETS', 4096),
      trustedProxies: trustedProxyAddresses(),
      sessionDuration: Duration(
        seconds: positiveLimit(
          'SEANCE_SESSION_TTL_SECONDS',
          const Duration(days: 30).inSeconds,
        ),
      ),
      maxSessionsPerAccount: positiveLimit(
        'SEANCE_MAX_SESSIONS_PER_ACCOUNT',
        20,
      ),
      maxBodyBytes: positiveLimit(
        'SEANCE_MAX_BODY_BYTES',
        kDefaultMaxPushBodyBytes,
      ),
      maxRecordsPerPush: positiveLimit(
        'SEANCE_MAX_RECORDS_PER_PUSH',
        kDefaultMaxRecordsPerPush,
      ),
      maxBlobBytes: positiveLimit(
        'SEANCE_MAX_BLOB_BYTES',
        kDefaultMaxBlobBytes,
      ),
      maxRecordsPerPull: positiveLimit(
        'SEANCE_MAX_RECORDS_PER_PULL',
        defaultMaxRecordsPerPull,
      ),
      maxPullBodyBytes: positiveLimit(
        'SEANCE_MAX_PULL_BODY_BYTES',
        defaultMaxPullBodyBytes,
      ),
      maxRecordsPerAccount: positiveLimit(
        'SEANCE_MAX_RECORDS_PER_ACCOUNT',
        defaultMaxRecordsPerAccount,
      ),
      maxAccountBytes: positiveLimit(
        'SEANCE_MAX_ACCOUNT_BYTES',
        defaultMaxAccountBytes,
      ),
    );
  }

  ServerSettings copyWith({
    String? bindAddress,
    int? port,
    bool? openRegistration,
    String? dbPath,
  }) => ServerSettings(
    bindAddress: bindAddress ?? this.bindAddress,
    port: port ?? this.port,
    openRegistration: openRegistration ?? this.openRegistration,
    dbPath: dbPath ?? this.dbPath,
    loginMaxAttempts: loginMaxAttempts,
    loginWindow: loginWindow,
    authGlobalMaxAttempts: authGlobalMaxAttempts,
    authGlobalWindow: authGlobalWindow,
    authSourceMaxAttempts: authSourceMaxAttempts,
    authSourceWindow: authSourceWindow,
    rateLimitMaxBuckets: rateLimitMaxBuckets,
    trustedProxies: trustedProxies,
    sessionDuration: sessionDuration,
    maxSessionsPerAccount: maxSessionsPerAccount,
    maxBodyBytes: maxBodyBytes,
    maxRecordsPerPush: maxRecordsPerPush,
    maxBlobBytes: maxBlobBytes,
    maxRecordsPerPull: maxRecordsPerPull,
    maxPullBodyBytes: maxPullBodyBytes,
    maxRecordsPerAccount: maxRecordsPerAccount,
    maxAccountBytes: maxAccountBytes,
  );
}
