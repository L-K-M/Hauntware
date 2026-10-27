// IMG-05's update check (03 §7.14, D68) over a fake daemon and a fake
// host: each reference's registry digest against its local digests, the
// six-hour cache, Check now, a 429's backoff, buildx for a private
// registry and a host without curl.
import 'dart:convert';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/docker/image_updates.dart';
import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show kRegistryHeadsMax;
import 'package:seance_core/seance_core.dart'
    show RemoteCommandException, RemoteCommandResult;
import 'package:test/test.dart';

import '../support/forwarding_link.dart';

String _digest(String seed) => 'sha256:${seed.padRight(64, '0')}';

final _index = _digest('a1');
final _old = _digest('0d');
final _child = _digest('c1');
final _node = _digest('b2');

/// Answers the image list and each image's inspect with `manifests=1`.
final class _Daemon extends FakeDaemon {
  final images = <Map<String, Object?>>[];
  final inspects = <String, Map<String, Object?>>{};

  @override
  String respond(String requestLine) {
    final [_, target, ...] = requestLine.split(' ');
    final uri = Uri.parse('http://engine$target');
    final path = uri.path.substring('/v1.52'.length);
    if (path == '/images/json') return _reply(200, images);
    if (path.startsWith('/images/') && path.endsWith('/json')) {
      final name = Uri.decodeComponent(
        path.substring('/images/'.length, path.length - '/json'.length),
      );
      if (inspects[name] case final inspect?) return _reply(200, inspect);
      return _reply(404, {'message': 'no such image'});
    }
    return _reply(404, {'message': 'not found'});
  }

  static String _reply(int status, Object body) {
    final bytes = utf8.encode(jsonEncode(body));
    return 'HTTP/1.1 $status X\r\nContent-Type: application/json\r\n'
        'Content-Length: ${bytes.length}\r\n\r\n${utf8.decode(bytes)}';
  }
}

/// The host: each reference the command names answers its block, in the
/// order the blocks were set.
final class _Host {
  final blocks = <String, String>{};
  final commands = <String>[];
  bool noCurl = false;
  Object? error;

  Future<RemoteCommandResult> run(
    String command, {
    required Duration timeout,
    required int maxOutputBytes,
  }) async {
    commands.add(command);
    if (error case final error?) throw error;
    if (noCurl) return const RemoteCommandResult(stdout: '== no curl\n');
    final out = StringBuffer();
    for (final MapEntry(key: reference, value: block) in blocks.entries) {
      // The tests' references are never part of one another.
      if (command.contains(reference)) {
        out.write('== image $reference\n$block');
      }
    }
    return RemoteCommandResult(stdout: '$out', exitCode: 0);
  }
}

String _head(int status, {String? digest, String? remaining}) =>
    '== head 0\n'
    'HTTP/2 $status \r\n'
    'content-type: application/vnd.oci.image.index.v1+json\r\n'
    '${digest == null ? '' : 'docker-content-digest: $digest\r\n'}'
    '${remaining == null ? '' : 'ratelimit-limit: 100;w=3600\r\n'
              'ratelimit-remaining: $remaining\r\n'}'
    '\r\n';

void main() {
  late _Daemon daemon;
  late _Host host;
  late ImageUpdateCache cache;
  var now = DateTime.utc(2026, 10, 27, 9);

  DockerClient client() => DockerClient(
    DockerHttpClient(() async => daemon.connect().client),
    apiVersion: ApiVersion.tryParse('1.52')!,
  );

  Future<DockerPayload> check({bool refresh = false}) => checkImageUpdates(
    client: client(),
    run: host.run,
    cache: cache,
    now: now,
    refresh: refresh,
  );

  void image(
    String id,
    List<String> tags, {
    List<String> repoDigests = const [],
    String? descriptor,
    List<String> children = const [],
  }) {
    daemon.images.add({
      'Id': id,
      'RepoTags': tags,
      'RepoDigests': repoDigests,
      'Created': 0,
      'Size': 1,
    });
    daemon.inspects[id] = {
      'Id': id,
      'RepoTags': tags,
      'RepoDigests': repoDigests,
      if (descriptor != null) 'Descriptor': {'digest': descriptor},
      'Manifests': [
        for (final child in children)
          {
            'Kind': 'image',
            'Available': true,
            'Descriptor': {'digest': child},
          },
      ],
    };
  }

  setUp(() {
    daemon = _Daemon();
    host = _Host();
    cache = ImageUpdateCache();
    now = DateTime.utc(2026, 10, 27, 9);
  });

  test('compares each tag with the registry and keeps the rows for six '
      'hours, unless Check now asks again', () async {
    image('sha256:i1', ['alpine:3.22'], repoDigests: ['alpine@$_index']);
    image(
      'sha256:i2',
      ['quay.io/prometheus/node-exporter:latest'],
      repoDigests: ['quay.io/prometheus/node-exporter@$_old'],
    );
    image('sha256:i3', ['<none>:<none>']);
    image('sha256:i4', ['busybox@$_index']);
    host.blocks['alpine:3.22'] = _head(
      200,
      digest: _index,
      remaining: '57;w=3600',
    );
    host.blocks['quay.io/prometheus/node-exporter:latest'] = _head(
      200,
      digest: _node,
    );

    final first = await check() as DockerImageUpdatesPayload;
    expect(first.curlMissing, isFalse);
    expect(host.commands, hasLength(1));
    final [alpine, node] = first.rows;
    expect(alpine.reference, 'alpine:3.22');
    expect(alpine.comparison.status, ImageUpdateStatus.upToDate);
    expect(alpine.route, ImageUpdateRoute.registry);
    expect(alpine.rateLimit?.remaining, 57);
    expect(alpine.checkedAt, now);
    expect(node.comparison.status, ImageUpdateStatus.updateAvailable);
    expect(node.comparison.localDigest, _old);
    expect(node.comparison.remoteDigest, _node);

    now = now.add(const Duration(hours: 5));
    final kept = await check() as DockerImageUpdatesPayload;
    expect(host.commands, hasLength(1), reason: 'still fresh');
    expect(
      kept.rows.map((r) => r.checkedAt),
      first.rows.map((r) => r.checkedAt),
    );

    await check(refresh: true);
    expect(host.commands, hasLength(2), reason: 'Check now');

    now = now.add(kImageUpdateFresh);
    await check();
    expect(host.commands, hasLength(3), reason: 'stale after six hours');
  });

  test('a 429 leaves that registry alone for the window it named, without '
      'another route', () async {
    image('sha256:i1', ['busybox:1'], repoDigests: ['busybox@$_old']);
    image('sha256:i2', ['quay.io/a/b:1'], repoDigests: ['quay.io/a/b@$_node']);
    host.blocks['busybox:1'] = _head(429, remaining: '0;w=3600');
    host.blocks['quay.io/a/b:1'] = _head(200, digest: _node);

    final first = await check() as DockerImageUpdatesPayload;
    final busy = first.rows.first;
    expect(busy.comparison.issue, ImageUpdateIssue.rateLimited);
    expect(busy.route, isNull);
    expect(busy.rateLimit?.window, const Duration(hours: 1));

    now = now.add(const Duration(minutes: 30));
    final again = await check(refresh: true) as DockerImageUpdatesPayload;
    expect(host.commands.last, isNot(contains('busybox:1')));
    expect(host.commands.last, contains('quay.io/a/b:1'));
    expect(again.rows.first.checkedAt, busy.checkedAt, reason: 'kept');

    now = now.add(const Duration(minutes: 31));
    host.blocks['busybox:1'] = _head(200, digest: _old);
    final after = await check(refresh: true) as DockerImageUpdatesPayload;
    expect(after.rows.first.comparison.status, ImageUpdateStatus.upToDate);
  });

  test('a private registry is read through buildx, and a containerd '
      'image matches by its available platform manifest', () async {
    image(
      'sha256:i1',
      ['localhost:5000/alpine:3.22'],
      repoDigests: ['localhost:5000/alpine@$_index'],
      descriptor: _index,
      children: [_child],
    );
    host.blocks['localhost:5000/alpine:3.22'] =
        '== head 0\n'
        'HTTP/1.1 401 Unauthorized\r\n'
        'Www-Authenticate: Basic realm="s8"\r\n'
        '== cli 0\n'
        '{\n  "mediaType": "application/vnd.oci.image.manifest.v1+json",\n'
        '  "digest": "$_child",\n  "size": 1022\n}\n';

    final row = (await check() as DockerImageUpdatesPayload).rows.single;
    expect(row.route, ImageUpdateRoute.hostCli);
    expect(row.comparison.status, ImageUpdateStatus.upToDate);
    expect(daemon.requests, contains(contains('manifests=1')));
  });

  test(
    'a private registry without buildx reads as needing credentials',
    () async {
      image(
        'sha256:i1',
        ['localhost:5000/app:1'],
        repoDigests: ['localhost:5000/app@$_old'],
      );
      host.blocks['localhost:5000/app:1'] =
          '== head 0\n'
          'HTTP/1.1 401 Unauthorized\r\n'
          '== cli missing\n';

      final row = (await check() as DockerImageUpdatesPayload).rows.single;
      expect(row.comparison.issue, ImageUpdateIssue.unauthorized);
      expect(row.cliMissing, isTrue);
    },
  );

  test('a host without curl checks nothing and keeps nothing', () async {
    image('sha256:i1', ['alpine:3.22'], repoDigests: ['alpine@$_index']);
    host.noCurl = true;

    final payload = await check() as DockerImageUpdatesPayload;
    expect(payload.curlMissing, isTrue);
    expect(payload.rows, isEmpty);

    host.noCurl = false;
    host.blocks['alpine:3.22'] = _head(200, digest: _index);
    await check();
    expect(host.commands, hasLength(2), reason: 'nothing was cached');
  });

  test('a command that could not run fails the query', () async {
    image('sha256:i1', ['alpine:3.22'], repoDigests: ['alpine@$_index']);
    host.error = const RemoteCommandException('channel closed');

    final payload = await check();
    expect(
      payload,
      isA<DockerQueryFailed>().having(
        (f) => f.failure,
        'failure',
        DockerQueryFailure.connectionFailed,
      ),
    );
  });

  test('more images than one read takes go in later reads', () async {
    for (var i = 0; i < kRegistryHeadsMax + 1; i++) {
      image('sha256:i$i', ['app$i:1'], repoDigests: ['app$i@$_old']);
      host.blocks['app$i:1'] = _head(200, digest: _old);
    }

    final payload = await check() as DockerImageUpdatesPayload;
    expect(host.commands, hasLength(2));
    expect(payload.rows, hasLength(kRegistryHeadsMax + 1));
    expect(payload.rows.map((r) => r.comparison.status).toSet(), {
      ImageUpdateStatus.upToDate,
    });
  });
}
