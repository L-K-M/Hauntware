import 'dart:convert';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

import 'harness.dart';

List<int> jsonResponse(List<int> body) => wireResponse(
  '200 OK',
  headers: {
    'Content-Type': 'application/json',
    'Content-Length': '${body.length}',
  },
  body: body,
);

DockerClient clientFor(FakeDaemon daemon, ApiVersion version) => DockerClient(
  DockerHttpClient(() async => daemon.pair.client),
  apiVersion: version,
);

void main() {
  group('container endpoints', () {
    test('listContainers versions the path and parses the list', () async {
      final daemon = FakeDaemon();
      final client = clientFor(daemon, const ApiVersion(1, 44));
      final sent = client.listContainers();
      await daemon.gotBytes(1);
      daemon.feed(jsonResponse(fixtureBytes('containers-1.44.json')));
      final r = await sent;
      expect(daemon.text, startsWith('GET /v1.44/containers/json?all=1'));
      expect(r.value, hasLength(4));
      expect(r.warnings, isEmpty);
    });

    test('inspectContainer parses the inspect document', () async {
      final daemon = FakeDaemon();
      final client = clientFor(daemon, const ApiVersion(1, 44));
      final sent = client.inspectContainer('abc123');
      await daemon.gotBytes(1);
      daemon.feed(jsonResponse(fixtureBytes('container-inspect-1.44.json')));
      final r = await sent;
      expect(daemon.text, startsWith('GET /v1.44/containers/abc123/json'));
      expect(r.value.name, 'web-1');
    });

    test('containerStatsOneShot uses the one-shot query', () async {
      final daemon = FakeDaemon();
      final client = clientFor(daemon, const ApiVersion(1, 44));
      final sent = client.containerStatsOneShot('abc123');
      await daemon.gotBytes(1);
      daemon.feed(jsonResponse(fixtureBytes('stats-1.44.json')));
      final r = await sent;
      expect(
        daemon.text,
        startsWith(
          'GET /v1.44/containers/abc123/stats?stream=false&one-shot=true',
        ),
      );
      expect(r.value.pids, 6);
    });

    test('start and remove send the right verbs and query', () async {
      final daemon = FakeDaemon();
      final client = clientFor(daemon, const ApiVersion(1, 44));
      final started = client.startContainer('abc123');
      await daemon.gotBytes(1);
      daemon.feed(wireResponse('204 No Content'));
      await started;
      expect(daemon.text, startsWith('POST /v1.44/containers/abc123/start'));

      final removed = client.removeContainer(
        'abc123',
        volumes: true,
        force: true,
      );
      await daemon.gotBytes(daemon.received.length + 1);
      daemon.feed(wireResponse('204 No Content'));
      await removed;
      expect(
        daemon.text,
        contains('DELETE /v1.44/containers/abc123?v=1&force=1&link=0'),
      );
    });

    test('killContainer sends an enum signal', () async {
      final daemon = FakeDaemon();
      final client = clientFor(daemon, const ApiVersion(1, 44));
      final sent = client.killContainer('abc123', signal: DockerSignal.sigterm);
      await daemon.gotBytes(1);
      daemon.feed(wireResponse('204 No Content'));
      await sent;
      expect(
        daemon.text,
        contains('POST /v1.44/containers/abc123/kill?signal=SIGTERM'),
      );
    });
  });

  group('image endpoints', () {
    test('listImages honours the 1.51 Containers gate', () async {
      final beforeDaemon = FakeDaemon();
      final at144 = clientFor(beforeDaemon, const ApiVersion(1, 44));
      final before = at144.listImages();
      await beforeDaemon.gotBytes(1);
      beforeDaemon.feed(jsonResponse(fixtureBytes('images-1.55.json')));
      final beforeResult = await before;
      expect(beforeResult.value.first.containers, isNull);

      final afterDaemon = FakeDaemon();
      final at155 = clientFor(afterDaemon, const ApiVersion(1, 55));
      final after = at155.listImages();
      await afterDaemon.gotBytes(1);
      afterDaemon.feed(jsonResponse(fixtureBytes('images-1.55.json')));
      final afterResult = await after;
      expect(afterResult.value.first.containers, 3);
    });

    test('inspectImage asks for the index children from 1.48 only', () async {
      Future<String> requestLine(ApiVersion version) async {
        final daemon = FakeDaemon();
        final inspect = clientFor(
          daemon,
          version,
        ).inspectImage('alpine:3.22', manifests: true);
        await daemon.gotBytes(1);
        daemon.feed(
          jsonResponse(
            utf8.encode(
              jsonEncode({
                'Id': 'sha256:i1',
                'Manifests': [
                  {
                    'Kind': 'image',
                    'Available': true,
                    'Descriptor': {'digest': 'sha256:c1'},
                  },
                  {
                    'Kind': 'attestation',
                    'Available': true,
                    'Descriptor': {'digest': 'sha256:a1'},
                  },
                  {
                    'Kind': 'image',
                    'Available': false,
                    'Descriptor': {'digest': 'sha256:c2'},
                  },
                ],
              }),
            ),
          ),
        );
        expect((await inspect).value.availableChildDigests, ['sha256:c1']);
        return utf8.decode(daemon.received).split('\r\n').first;
      }

      expect(
        await requestLine(const ApiVersion(1, 48)),
        'GET /v1.48/images/alpine%3A3.22/json?manifests=1 HTTP/1.1',
      );
      expect(
        await requestLine(const ApiVersion(1, 47)),
        'GET /v1.47/images/alpine%3A3.22/json HTTP/1.1',
      );
    });

    test('distributionInspect reads the descriptor the tag names', () async {
      final daemon = FakeDaemon();
      final read = clientFor(
        daemon,
        const ApiVersion(1, 52),
      ).distributionInspect('alpine:3.22');
      await daemon.gotBytes(1);
      daemon.feed(
        jsonResponse(
          utf8.encode(
            jsonEncode({
              'Descriptor': {
                'mediaType': 'application/vnd.oci.image.index.v1+json',
                'digest': 'sha256:aa',
                'size': 9218,
              },
              'Platforms': [
                {'architecture': 'amd64', 'os': 'linux'},
              ],
            }),
          ),
        ),
      );
      final descriptor = (await read).value;
      expect(descriptor.digest, 'sha256:aa');
      expect(descriptor.mediaType, 'application/vnd.oci.image.index.v1+json');
      expect(
        utf8.decode(daemon.received).split('\r\n').first,
        'GET /v1.52/distribution/alpine%3A3.22/json HTTP/1.1',
      );
      expect(parseDistributionInspect(const <String, Object?>{}).warnings, [
        'distribution inspect has no Descriptor',
      ]);
    });

    test('pullImage streams parsed progress values', () async {
      final daemon = FakeDaemon();
      final client = clientFor(daemon, const ApiVersion(1, 44));
      final collected = client
          .pullImage('alpine', tag: '3.21')
          .map((r) => r.value)
          .toList();
      await daemon.gotBytes(1);
      final body = fixtureBytes('pull-progress-1.44.json');
      daemon.feed(
        wireResponse(
          '200 OK',
          headers: {'Content-Length': '${body.length}'},
          body: body,
        ),
      );
      final progress = await collected;
      expect(
        daemon.text,
        startsWith('POST /v1.44/images/create?fromImage=alpine&tag=3.21'),
      );
      expect(progress, hasLength(4));
      expect(progress[1].status, 'Downloading');
      expect(progress[1].progressDetail!.ratio, closeTo(0.00399, 0.001));
      expect(progress[3].status, startsWith('Digest:'));
    });
  });

  group('network, volume and engine endpoints', () {
    test('listNetworks and listVolumes parse their documents', () async {
      final daemon = FakeDaemon();
      final client = clientFor(daemon, const ApiVersion(1, 44));
      final networks = client.listNetworks();
      await daemon.gotBytes(1);
      daemon.feed(jsonResponse(fixtureBytes('networks-1.44.json')));
      expect((await networks).value, hasLength(2));

      final volumes = client.listVolumes();
      await daemon.gotBytes(daemon.received.length + 1);
      daemon.feed(jsonResponse(fixtureBytes('volumes-1.44.json')));
      expect((await volumes).value, hasLength(2));
    });

    test('engineInfo parses /info', () async {
      final daemon = FakeDaemon();
      final client = clientFor(daemon, const ApiVersion(1, 55));
      final sent = client.engineInfo();
      await daemon.gotBytes(1);
      daemon.feed(jsonResponse(fixtureBytes('info-1.55.json')));
      final r = await sent;
      expect(daemon.text, startsWith('GET /v1.55/info'));
      expect(r.value.containersRunning, 3);
    });
  });

  group('system df endpoint', () {
    Future<(String, DockerParseResult<SystemDf>)> fetch(
      ApiVersion version,
      String fixture, {
      SystemDfType? type,
    }) async {
      final daemon = FakeDaemon();
      final sent = clientFor(daemon, version).systemDf(type: type);
      await daemon.gotBytes(1);
      daemon.feed(jsonResponse(fixtureBytes(fixture)));
      final r = await sent;
      return (daemon.text, r);
    }

    test('reads the shape the negotiated version gates', () async {
      final (legacyText, legacy) = await fetch(
        const ApiVersion(1, 44),
        'system-df-1.44.json',
      );
      expect(legacyText, startsWith('GET /v1.44/system/df HTTP/1.1'));
      expect(legacy.warnings, isEmpty);
      expect(legacy.value.images!.reclaimable, 10800000);

      final (_, v152) = await fetch(
        const ApiVersion(1, 52),
        'system-df-1.52.json',
      );
      expect(v152.warnings, isEmpty);
      expect(v152.value.reclaimable, 4130000);

      final (_, v155) = await fetch(
        const ApiVersion(1, 55),
        'system-df-1.53.json',
      );
      expect(v155.warnings, isEmpty);
      expect(v155.value.volumes!.reclaimable, 104857600);
    });

    test('sends the type filter', () async {
      final (text, _) = await fetch(
        const ApiVersion(1, 53),
        'system-df-1.53.json',
        type: SystemDfType.buildCache,
      );
      expect(text, startsWith('GET /v1.53/system/df?type=build-cache '));
    });
  });

  group('events endpoint', () {
    test('streams parsed events and resumes with since', () async {
      final daemon = FakeDaemon();
      final client = clientFor(daemon, const ApiVersion(1, 52));
      final collected = client
          .events(since: const LogTimestamp(1780000000, 0))
          .map((r) => r.value)
          .toList();
      await daemon.gotBytes(1);
      final body = fixtureBytes('events-1.52.ndjson');
      daemon.feed(
        wireResponse(
          '200 OK',
          headers: {
            'Content-Type': 'application/json',
            'Content-Length': '${body.length}',
          },
          body: body,
        ),
      );
      final events = await collected;
      expect(daemon.text, startsWith('GET /v1.52/events?since=1780000000'));
      expect(events, hasLength(7));
      expect(events.first.action, 'create');
    });
  });

  group('logs endpoint', () {
    List<int> stdcopyFrame(int kind, String text) {
      final payload = utf8.encode(text);
      return [
        kind,
        0,
        0,
        0,
        (payload.length >> 24) & 0xff,
        (payload.length >> 16) & 0xff,
        (payload.length >> 8) & 0xff,
        payload.length & 0xff,
        ...payload,
      ];
    }

    test('resolves the framing and resumes with an inclusive since', () async {
      final daemon = FakeDaemon();
      final client = clientFor(daemon, const ApiVersion(1, 52));
      final sent = client.containerLogLines(
        'abc123',
        tty: false,
        since: const LogTimestamp(1780000000, 500),
        tail: 100,
      );
      await daemon.gotBytes(1);
      final body = stdcopyFrame(1, 'hello\n');
      daemon.feed(
        wireResponse(
          '200 OK',
          headers: {
            'Content-Type': contentTypeMultiplexed,
            'Content-Length': '${body.length}',
          },
          body: body,
        ),
      );
      final res = await sent;
      final lines = await res.body.toList();
      expect(lines.single.text, 'hello');
      expect(
        daemon.text,
        startsWith(
          'GET /v1.52/containers/abc123/logs?follow=1&stdout=1&stderr=1'
          '&timestamps=1&tail=100&since=1780000000.000000500',
        ),
      );
    });

    test('drops the re-sent inclusive boundary line', () async {
      final daemon = FakeDaemon();
      final client = clientFor(daemon, const ApiVersion(1, 52));
      final since = LogTimestamp.tryParse('2026-05-01T10:20:30.000000000Z')!;
      final sent = client.containerLogLines('abc123', tty: false, since: since);
      await daemon.gotBytes(1);
      final body = [
        ...stdcopyFrame(1, '2026-05-01T10:20:30.000000000Z old\n'),
        ...stdcopyFrame(1, '2026-05-01T10:20:31.000000000Z new\n'),
      ];
      daemon.feed(
        wireResponse(
          '200 OK',
          headers: {
            'Content-Type': contentTypeMultiplexed,
            'Content-Length': '${body.length}',
          },
          body: body,
        ),
      );
      final res = await sent;
      final lines = await res.body.toList();
      expect(lines.map((l) => l.text), ['2026-05-01T10:20:31.000000000Z new']);
    });
  });

  group('tolerance', () {
    test('a malformed body becomes a warning, not a throw', () async {
      final daemon = FakeDaemon();
      final client = clientFor(daemon, const ApiVersion(1, 44));
      final sent = client.listContainers();
      await daemon.gotBytes(1);
      daemon.feed(
        wireResponse(
          '200 OK',
          headers: {'Content-Length': '3'},
          body: utf8Of('nope'),
        ),
      );
      final r = await sent;
      expect(r.value, isEmpty);
      expect(r.warnings, isNotEmpty);
    });
  });
}
