import 'package:seance_protocol/seance_protocol.dart';

import 'client_address.dart';

/// Server settings, sourced from environment variables (with CLI overrides
/// applied in `bin/`). TLS is intentionally not handled here — run behind a
/// reverse proxy, the same shape as Atuin's deployment guidance.
class ServerSettings {
  final String bindAddress;
  final int port;

  /// When false, `/v1/register` is refused — lock this down after enrolling
  /// your own devices.
  final bool openRegistration;

  /// Path to the SQLite database, or null for an ephemeral in-memory store.
  final String? dbPath;

  final int loginMaxAttempts;
  final Duration loginWindow;

  /// Authentication traffic limits. The global layer prevents distributed
  /// key churn from bypassing bounded per-client buckets; the client layer
  /// covers register, prelogin, and login before expensive storage or hashes.
  final int authGlobalMaxAttempts;
  final int authClientMaxAttempts;
  final int rateLimitMaxBuckets;

  /// Immediate reverse proxies whose `X-Forwarded-For` chain may be trusted.
  /// Entries are canonical numeric IP addresses, never hostnames or CIDRs.
  final Set<String> trustedProxies;

  /// Hard cap on a single request body, which in practice sizes pushes: the
  /// unauthenticated routes read at most 16 KiB, or this if it is lower.
  /// Default 8 MiB.
  final int maxBodyBytes;

  /// Cap on records accepted in one push, and on a single record's encrypted
  /// blob, to bound authenticated abuse. Defaults: 1000 records, 1 MiB blob.
  final int maxRecordsPerPush;
  final int maxBlobBytes;

  /// The push caps as the client sees them. Advertised in every pull response
  /// so a client can split a large dirty set into pushes this deployment
  /// accepts instead of guessing at env-tuned values.
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
    this.authGlobalMaxAttempts = 2000,
    this.authClientMaxAttempts = 120,
    this.rateLimitMaxBuckets = 4096,
    this.trustedProxies = const {},
    this.maxBodyBytes = kDefaultMaxPushBodyBytes,
    this.maxRecordsPerPush = kDefaultMaxRecordsPerPush,
    this.maxBlobBytes = kDefaultMaxBlobBytes,
  });

  factory ServerSettings.fromEnvironment(Map<String, String> env) {
    bool flag(String key, bool fallback) {
      final v = env[key]?.toLowerCase();
      if (v == null) return fallback;
      return v == '1' || v == 'true' || v == 'yes' || v == 'on';
    }

    /// A cap of zero or less accepts nothing, and one that is not a number is a
    /// typo rather than an intent. Refuse to start instead, naming the
    /// variable. An unset variable still takes the default, and `int.tryParse`
    /// already tolerates surrounding whitespace, so a stray newline in an env
    /// file is not a typo.
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

    Set<String> trustedProxySet() {
      const key = 'SEANCE_TRUSTED_PROXIES';
      final raw = env[key];
      if (raw == null || raw.trim().isEmpty) return const {};
      final result = <String>{};
      for (final entry in raw.split(',')) {
        final address = canonicalIpAddress(entry.trim());
        if (address == null) {
          throw ArgumentError.value(
            raw,
            key,
            'must be a comma-separated list of numeric IP addresses',
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
        2000,
      ),
      authClientMaxAttempts: positiveLimit(
        'SEANCE_AUTH_CLIENT_MAX_ATTEMPTS',
        120,
      ),
      rateLimitMaxBuckets: positiveLimit('SEANCE_RATE_LIMIT_MAX_BUCKETS', 4096),
      trustedProxies: trustedProxySet(),
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
    );
  }

  ServerSettings copyWith({
    String? bindAddress,
    int? port,
    bool? openRegistration,
    String? dbPath,
  }) =>
      ServerSettings(
        bindAddress: bindAddress ?? this.bindAddress,
        port: port ?? this.port,
        openRegistration: openRegistration ?? this.openRegistration,
        dbPath: dbPath ?? this.dbPath,
        loginMaxAttempts: loginMaxAttempts,
        loginWindow: loginWindow,
        authGlobalMaxAttempts: authGlobalMaxAttempts,
        authClientMaxAttempts: authClientMaxAttempts,
        rateLimitMaxBuckets: rateLimitMaxBuckets,
        trustedProxies: trustedProxies,
        maxBodyBytes: maxBodyBytes,
        maxRecordsPerPush: maxRecordsPerPush,
        maxBlobBytes: maxBlobBytes,
      );
}
