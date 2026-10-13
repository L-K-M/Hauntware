import 'dart:convert';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

import 'harness.dart';

List<int> jsonResponse(Map<String, String> headers, List<int> body) =>
    wireResponse(
      '200 OK',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': '${body.length}',
        ...headers,
      },
      body: body,
    );

void main() {
  group('ping', () {
    test('HEAD /_ping parses the negotiation headers', () async {
      final daemon = FakeDaemon();
      final http = DockerHttpClient(() async => daemon.pair.client);
      final client = DockerClient(http, apiVersion: const ApiVersion(1, 55));
      final sent = client.ping();
      await daemon.gotBytes(1);
      daemon.feed(
        wireResponse(
          '200 OK',
          headers: {
            'Api-Version': '1.52',
            'OSType': 'linux',
            'Docker-Experimental': 'false',
            'Builder-Version': '2',
            'Content-Length': '0',
          },
        ),
      );
      final ping = await sent;
      expect(daemon.text, startsWith('HEAD /_ping HTTP/1.1'));
      expect(ping.apiVersion, const ApiVersion(1, 52));
      expect(ping.osType, 'linux');
      expect(ping.dockerExperimental, isFalse);
      expect(ping.isPodman, isFalse);
    });

    test('falls back to GET /_ping when HEAD is refused', () async {
      final daemon = FakeDaemon();
      final http = DockerHttpClient(() async => daemon.pair.client);
      final client = DockerClient(http, apiVersion: const ApiVersion(1, 55));
      final sent = client.ping();
      await daemon.gotBytes(1);
      daemon.feed(
        wireResponse(
          '405 Method Not Allowed',
          headers: {'Content-Length': '0'},
        ),
      );
      await daemon.gotBytes(daemon.received.length + 1);
      daemon.feed(
        wireResponse(
          '200 OK',
          headers: {'Api-Version': '1.44', 'Content-Length': '2'},
          body: utf8Of('OK'),
        ),
      );
      final ping = await sent;
      expect(daemon.text, contains('GET /_ping HTTP/1.1'));
      expect(ping.apiVersion, const ApiVersion(1, 44));
    });

    test('Libpod-API-Version marks Podman', () async {
      final daemon = FakeDaemon();
      final http = DockerHttpClient(() async => daemon.pair.client);
      final client = DockerClient(http, apiVersion: const ApiVersion(1, 55));
      final sent = client.ping();
      await daemon.gotBytes(1);
      daemon.feed(
        wireResponse(
          '200 OK',
          headers: {
            'Api-Version': '1.44',
            'Libpod-API-Version': '5.4.1',
            'Content-Length': '0',
          },
        ),
      );
      expect((await sent).isPodman, isTrue);
    });
  });

  group('version and info', () {
    test('GET /version parses the fixture', () async {
      final daemon = FakeDaemon();
      final http = DockerHttpClient(() async => daemon.pair.client);
      final client = DockerClient(http, apiVersion: const ApiVersion(1, 55));
      final sent = client.version();
      await daemon.gotBytes(1);
      daemon.feed(jsonResponse({}, fixtureBytes('version-docker-29.3.json')));
      final v = await sent;
      expect(daemon.text, startsWith('GET /version HTTP/1.1'));
      expect(v.version, '29.3.1');
      expect(v.apiVersion, const ApiVersion(1, 55));
      expect(v.minApiVersion, const ApiVersion(1, 40));
    });

    test('GET /info is versioned and returns the raw map', () async {
      final daemon = FakeDaemon();
      final http = DockerHttpClient(() async => daemon.pair.client);
      final client = DockerClient(http, apiVersion: const ApiVersion(1, 44));
      final sent = client.info();
      await daemon.gotBytes(1);
      daemon.feed(jsonResponse({}, fixtureBytes('info.json')));
      final info = await sent;
      expect(daemon.text, startsWith('GET /v1.44/info HTTP/1.1'));
      expect(info['ServerVersion'], '29.3.1');
      expect(info['Driver'], 'overlay2');
    });
  });

  group('request plumbing', () {
    test('versioned path and JSON-encoded filters', () async {
      final daemon = FakeDaemon();
      final http = DockerHttpClient(() async => daemon.pair.client);
      final client = DockerClient(http, apiVersion: const ApiVersion(1, 44));
      final sent = client.request(
        'GET',
        '/containers/json',
        query: {'all': '1'},
        filters: {
          'status': ['running'],
          'label': ['com.docker.compose.project=web'],
        },
      );
      await daemon.gotBytes(1);
      daemon.feed(jsonResponse({}, utf8Of('[]')));
      await sent;
      final requestLine = daemon.text.split('\r\n').first;
      final target = requestLine.split(' ')[1];
      final uri = Uri.parse('http://docker$target');
      expect(uri.path, '/v1.44/containers/json');
      expect(uri.queryParameters['all'], '1');
      expect(jsonDecode(uri.queryParameters['filters']!), {
        'status': ['running'],
        'label': ['com.docker.compose.project=web'],
      });
    });

    test('requestLines streams NDJSON through the client', () async {
      final daemon = FakeDaemon();
      final http = DockerHttpClient(() async => daemon.pair.client);
      final client = DockerClient(http, apiVersion: const ApiVersion(1, 52));
      final sent = client.requestLines('GET', '/events');
      await daemon.gotBytes(1);
      final body = fixtureBytes('events.ndjson');
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
      final res = await sent;
      final events = await res.body.map(jsonDecode).toList();
      expect(events, hasLength(3));
      expect((events[0] as Map)['Type'], 'container');
      expect((events[2] as Map)['Action'], 'die');
    });

    test('typed errors propagate through request()', () async {
      final daemon = FakeDaemon();
      final http = DockerHttpClient(() async => daemon.pair.client);
      final client = DockerClient(http, apiVersion: const ApiVersion(1, 44));
      final sent = client.request('DELETE', '/containers/abc');
      await daemon.gotBytes(1);
      final body = utf8Of('{"message":"No such container: abc"}');
      daemon.feed(
        wireResponse(
          '404 Not Found',
          headers: {'Content-Length': '${body.length}'},
          body: body,
        ),
      );
      await expectThrows<DockerNotFoundException>(sent);
    });
  });

  group('negotiate', () {
    /// Scripts the two negotiation exchanges the client performs back to
    /// back: `/_ping` headers, then the `GET /version` document.
    Future<DockerNegotiation> negotiateOver(
      Map<String, String> pingHeaders,
      List<int> versionDoc,
    ) async {
      final daemon = FakeDaemon();
      final http = DockerHttpClient(() async => daemon.pair.client);
      final client = DockerClient(http, apiVersion: const ApiVersion(1, 55));
      final sent = client.negotiate();
      await daemon.gotBytes(1);
      daemon.feed(wireResponse('200 OK', headers: pingHeaders));
      await daemon.gotBytes(daemon.received.length + 1);
      daemon.feed(jsonResponse({}, versionDoc));
      return sent;
    }

    test('Docker 29.3: negotiates 1.55', () async {
      final n = await negotiateOver({
        'Api-Version': '1.55',
        'Content-Length': '0',
      }, fixtureBytes('version-docker-29.3.json'));
      expect(n.negotiated, const ApiVersion(1, 55));
      expect(n.isPodman, isFalse);
      expect(n.gates.usesEventV2, isTrue);
      expect(n.gates.hasAttestations, isTrue);
    });

    test('Docker 29.0: negotiates its 1.52 max', () async {
      final n = await negotiateOver({
        'Api-Version': '1.52',
        'Content-Length': '0',
      }, fixtureBytes('version-docker-29.0.json'));
      expect(n.negotiated, const ApiVersion(1, 52));
      expect(n.gates.usesEventV2, isTrue);
      expect(n.gates.hasAttestations, isFalse);
      expect(n.gates.systemDfShape, SystemDfShape.v152);
    });

    test('Podman: negotiated 1.44 and detected', () async {
      final n = await negotiateOver({
        'Api-Version': '1.44',
        'Libpod-API-Version': '5.4.1',
        'Content-Length': '0',
      }, fixtureBytes('version-podman.json'));
      expect(n.negotiated, const ApiVersion(1, 44));
      expect(n.isPodman, isTrue);
    });

    test('an engine below the floor is refused end to end', () async {
      final doc = utf8Of(
        '{"Version":"20.10.0","ApiVersion":"1.40","MinAPIVersion":"1.12"}',
      );
      await expectThrows<NegotiationRefusedException>(
        negotiateOver({'Api-Version': '1.40', 'Content-Length': '0'}, doc),
      );
    });

    test('negotiateDockerClient binds the negotiated version', () async {
      final daemon = FakeDaemon();
      final http = DockerHttpClient(() async => daemon.pair.client);
      final sent = negotiateDockerClient(http);
      await daemon.gotBytes(1);
      daemon.feed(
        wireResponse(
          '200 OK',
          headers: {'Api-Version': '1.52', 'Content-Length': '0'},
        ),
      );
      await daemon.gotBytes(daemon.received.length + 1);
      daemon.feed(jsonResponse({}, fixtureBytes('version-docker-29.0.json')));
      final (client, negotiation) = await sent;
      expect(negotiation.negotiated, const ApiVersion(1, 52));
      expect(client.apiVersion, const ApiVersion(1, 52));

      // The negotiated client versions subsequent paths.
      final info = client.info();
      await daemon.gotBytes(daemon.received.length + 1);
      daemon.feed(jsonResponse({}, fixtureBytes('info.json')));
      await info;
      expect(daemon.text, contains('GET /v1.52/info HTTP/1.1'));
    });
  });
}
