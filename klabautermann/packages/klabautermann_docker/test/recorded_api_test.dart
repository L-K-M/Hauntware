/// Replays the recorded API corpora (03 §11.1, D21) through the real
/// HTTP client and the typed endpoints: negotiation and refusals, every
/// parser, the version gates, log framing and resume, and stats.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:klabautermann_docker/testing.dart';
import 'package:test/test.dart';

import 'harness.dart';

/// The exchanges whose response is buffered whole and parsed by a typed
/// endpoint; [_callEndpoint] maps each to its call.
const List<String> _bufferedEndpoints = [
  'info',
  'containers',
  'containers-size',
  'stats-oneshot',
  'images',
  'image-inspect',
  'networks',
  'volumes',
  'system-df',
];

void main() {
  for (final name in recordedCorpusNames) {
    group(name, () {
      late RecordedCorpus corpus;
      setUpAll(() => corpus = recordedCorpus(name));

      Future<T> replay<T>(
        Future<T> Function(DockerClient client, DockerNegotiation negotiation)
        body, {
        RecordedChunking chunking = RecordedChunking.whole,
      }) async {
        final daemon = RecordedDaemon(corpus, chunking: chunking);
        final http = DockerHttpClient(daemon.opener);
        try {
          final (client, negotiation) = await negotiateDockerClient(http);
          final result = await body(client, negotiation);
          expect(daemon.unmatched, isEmpty, reason: 'unrecorded requests');
          return result;
        } finally {
          await http.close();
        }
      }

      test('negotiates the native version from _ping and /version', () async {
        for (final chunking in RecordedChunking.values) {
          final daemon = RecordedDaemon(corpus, chunking: chunking);
          final http = DockerHttpClient(daemon.opener);
          final (client, negotiation) = await negotiateDockerClient(http);
          final ping = await client.ping();
          await http.close();

          expect(negotiation.negotiated, corpus.apiVersion);
          expect(negotiation.serverMax, corpus.apiVersion);
          expect(negotiation.serverMin, corpus.minApiVersion);
          expect(negotiation.isPodman, corpus.isPodman);
          expect(ping.isPodman, corpus.isPodman);
          expect(ping.apiVersion, corpus.apiVersion);
          // HEAD /_ping answers on every recorded daemon: no GET fallback.
          expect(daemon.requests, [
            'HEAD /_ping',
            'GET /version',
            'HEAD /_ping',
          ]);
          expect(daemon.unmatched, isEmpty);
        }
      });

      test('refuses below the client floor and the server minimum', () async {
        Future<NegotiationRefusal> refusal(ApiVersion clientMax) async {
          final http = DockerHttpClient(RecordedDaemon(corpus).opener);
          try {
            await negotiateDockerClient(http, clientMax: clientMax);
            fail('negotiation with client max $clientMax succeeded');
          } on NegotiationRefusedException catch (e) {
            expect(e.serverMax, corpus.apiVersion);
            return e.reason;
          } finally {
            await http.close();
          }
        }

        final belowFloor = ApiVersion(
          clientApiFloor.major,
          clientApiFloor.minor - 1,
        );
        expect(await refusal(belowFloor), NegotiationRefusal.belowClientFloor);

        final min = corpus.minApiVersion;
        if (min > clientApiFloor) {
          expect(
            await refusal(ApiVersion(min.major, min.minor - 1)),
            NegotiationRefusal.belowServerMinimum,
          );
        }
      });

      test('the daemon refuses versions outside its range', () async {
        final http = DockerHttpClient(RecordedDaemon(corpus).opener);
        addTearDown(http.close);
        Future<DockerParseResult<EngineInfo>> infoAt(String exchange) =>
            DockerClient(
              http,
              apiVersion: corpus[exchange].pathVersion!,
            ).engineInfo();

        if (corpus.isPodman) {
          // 03 §11.1: Podman answers versioned paths outside its range,
          // so the client-side refusal is the only one there.
          for (final exchange in ['below-min', 'above-max', 'floor-1.41']) {
            final info = await infoAt(exchange);
            expect(info.warnings, isEmpty, reason: exchange);
          }
          return;
        }

        await expectLater(
          infoAt('above-max'),
          throwsA(
            isA<DockerVersionException>()
                .having(
                  (e) => e.clientVersion,
                  'clientVersion',
                  corpus['above-max'].pathVersion,
                )
                .having(
                  (e) => e.serverMaxVersion,
                  'serverMaxVersion',
                  corpus.apiVersion,
                ),
          ),
        );
        await expectLater(
          infoAt('below-min'),
          throwsA(
            isA<DockerVersionException>().having(
              (e) => e.daemonMessage,
              'daemonMessage',
              contains('too old'),
            ),
          ),
        );
        // Docker 29.0 to 29.2 refuse the client floor (03 §5.8); the
        // negotiated version never goes below the daemon's minimum.
        if (corpus.minApiVersion > clientApiFloor) {
          expect(corpus['floor-1.41'].status, 400);
          await expectLater(
            infoAt('floor-1.41'),
            throwsA(isA<DockerVersionException>()),
          );
        } else {
          expect((await infoAt('floor-1.41')).warnings, isEmpty);
        }
      });

      test('every typed endpoint parses without warnings', () async {
        final inspects = [
          for (final e in corpus.exchanges)
            if (e.name.startsWith('inspect-') && e.status == 200) e.name,
        ];
        expect(inspects, hasLength(corpus.seededContainers.length));

        for (final chunking in RecordedChunking.values) {
          await replay((client, _) async {
            final warnings = <String, List<String>>{};
            for (final exchange in [..._bufferedEndpoints, ...inspects]) {
              warnings[exchange] = await _callEndpoint(
                client,
                corpus,
                exchange,
              );
            }
            warnings['events'] = [
              await for (final e in _events(client, corpus)) ...e.warnings,
            ];
            for (final MapEntry(:key, :value) in warnings.entries) {
              expect(value, isEmpty, reason: '$key ($chunking)');
            }

            await expectLater(
              client.inspectContainer('klab-missing'),
              throwsA(isA<DockerNotFoundException>()),
            );
          }, chunking: chunking);
        }
      });

      test('events carry the legacy fields below 1.52 only', () async {
        await replay((client, negotiation) async {
          final events = [
            await for (final e in _events(client, corpus)) e.value,
          ];
          expect(events, isNotEmpty);
          // Podman's 1.44 compat layer sends the legacy fields too.
          final legacy = !negotiation.gates.usesEventV2;
          for (final e in events) {
            if (e.type == 'container') expect(e.isLegacy, legacy);
            expect(e.timestamp, isNotNull);
          }
          final started = {
            for (final e in events)
              if (e.type == 'container' && e.action == 'start') e.name,
          };
          expect(started, containsAll(['web', 'worker', 'job']));
        });
      });

      test('image use agrees with the container list', () async {
        await replay((client, negotiation) async {
          final containers = (await client.listContainers()).value;
          final images = (await client.listImages()).value;
          final usedIds = {for (final c in containers) c.imageId};
          final computed = images.where((i) => usedIds.contains(i.id));

          for (final image in images) {
            if (!negotiation.gates.hasImageContainersCount) {
              // Below 1.51 the count is not read (03 §5.8).
              expect(image.containers, isNull);
              continue;
            }
            final using = containers.where((c) => c.imageId == image.id);
            expect(image.containers, using.length, reason: image.id);
          }
          expect(
            dockerSummary(containers, images).imagesInUse,
            computed.length,
          );
          expect(images.where((i) => i.isDangling), hasLength(1));
        });
      });

      test('logs Content-Type agrees with Config.Tty', () async {
        await replay((client, negotiation) async {
          for (final (container, exchange) in [
            ('job', 'logs-tail'),
            ('tty', 'logs-tail-tty'),
          ]) {
            final inspect = (await client.inspectContainer(container)).value;
            final tty = inspect.config!.tty;
            expect(tty, container == 'tty');

            final contentType = corpus[exchange].headers['content-type'];
            final choice = resolveLogFraming(
              negotiated: negotiation.negotiated,
              tty: tty,
              contentType: contentType,
            );
            expect(
              choice.framing,
              tty ? LogFraming.raw : LogFraming.multiplexed,
            );
            if (corpus.isPodman) {
              // 03 §5.6: Podman sends no logs Content-Type even at 1.44,
              // so Config.Tty decides, with a warning.
              expect(contentType, isNull);
              expect(choice.warning, contains('no Content-Type'));
            } else if (negotiation.gates.hasLogsContentType) {
              expect(contentType, isNotNull);
              expect(choice.warning, isNull);
            } else {
              expect(contentType, isNull);
              expect(choice.warning, isNull);
            }

            final res = await client.containerLogLines(
              container,
              tty: tty,
              follow: false,
              tail: 20,
            );
            final lines = await res.body.toList();
            expect(lines, isNotEmpty, reason: exchange);
            for (final line in lines) {
              expect(
                parseTimestampedLogLine(line).value.timestamp,
                isNotNull,
                reason: line.text,
              );
            }
          }
        });
      });

      test('/system/df agrees with the lists', () async {
        await replay((client, _) async {
          final df = await client.systemDf();
          expect(df.warnings, isEmpty);
          final containers = (await client.listContainers()).value;
          final images = (await client.listImages()).value;
          final volumes = (await client.listVolumes()).value;

          expect(df.value.containers?.totalCount, containers.length);
          // Podman lists an image once per name in /system/df (the seed
          // image under its tag and its digest reference), where
          // /images/json lists it once.
          final imageRows = corpus.isPodman
              ? images.fold(0, (n, i) => n + math.max(1, i.repoTags.length))
              : images.length;
          expect(df.value.images?.totalCount, imageRows);
          expect(df.value.volumes?.totalCount, volumes.length);
        });
      });

      test('the follow demultiplexes into every line', () async {
        await replay((client, _) async {
          final lines = await _follow(client);
          expect(lines, hasLength(jobLineCount));
          for (final stream in [StdcopyKind.stdout, StdcopyKind.stderr]) {
            final messages = [
              for (final l in lines)
                if (l.stream == stream) _message(l),
            ];
            expect(messages, [
              for (var i = 1; i <= jobLineCount ~/ 2; i++)
                '${stream.name} line $i',
            ]);
          }
        });
      });

      test('since resumes with no lost or repeated line', () async {
        await replay((client, _) async {
          final follow = await _follow(client);
          final since = _parseSince(corpus['logs-since'].query['since']!);

          final res = await client.containerLogLines(
            'job',
            tty: false,
            follow: false,
            since: since,
          );
          final resumed = [for (final l in await res.body.toList()) _key(l)];
          final expected = [
            for (final l in follow)
              if (_timestamp(l) > since) _key(l),
          ];
          expect(resumed..sort(), expected..sort());
          expect(resumed, isNotEmpty);

          // An inclusive resend from the last delivered timestamp repeats
          // the boundary lines; dropInclusiveSince removes exactly those.
          final delivered = [
            for (final l in follow)
              if (_timestamp(l) <= since) l,
          ];
          final last = lastDeliveredTimestamp(
            delivered.map((l) => parseTimestampedLogLine(l).value),
          )!;
          final resend = [
            for (final l in follow)
              if (_timestamp(l) >= last) l,
          ];
          expect(resend.length, greaterThan(expected.length));
          final kept = [
            await for (final l in dropInclusiveSinceLines(
              Stream.fromIterable(resend),
              last,
            ))
              _key(l),
          ];
          expect(kept..sort(), expected);
        });
      });

      test('one-shot stats, then a delta from the stream', () async {
        await replay((client, _) async {
          final oneShot = await client.containerStatsOneShot('web');
          expect(oneShot.warnings, isEmpty);
          // 03 §5.6: the one-shot precpu_stats is zeroed, so CPU needs a
          // second sample.
          expect(oneShot.value.preCpu.totalUsage ?? 0, 0);
          expect(oneShot.value.preCpu.systemCpuUsage ?? 0, 0);
          final single = computeStatsDelta(oneShot.value);
          expect(single.cpuPercent, isNull);
          expect(single.memoryUsage, isNotNull);

          final samples = await client
              .containerStatsStream('web')
              .take(2)
              .toList();
          for (final s in samples) {
            expect(s.warnings, isEmpty);
          }
          final delta = computeStatsDelta(
            samples[1].value,
            previous: samples[0].value,
          );
          expect(delta.cpuPercent, isNotNull);
          expect(delta.cpuPercent, greaterThanOrEqualTo(0));
        });
      });
    });
  }
}

/// Lines `job` prints, half on stdout and half on stderr.
const int jobLineCount = 2000;

Future<List<String>> _callEndpoint(
  DockerClient client,
  RecordedCorpus corpus,
  String exchange,
) async {
  if (exchange.startsWith('inspect-')) {
    final name = exchange.substring('inspect-'.length);
    return (await client.inspectContainer(name)).warnings;
  }
  return switch (exchange) {
    'info' => (await client.engineInfo()).warnings,
    'containers' => (await client.listContainers()).warnings,
    'containers-size' => (await client.listContainers(sizes: true)).warnings,
    'stats-oneshot' => (await client.containerStatsOneShot('web')).warnings,
    'images' => (await client.listImages()).warnings,
    'image-inspect' => (await client.inspectImage(
      _imageRef(corpus['image-inspect'].path),
    )).warnings,
    'networks' => (await client.listNetworks()).warnings,
    'volumes' => (await client.listVolumes()).warnings,
    'system-df' => (await client.systemDf()).warnings,
    _ => throw ArgumentError.value(exchange, 'exchange'),
  };
}

/// The image reference in an `/images/<ref>/json` path.
String _imageRef(String path) {
  const prefix = '/images/';
  final start = path.indexOf(prefix) + prefix.length;
  return path.substring(start, path.length - '/json'.length);
}

Stream<DockerParseResult<DockerEvent>> _events(
  DockerClient client,
  RecordedCorpus corpus,
) {
  final query = corpus['events'].query;
  return client.events(
    since: LogTimestamp.fromUnix(int.parse(query['since']!)),
    until: LogTimestamp.fromUnix(int.parse(query['until']!)),
  );
}

Future<List<LogLine>> _follow(DockerClient client) async {
  final res = await client.containerLogLines('job', tty: false);
  return res.body.toList();
}

LogTimestamp _parseSince(String value) {
  final dot = value.indexOf('.');
  return LogTimestamp(
    int.parse(value.substring(0, dot)),
    int.parse(value.substring(dot + 1)),
  );
}

LogTimestamp _timestamp(LogLine line) =>
    parseTimestampedLogLine(line).value.timestamp!;

String _message(LogLine line) => parseTimestampedLogLine(line).value.message;

String _key(LogLine line) => '${line.stream.name} ${_message(line)}';
