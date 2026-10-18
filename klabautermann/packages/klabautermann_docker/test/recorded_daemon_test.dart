import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:klabautermann_docker/testing.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late RecordedCorpus corpus;
  setUpAll(() => corpus = recordedCorpus('api-1.55'));

  test('serves the native recording to a lower negotiated version', () async {
    final daemon = RecordedDaemon(corpus);
    final http = DockerHttpClient(daemon.opener);
    addTearDown(http.close);
    final (client, negotiation) = await negotiateDockerClient(
      http,
      clientMax: const ApiVersion(1, 44),
    );

    expect(negotiation.negotiated, const ApiVersion(1, 44));
    final containers = await client.listContainers();
    expect(containers.value, hasLength(corpus.seededContainers.length));
    expect(daemon.requests.last, 'GET /v1.44/containers/json?all=1');
    expect(daemon.unmatched, isEmpty);
  });

  test('answers an unrecorded request with a 404 and lists it', () async {
    final daemon = RecordedDaemon(corpus);
    final http = DockerHttpClient(daemon.opener);
    addTearDown(http.close);

    // Below the daemon's minimum, with no recording of its own.
    final old = DockerClient(http, apiVersion: const ApiVersion(1, 30));
    await expectLater(
      old.engineInfo(),
      throwsA(isA<DockerNotFoundException>()),
    );
    final client = DockerClient(http, apiVersion: corpus.apiVersion);
    await expectLater(
      client.inspectContainer('never-seeded'),
      throwsA(isA<DockerNotFoundException>()),
    );
    expect(daemon.unmatched, [
      'GET /v1.30/info',
      'GET /v1.55/containers/never-seeded/json',
    ]);
  });

  test('keeps one connection alive across requests', () async {
    final daemon = RecordedDaemon(corpus);
    final http = DockerHttpClient(daemon.opener);
    addTearDown(http.close);
    final (client, _) = await negotiateDockerClient(http);

    await client.engineInfo();
    await client.listImages();
    await client.listNetworks();
    expect(daemon.connections, 1);
  });

  test('matches query values in either boolean spelling', () {
    expect(
      corpus.match('GET', '/v1.55/containers/web/stats?stream=true')?.name,
      'stats-stream',
    );
    expect(
      corpus.match('GET', '/v1.55/containers/json?all=true&size=0')?.name,
      'containers',
    );
    expect(corpus.match('GET', '/v1.55/containers/json'), isNull);
  });
}
