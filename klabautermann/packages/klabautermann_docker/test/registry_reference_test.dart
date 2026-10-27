import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

const String _digest =
    'sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f';

HttpHeaders _headers(Map<String, String> m) =>
    HttpHeaders(m.entries.map((e) => (e.key, e.value)));

/// The registry side of an update check (03 §7.14 IMG-05, D68).
void main() {
  group('RegistryReference', () {
    test('Docker Hub official images gain library/ and the default tag', () {
      final r = RegistryReference.tryParse('alpine')!;
      expect(r.registry, dockerHubRegistry);
      expect(r.repository, 'library/alpine');
      expect(r.tag, 'latest');
      expect(r.familiarName, 'alpine');
      expect(r.isDockerHub, isTrue);
      expect(r.isPinned, isFalse);
    });

    test('docker.io prefixes and user namespaces keep Docker\'s familiar '
        'name', () {
      final r = RegistryReference.tryParse('docker.io/grafana/grafana:11.2')!;
      expect(r.registry, dockerHubRegistry);
      expect(r.repository, 'grafana/grafana');
      expect(r.tag, '11.2');
      expect(r.familiarName, 'grafana/grafana');

      final official = RegistryReference.tryParse('docker.io/library/nginx')!;
      expect(official.repository, 'library/nginx');
      expect(official.familiarName, 'nginx');
    });

    test('a host component is a dot, a port or localhost', () {
      final ghcr = RegistryReference.tryParse(
        'ghcr.io/home-assistant/home-assistant:stable',
      )!;
      expect(ghcr.registry, 'ghcr.io');
      expect(ghcr.repository, 'home-assistant/home-assistant');
      expect(ghcr.familiarName, 'ghcr.io/home-assistant/home-assistant');

      final local = RegistryReference.tryParse('localhost:5000/alpine:3.22')!;
      expect(local.registry, 'localhost:5000');
      expect(local.repository, 'alpine');
      expect(local.tag, '3.22');
      expect(local.familiarName, 'localhost:5000/alpine');

      final bare = RegistryReference.tryParse('localhost/app')!;
      expect(bare.registry, 'localhost');

      // `acme` has no dot or port, so it is a Docker Hub namespace.
      final namespace = RegistryReference.tryParse('acme/api')!;
      expect(namespace.registry, dockerHubRegistry);
      expect(namespace.repository, 'acme/api');
    });

    test('a digest pin is kept and marks the reference pinned', () {
      final r = RegistryReference.tryParse('alpine:3.22@$_digest')!;
      expect(r.isPinned, isTrue);
      expect(r.digest, _digest);
      expect(r.tag, '3.22');
    });

    test('invalid references are refused', () {
      for (final bad in [
        '',
        'Alpine',
        'alpine:',
        'alpine@sha256:abc',
        'ghcr.io/',
        'a//b',
        'alpine:bad tag',
      ]) {
        expect(RegistryReference.tryParse(bad), isNull, reason: bad);
      }
    });
  });

  group('RegistryChallenge', () {
    test('a Bearer challenge names the anonymous token request', () {
      final c = RegistryChallenge.tryParse(
        'Bearer realm="https://ghcr.io/token",service="ghcr.io",'
        'scope="repository:home-assistant/home-assistant:pull"',
      )!;
      expect(c.scheme, RegistryAuthScheme.bearer);
      expect(c.service, 'ghcr.io');
      expect(
        c.anonymousTokenUri('home-assistant/home-assistant').toString(),
        'https://ghcr.io/token?service=ghcr.io'
        '&scope=repository%3Ahome-assistant%2Fhome-assistant%3Apull',
      );
    });

    test('a Basic challenge means credentials, with no token to fetch', () {
      final c = RegistryChallenge.tryParse('Basic realm="s8"')!;
      expect(c.scheme, RegistryAuthScheme.basic);
      expect(c.realm, 's8');
      expect(c.anonymousTokenUri('alpine'), isNull);
    });

    test('a realm that is not https is not followed', () {
      final c = RegistryChallenge.tryParse(
        'Bearer realm="http://registry.example/token",service="x"',
      )!;
      expect(c.anonymousTokenUri('alpine'), isNull);
      expect(RegistryChallenge.tryParse(''), isNull);
      expect(RegistryChallenge.tryParse(null), isNull);
    });
  });

  group('RegistryRateLimit', () {
    test('reads Docker Hub\'s count and window', () {
      final limit = RegistryRateLimit.fromHeaders(
        _headers({
          'ratelimit-limit': '100;w=3600',
          'ratelimit-remaining': '57;w=3600',
        }),
      )!;
      expect(limit.limit, 100);
      expect(limit.remaining, 57);
      expect(limit.window, const Duration(hours: 1));
      expect(limit.isSpent, isFalse);
    });

    test('zero remaining is spent; no headers is no limit', () {
      final spent = RegistryRateLimit.fromHeaders(
        _headers({'ratelimit-remaining': '0;w=3600'}),
      )!;
      expect(spent.isSpent, isTrue);
      expect(RegistryRateLimit.fromHeaders(_headers({})), isNull);
    });
  });
}
