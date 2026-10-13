import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

const String localDigest =
    'sha256:abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd';

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

    test('an index media type mismatch stays unknown, not a false update', () {
      final c = compareImageDigest(
        repoDigests: ['alpine@$localDigest'],
        repository: 'alpine',
        remote: const RegistryManifestHead(
          statusCode: 200,
          digest:
              'sha256:2222222222222222222222222222222222222222222222222222222222222222',
          mediaType: 'application/vnd.oci.image.index.v1+json',
        ),
      );
      expect(c.status, ImageUpdateStatus.unknown);
      expect(c.warnings, isNotEmpty);
    });

    test('no remote result and no local digest are unknown', () {
      expect(
        compareImageDigest(
          repoDigests: const [],
          repository: 'alpine',
          remote: null,
        ).status,
        ImageUpdateStatus.unknown,
      );
      expect(
        compareImageDigest(
          repoDigests: const [],
          repository: 'alpine',
          remote: const RegistryManifestHead(
            statusCode: 200,
            digest: localDigest,
          ),
        ).status,
        ImageUpdateStatus.unknown,
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
