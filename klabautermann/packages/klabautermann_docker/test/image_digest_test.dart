import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

const String localDigest =
    'sha256:abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd';

const String otherDigest =
    'sha256:2222222222222222222222222222222222222222222222222222222222222222';

// alpine:3.22's index and its amd64 child, as spike S8 read them.
const String s8Index =
    'sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f';
const String s8Amd64 =
    'sha256:dc92f017beea8e7f43263073d717f7bc011228c95d5312e440deb4d035bb4eec';

HttpHeaders headers(Map<String, String> m) =>
    HttpHeaders(m.entries.map((e) => (e.key, e.value)));

void main() {
  group('parseRegistryHead (03 §7.14 IMG-05)', () {
    test('reads the Docker-Content-Digest and media type', () {
      final r = parseRegistryHead(
        statusCode: 200,
        headers: headers({
          'Docker-Content-Digest': localDigest,
          'Content-Type': 'application/vnd.oci.image.manifest.v1+json',
        }),
      );
      expect(r.warnings, isEmpty);
      expect(r.value.digest, localDigest);
      expect(r.value.mediaType, contains('manifest'));
      expect(r.value.isSuccess, isTrue);
    });

    test('warns when a successful HEAD has no digest', () {
      final r = parseRegistryHead(statusCode: 200, headers: headers({}));
      expect(r.value.digest, isNull);
      expect(r.warnings, isNotEmpty);
    });
  });

  group('compareImageDigest (03 §7.14 IMG-05)', () {
    test('a matching digest is up to date', () {
      final c = compareImageDigest(
        repoDigests: ['alpine@$localDigest'],
        repository: 'alpine',
        tag: '3.21',
        remote: RegistryManifestHead(statusCode: 200, digest: localDigest),
      );
      expect(c.status, ImageUpdateStatus.upToDate);
      expect(c.localDigest, localDigest);
      expect(c.hasUpdate, isFalse);
    });

    test('a differing manifest digest is an update', () {
      final c = compareImageDigest(
        repoDigests: ['alpine@$localDigest'],
        repository: 'alpine',
        remote: const RegistryManifestHead(
          statusCode: 200,
          digest:
              'sha256:1111111111111111111111111111111111111111111111111111111111111111',
          mediaType: 'application/vnd.docker.distribution.manifest.v2+json',
        ),
      );
      expect(c.status, ImageUpdateStatus.updateAvailable);
      expect(c.hasUpdate, isTrue);
    });

    test('a differing index digest is an update too', () {
      final c = compareImageDigest(
        repoDigests: ['alpine@$localDigest'],
        repository: 'alpine',
        remote: const RegistryManifestHead(
          statusCode: 200,
          digest: otherDigest,
          mediaType: 'application/vnd.oci.image.index.v1+json',
        ),
      );
      expect(c.status, ImageUpdateStatus.updateAvailable);
      expect(c.localDigest, localDigest);
      expect(c.remoteDigest, otherDigest);
    });

    // Spike S8 (D68): a push from the containerd store with one platform
    // present stores that platform's manifest (dc92...) while RepoDigests
    // keeps the index digest (2e0b...).
    test('a pushed platform manifest matches an available index child', () {
      final c = compareImageDigest(
        repoDigests: const ['localhost:5000/alpine@$s8Index'],
        repository: 'localhost:5000/alpine',
        descriptorDigest: s8Index,
        availableChildDigests: const [s8Amd64],
        remote: const RegistryManifestHead(
          statusCode: 200,
          digest: s8Amd64,
          mediaType: 'application/vnd.oci.image.manifest.v1+json',
        ),
      );
      expect(c.status, ImageUpdateStatus.upToDate);
      expect(c.localDigest, s8Amd64);
    });

    test('the containerd Descriptor counts when RepoDigests names another '
        'repository', () {
      final c = compareImageDigest(
        repoDigests: const ['ghcr.io/acme/api@$otherDigest'],
        repository: 'alpine',
        descriptorDigest: s8Index,
        remote: const RegistryManifestHead(statusCode: 200, digest: s8Index),
      );
      expect(c.status, ImageUpdateStatus.upToDate);
    });

    test('a refused HEAD names why the check could not decide', () {
      ImageUpdateIssue? issueFor(int status) => compareImageDigest(
        repoDigests: ['alpine@$localDigest'],
        repository: 'alpine',
        remote: RegistryManifestHead(statusCode: status),
      ).issue;

      expect(issueFor(401), ImageUpdateIssue.unauthorized);
      expect(issueFor(403), ImageUpdateIssue.unauthorized);
      expect(issueFor(404), ImageUpdateIssue.notFound);
      expect(issueFor(429), ImageUpdateIssue.rateLimited);
      expect(issueFor(500), ImageUpdateIssue.failed);
      expect(issueFor(200), ImageUpdateIssue.noDigest);
    });

    test('no remote result and no local digest are unknown', () {
      expect(
        compareImageDigest(
          repoDigests: const [],
          repository: 'alpine',
          remote: null,
        ).issue,
        ImageUpdateIssue.noResult,
      );
      expect(
        compareImageDigest(
          repoDigests: const [],
          repository: 'alpine',
          remote: const RegistryManifestHead(
            statusCode: 200,
            digest: localDigest,
          ),
        ).issue,
        ImageUpdateIssue.noLocalDigest,
      );
    });
  });

  group('RepoDigest', () {
    test('splits repo@digest and rejects junk', () {
      expect(RepoDigest.tryParse('alpine@$localDigest')!.repository, 'alpine');
      expect(RepoDigest.tryParse('alpine') == null, isTrue);
      expect(RepoDigest.tryParse('@x') == null, isTrue);
    });
  });
}
