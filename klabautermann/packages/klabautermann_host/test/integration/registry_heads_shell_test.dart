// IMG-05's registry read through real shells (03 §7.14, D68), with
// stand-in `curl` and `docker` first on PATH. The stand-in registries
// answer as spike S8 recorded: Docker Hub's anonymous Bearer flow, Quay
// without a token, a private registry's Basic challenge and Docker Hub's
// 429. Each runs as the builder's argv with `sh` replaced by the shell
// under test. Tagged `shell`; a shell that is not installed gets no
// tests.
@Tags(['shell'])
@TestOn('linux')
library;

import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

final _shells = {
  for (final name in ['dash', 'bash'])
    for (final dir in ['/bin', '/usr/bin'])
      if (File('$dir/$name').existsSync()) name: '$dir/$name',
};

const _index =
    'sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f';
const _quay =
    'sha256:1b4e4438faca4dd7e001dd445d161a4a2091b0fededa84093b3a8dfeae1f1be0';
const _private =
    'sha256:dc92f017beea8e7f43263073d717f7bc011228c95d5312e440deb4d035bb4eec';

/// Records every argument line to `$LOG`, so a test can check that the
/// token never appeared in one.
const _curl = r'''#!/bin/sh
printf '%s\n' "$*" >> "$LOG"
head=; get=; stdin=
for a in "$@"; do
  case $a in -I) head=1;; -G) get=1;; @-) stdin=$(cat);; esac
  url=$a
done
if [ -n "$get" ]; then
  echo '{"token":"tok-123","access_token":"tok-123","expires_in":300}'
  exit 0
fi
case $url in
  https://registry-1.docker.io/v2/library/alpine/*)
    case $stdin in
      *'Authorization: Bearer tok-123'*)
        printf 'HTTP/1.1 200 Connection Established\r\n\r\n'
        printf 'HTTP/2 200 \r\ncontent-type: application/vnd.oci.image.index.v1+json\r\n'
        printf 'docker-content-digest: sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f\r\n'
        printf 'ratelimit-limit: 100;w=3600\r\nratelimit-remaining: 57;w=3600\r\ndate: x\r\n\r\n';;
      *)
        printf 'HTTP/2 401 \r\nwww-authenticate: Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:library/alpine:pull"\r\n\r\n';;
    esac;;
  https://registry-1.docker.io/v2/library/busy/*)
    printf 'HTTP/2 429 \r\nratelimit-limit: 100;w=3600\r\nratelimit-remaining: 0;w=3600\r\n\r\n';;
  https://quay.io/*)
    printf 'HTTP/2 200 \r\ncontent-type: application/vnd.docker.distribution.manifest.list.v2+json\r\n'
    printf 'docker-content-digest: sha256:1b4e4438faca4dd7e001dd445d161a4a2091b0fededa84093b3a8dfeae1f1be0\r\n\r\n';;
  http://localhost:5000/*)
    printf 'HTTP/1.1 401 Unauthorized\r\nWww-Authenticate: Basic realm="s8"\r\n\r\n';;
  https://bad.example/*)
    printf 'HTTP/2 401 \r\nwww-authenticate: Bearer realm="http://bad.example/token",service="x"\r\n\r\n';;
  *) echo "curl: (6) Could not resolve host" >&2; exit 6;;
esac
''';

const _docker = r'''#!/bin/sh
case "$1 $2" in
  "buildx version") echo 'github.com/docker/buildx v0.37.1'; exit 0;;
  "buildx imagetools")
    printf '{\n  "mediaType": "application/vnd.oci.image.manifest.v1+json",\n'
    printf '  "digest": "sha256:dc92f017beea8e7f43263073d717f7bc011228c95d5312e440deb4d035bb4eec",\n  "size": 1022\n}\n';;
  *) exit 1;;
esac
''';

const _alpine = RegistryHeadTarget(
  registry: 'registry-1.docker.io',
  repository: 'library/alpine',
  tag: '3.22',
  reference: 'alpine:3.22',
);

void main() {
  late Directory bin;
  late File log;

  setUp(() async {
    bin = await Directory.systemTemp.createTemp('klab-registry-');
    log = File('${bin.path}/curl.log');
  });

  tearDown(() => bin.delete(recursive: true));

  Future<void> standIn(String name, String script) async {
    final file = File('${bin.path}/$name');
    await file.writeAsString(script);
    await Process.run('chmod', ['+x', file.path]);
  }

  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    group(name, () {
      Future<RegistryHeads> run(
        List<RegistryHeadTarget> targets, {
        String? path,
      }) async {
        final argv = [
          for (final w in HostCommands.registryHeads(targets))
            w == 'sh' ? shell : w,
        ];
        final r = await Process.run(
          argv.first,
          argv.sublist(1),
          environment: {
            'PATH': path ?? '${bin.path}:${Platform.environment['PATH']}',
            'LOG': log.path,
          },
        );
        expect(r.exitCode, 0, reason: '${r.stderr}');
        return parseRegistryHeads(r.stdout as String);
      }

      test('Docker Hub: the anonymous token flow, with the token kept out '
          'of every argument list', () async {
        await standIn('curl', _curl);
        final read = await run([_alpine]);
        final alpine = read.images.single;
        expect(alpine.reference, 'alpine:3.22');
        expect(alpine.curlExit, 0);
        expect(alpine.statusCode, 200);
        expect(alpine.header('docker-content-digest'), _index);
        expect(alpine.header('ratelimit-remaining'), '57;w=3600');
        expect(alpine.header('date'), isNull, reason: 'not kept');
        expect(alpine.cliExit, isNull);
        final calls = await log.readAsString();
        expect(calls, contains('scope=repository:library/alpine:pull'));
        expect(calls, isNot(contains('tok-123')));
      });

      test('several registries in one read, each answered in turn', () async {
        await standIn('curl', _curl);
        await standIn('docker', _docker);
        final read = await run([
          _alpine,
          const RegistryHeadTarget(
            registry: 'quay.io',
            repository: 'prometheus/node-exporter',
            tag: 'latest',
            reference: 'quay.io/prometheus/node-exporter:latest',
          ),
          const RegistryHeadTarget(
            registry: 'registry-1.docker.io',
            repository: 'library/busy',
            tag: 'latest',
            reference: 'busy',
          ),
          const RegistryHeadTarget(
            registry: 'localhost:5000',
            repository: 'alpine',
            tag: '3.22',
            reference: 'localhost:5000/alpine:3.22',
          ),
          const RegistryHeadTarget(
            registry: 'nowhere.example',
            repository: 'app',
            tag: 'latest',
            reference: 'nowhere.example/app',
          ),
        ]);
        final [hub, quay, busy, private, nowhere] = read.images;
        expect(hub.header('docker-content-digest'), _index);
        expect(quay.statusCode, 200);
        expect(quay.header('docker-content-digest'), _quay);
        expect(busy.statusCode, 429);
        expect(busy.header('ratelimit-remaining'), '0;w=3600');
        expect(busy.cliExit, isNull, reason: 'a 429 is not a sign-in');
        expect(private.statusCode, 401);
        expect(private.header('www-authenticate'), 'Basic realm="s8"');
        expect(private.cliExit, 0);
        expect(private.cliOutput, contains(_private));
        expect(nowhere.curlExit, 6);
        expect(nowhere.statusCode, isNull);
      });

      test(
        'a private registry without buildx says the CLI is missing',
        () async {
          await standIn('curl', _curl);
          await standIn('docker', '#!/bin/sh\nexit 1\n');
          final read = await run([
            const RegistryHeadTarget(
              registry: 'localhost:5000',
              repository: 'alpine',
              tag: '3.22',
              reference: 'localhost:5000/alpine:3.22',
            ),
          ]);
          expect(read.images.single.cliMissing, isTrue);
        },
      );

      test('a realm that is not https is not followed', () async {
        await standIn('curl', _curl);
        final read = await run([
          const RegistryHeadTarget(
            registry: 'bad.example',
            repository: 'app',
            tag: 'latest',
            reference: 'bad.example/app',
          ),
        ]);
        expect(read.images.single.statusCode, 401);
        expect(await log.readAsString(), isNot(contains('-G')));
      });

      test('a host without curl checks nothing', () async {
        final read = await run([_alpine], path: bin.path);
        expect(read.curlMissing, isTrue);
        expect(read.images, isEmpty);
      });
    });
  }
}
