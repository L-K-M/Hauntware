import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const _target = RegistryHeadTarget(
  registry: 'registry-1.docker.io',
  repository: 'library/alpine',
  tag: '3.22',
  reference: 'alpine:3.22',
);

/// IMG-05's registry read (03 §7.14, D68): the builder and the parser.
void main() {
  group('HostCommands.registryHeads', () {
    test('passes each image as four checked positional words', () {
      final argv = HostCommands.registryHeads(const [
        _target,
        RegistryHeadTarget(
          registry: 'localhost:5000',
          repository: 'team/app',
          tag: 'v1.2_rc-3',
          reference: 'localhost:5000/team/app:v1.2_rc-3',
        ),
      ]);
      expect(argv.take(2), ['sh', '-c']);
      expect(argv.skip(3), [
        'hws-registry',
        'registry-1.docker.io',
        'library/alpine',
        '3.22',
        'alpine:3.22',
        'localhost:5000',
        'team/app',
        'v1.2_rc-3',
        'localhost:5000/team/app:v1.2_rc-3',
      ]);
    });

    test('refuses words a shell or a URL could misread', () {
      RegistryHeadTarget with_({
        String registry = 'quay.io',
        String repository = 'a/b',
        String tag = 'latest',
        String reference = 'quay.io/a/b',
      }) => RegistryHeadTarget(
        registry: registry,
        repository: repository,
        tag: tag,
        reference: reference,
      );

      for (final bad in [
        with_(registry: 'quay.io/x'),
        with_(registry: r'$(id)'),
        with_(repository: 'A/b'),
        with_(repository: 'a/../b'),
        with_(repository: 'a?x=1'),
        with_(tag: '-rf'),
        with_(tag: 'a b'),
        with_(reference: 'quay.io/a/b@sha256:abc'),
        with_(reference: 'a;b'),
      ]) {
        expect(
          () => HostCommands.registryHeads([bad]),
          throwsA(isA<HostCommandError>()),
        );
      }
    });

    test('takes between one and the most images a read checks', () {
      expect(
        () => HostCommands.registryHeads(const []),
        throwsA(isA<HostCommandError>()),
      );
      expect(
        () => HostCommands.registryHeads(
          List.filled(kRegistryHeadsMax + 1, _target),
        ),
        throwsA(isA<HostCommandError>()),
      );
      expect(
        HostCommands.registryHeads(List.filled(kRegistryHeadsMax, _target)),
        hasLength(4 + 4 * kRegistryHeadsMax),
      );
    });
  });

  group('parseRegistryHeads', () {
    test('keeps the last response behind a proxy, and only the headers '
        'the check reads', () {
      final read = parseRegistryHeads(
        '== image alpine:3.22\n'
        '== head 0\n'
        'HTTP/1.1 200 Connection Established\n'
        'HTTP/2 200 \n'
        'content-type: application/vnd.oci.image.index.v1+json\n'
        'Docker-Content-Digest: sha256:aa\n'
        'ratelimit-limit: 100;w=3600\n'
        'ratelimit-remaining: 57;w=3600\n',
      );
      final image = read.images.single;
      expect(image.curlExit, 0);
      expect(image.statusCode, 200);
      expect(image.header('docker-content-digest'), 'sha256:aa');
      expect(image.header('ratelimit-remaining'), '57;w=3600');
      expect(image.headers.map((h) => h.$1), [
        'content-type',
        'docker-content-digest',
        'ratelimit-limit',
        'ratelimit-remaining',
      ]);
    });

    test('reads buildx\'s answer and a missing plugin', () {
      final read = parseRegistryHeads(
        '== image localhost:5000/alpine:3.22\n'
        '== head 0\n'
        'HTTP/1.1 401 Unauthorized\r\n'
        'Www-Authenticate: Basic realm="s8"\r\n'
        '== cli 0\n'
        '{\n  "digest": "sha256:dc"\n}\n'
        '\n'
        '== image localhost:5001/app\n'
        '== head 0\n'
        'HTTP/1.1 401 Unauthorized\n'
        '== cli missing\n',
      );
      final [withCli, without] = read.images;
      expect(withCli.statusCode, 401);
      expect(withCli.header('www-authenticate'), 'Basic realm="s8"');
      expect(withCli.cliExit, 0);
      expect(withCli.cliOutput, '{\n  "digest": "sha256:dc"\n}');
      expect(without.cliMissing, isTrue);
      expect(without.cliOutput, isNull);
    });

    test('a failed curl leaves no status; no curl means nothing ran', () {
      final failed = parseRegistryHeads(
        '== image nowhere.example/app\n'
        '== head 6\n'
        'curl: (6) Could not resolve host\n',
      ).images.single;
      expect(failed.curlExit, 6);
      expect(failed.statusCode, isNull);
      expect(failed.headers, isEmpty);

      final none = parseRegistryHeads('$kRegistryNoCurlMarker\n');
      expect(none.curlMissing, isTrue);
      expect(none.images, isEmpty);
      expect(parseRegistryHeads('').images, isEmpty);
    });
  });
}
