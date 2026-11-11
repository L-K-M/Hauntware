import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:test/test.dart';

/// Regression coverage for the authentication and rate-limit settings that
/// `ServerSettings.fromEnvironment` accepts.
///
/// These settings were introduced with the bounded auth rate limits. A typo in
/// an env file must stop startup with the offending variable named, rather than
/// quietly running a wider limiter than the operator asked for. A trusted-proxy
/// entry must be an exact IP: a hostname would let anyone claim to be a proxy,
/// and a CIDR range would trust a whole network.
void main() {
  const limiterKeys = [
    'SEANCE_LOGIN_MAX_ATTEMPTS',
    'SEANCE_LOGIN_WINDOW_SECONDS',
    'SEANCE_AUTH_GLOBAL_MAX_ATTEMPTS',
    'SEANCE_AUTH_GLOBAL_WINDOW_SECONDS',
    'SEANCE_AUTH_SOURCE_MAX_ATTEMPTS',
    'SEANCE_AUTH_SOURCE_WINDOW_SECONDS',
    'SEANCE_RATE_LIMIT_MAX_BUCKETS',
  ];

  group('authentication limiter settings', () {
    test('reject zero, negative, and non-numeric values naming the key', () {
      for (final key in limiterKeys) {
        for (final value in const ['0', '-1', 'lots', '4096b', '1_000_000']) {
          // A cap of zero or less accepts no auth attempt at all, and one that
          // is not a number is a typo rather than an intent. Both must be
          // refused at startup, and the error must name the variable.
          expect(
            () => ServerSettings.fromEnvironment({key: value}),
            throwsA(
              isA<ArgumentError>().having((error) => error.name, 'name', key),
            ),
            reason: '$key=$value',
          );
        }
      }
    });

    test('accept positive values, including surrounding whitespace', () {
      // Env files pick up trailing newlines and indentation; that must not
      // stop the server or silently change the value.
      final settings = ServerSettings.fromEnvironment(const {
        'SEANCE_LOGIN_MAX_ATTEMPTS': ' 7\n',
        'SEANCE_LOGIN_WINDOW_SECONDS': ' 90 ',
        'SEANCE_AUTH_GLOBAL_MAX_ATTEMPTS': ' 250\n',
        'SEANCE_AUTH_GLOBAL_WINDOW_SECONDS': ' 120 ',
        'SEANCE_AUTH_SOURCE_MAX_ATTEMPTS': ' 30\n',
        'SEANCE_AUTH_SOURCE_WINDOW_SECONDS': ' 45 ',
        'SEANCE_RATE_LIMIT_MAX_BUCKETS': ' 1024\n',
      });

      expect(settings.loginMaxAttempts, 7);
      expect(settings.loginWindow, const Duration(seconds: 90));
      expect(settings.authGlobalMaxAttempts, 250);
      expect(settings.authGlobalWindow, const Duration(seconds: 120));
      expect(settings.authSourceMaxAttempts, 30);
      expect(settings.authSourceWindow, const Duration(seconds: 45));
      expect(settings.rateLimitMaxBuckets, 1024);
    });

    test(
      'missing, empty, and whitespace-only values keep documented defaults',
      () {
        // `KEY=` in an env file, an empty Compose interpolation and an empty
        // ConfigMap entry all arrive as the empty string and all mean "unset".
        final empty = ServerSettings.fromEnvironment(const {
          'SEANCE_LOGIN_MAX_ATTEMPTS': '',
          'SEANCE_LOGIN_WINDOW_SECONDS': '',
          'SEANCE_AUTH_GLOBAL_MAX_ATTEMPTS': '',
          'SEANCE_AUTH_GLOBAL_WINDOW_SECONDS': '',
          'SEANCE_AUTH_SOURCE_MAX_ATTEMPTS': '',
          'SEANCE_AUTH_SOURCE_WINDOW_SECONDS': '',
          'SEANCE_RATE_LIMIT_MAX_BUCKETS': '',
        });
        final whitespace = ServerSettings.fromEnvironment(const {
          'SEANCE_LOGIN_MAX_ATTEMPTS': '  ',
          'SEANCE_LOGIN_WINDOW_SECONDS': '\t',
          'SEANCE_AUTH_GLOBAL_MAX_ATTEMPTS': ' ',
          'SEANCE_AUTH_GLOBAL_WINDOW_SECONDS': '  ',
          'SEANCE_AUTH_SOURCE_MAX_ATTEMPTS': '\t',
          'SEANCE_AUTH_SOURCE_WINDOW_SECONDS': ' ',
          'SEANCE_RATE_LIMIT_MAX_BUCKETS': '  ',
        });
        final unset = ServerSettings.fromEnvironment(const {});

        for (final settings in [empty, whitespace, unset]) {
          expect(settings.loginMaxAttempts, 10);
          expect(settings.loginWindow, const Duration(minutes: 1));
          expect(settings.authGlobalMaxAttempts, 1000);
          expect(settings.authGlobalWindow, const Duration(minutes: 1));
          expect(settings.authSourceMaxAttempts, 60);
          expect(settings.authSourceWindow, const Duration(minutes: 1));
          expect(settings.rateLimitMaxBuckets, 4096);
        }
      },
    );
  });

  group('trusted proxy settings', () {
    test('trims exact IP addresses, IPv4 and IPv6', () {
      final settings = ServerSettings.fromEnvironment(const {
        'SEANCE_TRUSTED_PROXIES': '192.0.2.1, 2001:db8::1',
      });
      expect(settings.trustedProxies, {'192.0.2.1', '2001:db8::1'});
    });

    test('canonicalizes IPv4-mapped IPv6 addresses to IPv4', () {
      final settings = ServerSettings.fromEnvironment(const {
        'SEANCE_TRUSTED_PROXIES': '::ffff:192.0.2.1, ::ffff:cb00:7104',
      });
      expect(settings.trustedProxies, {'192.0.2.1', '203.0.113.4'});
    });

    test('deduplicates repeated and equivalent entries', () {
      final settings = ServerSettings.fromEnvironment(const {
        'SEANCE_TRUSTED_PROXIES': '192.0.2.1, 192.0.2.1, ::ffff:192.0.2.1',
      });
      expect(settings.trustedProxies, {'192.0.2.1'});
    });

    test('accepts CIDR ranges in canonical form', () {
      final settings = ServerSettings.fromEnvironment(const {
        'SEANCE_TRUSTED_PROXIES': '172.17.0.1/16, 192.0.2.1, 2001:db8::/32',
      });
      expect(settings.trustedProxies, {
        '172.17.0.0/16',
        '192.0.2.1',
        '2001:db8::/32',
      });
    });

    test('rejects hostnames, bad ranges, and empty CSV entries', () {
      for (final value in const [
        'proxy.example.com',
        '192.0.2.0/33',
        '0.0.0.0/0',
        '192.0.2.1,,203.0.113.4',
        '192.0.2.1, ',
      ]) {
        expect(
          () =>
              ServerSettings.fromEnvironment({'SEANCE_TRUSTED_PROXIES': value}),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.name,
              'name',
              'SEANCE_TRUSTED_PROXIES',
            ),
          ),
          reason: value,
        );
      }
    });

    test('an unset or empty setting yields an empty set', () {
      expect(ServerSettings.fromEnvironment(const {}).trustedProxies, isEmpty);
      for (final value in const ['', '  ']) {
        expect(
          ServerSettings.fromEnvironment({
            'SEANCE_TRUSTED_PROXIES': value,
          }).trustedProxies,
          isEmpty,
          reason: value,
        );
      }
    });
  });
}
