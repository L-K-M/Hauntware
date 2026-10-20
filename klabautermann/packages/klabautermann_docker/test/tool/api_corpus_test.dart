// Pure tests of the recorded Docker API corpus format and check mode
// (tool/src/api_corpus.dart; 03 §11.1, D21).
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../../tool/src/api_corpus.dart';

Uint8List _bytes(String text) => Uint8List.fromList(latin1.encode(text));

String _head(String status, List<String> headers) =>
    'HTTP/1.1 $status\r\n${headers.map((h) => '$h\r\n').join()}\r\n';

String _chunked(List<String> chunks, {bool last = true}) => [
  for (final c in chunks)
    '${utf8.encode(c).length.toRadixString(16)}\r\n$c\r\n',
  if (last) '0\r\n\r\n',
].join();

const _json = 'Content-Type: application/json';
const _te = 'Transfer-Encoding: chunked';

void main() {
  group('parseRecordedResponse', () {
    test('reads a Content-Length body', () {
      final r = parseRecordedResponse(
        _bytes('${_head('200 OK', [_json, 'Content-Length: 7'])}{"a":1}'),
      );
      expect(r.statusCode, 200);
      expect(r.reasonPhrase, 'OK');
      expect(r.framing, BodyFraming.length);
      expect(utf8.decode(r.body), '{"a":1}');
      expect(r.complete, isTrue);
      expect(r.mediaType, 'application/json');
      expect(r.header('CONTENT-TYPE'), 'application/json');
    });

    test('removes chunked framing', () {
      final r = parseRecordedResponse(
        _bytes('${_head('200 OK', [_te])}${_chunked(['{"a":', '1}'])}'),
      );
      expect(r.framing, BodyFraming.chunked);
      expect(utf8.decode(r.body), '{"a":1}');
      expect(r.complete, isTrue);
    });

    test('marks a chunked body without its last chunk incomplete', () {
      final r = parseRecordedResponse(
        _bytes('${_head('200 OK', [_te])}${_chunked(['x\n'], last: false)}'),
      );
      expect(utf8.decode(r.body), 'x\n');
      expect(r.complete, isFalse);
    });

    test('reads a close-delimited body', () {
      final r = parseRecordedResponse(_bytes('${_head('200 OK', [])}rest'));
      expect(r.framing, BodyFraming.close);
      expect(utf8.decode(r.body), 'rest');
    });

    test('keeps the raw stream after a 101 upgrade', () {
      final r = parseRecordedResponse(
        _bytes(
          '${_head('101 UPGRADED', ['Connection: Upgrade', 'Upgrade: tcp'])}'
          '\x01\x00\x00\x00\x00\x00\x00\x01x',
        ),
      );
      expect(r.framing, BodyFraming.upgraded);
      expect(r.body, hasLength(9));
      expect(r.complete, isTrue);
      expect(classifyBody(r.body), BodyKind.stdcopy);
    });

    test('gives a HEAD response no body', () {
      final r = parseRecordedResponse(
        _bytes(_head('200 OK', ['Content-Length: 2', 'Api-Version: 1.55'])),
        headRequest: true,
      );
      expect(r.framing, BodyFraming.none);
      expect(r.body, isEmpty);
      expect(r.header('api-version'), '1.55');
    });

    test('refuses what is not an HTTP response', () {
      for (final bad in [
        'HTTP/1.1 200 OK\r\n',
        'HTTP/2 200\r\n\r\n',
        _head('200 OK', ['no colon']),
        '${_head('200 OK', ['Content-Length: 1'])}ab',
        '${_head('200 OK', [_te])}zz\r\n',
        '${_head('200 OK', [_te])}${_chunked(['a'])}extra',
      ]) {
        expect(
          () => parseRecordedResponse(_bytes(bad)),
          throwsFormatException,
          reason: bad,
        );
      }
    });
  });

  group('truncationPoint', () {
    final head = _head('200 OK', [_te]);

    test('cuts at the end of the chunk completing the line', () {
      final raw = '$head${_chunked(['{"n":1}\n', '{"n":2}\n', '{"n":3}\n'])}';
      final cut = truncationPoint(_bytes(raw), 2)!;
      expect(
        latin1.decode(_bytes(raw).sublist(0, cut)),
        '$head${_chunked(['{"n":1}\n', '{"n":2}\n'], last: false)}',
      );
      final r = parseRecordedResponse(_bytes(raw).sublist(0, cut));
      expect(r.complete, isFalse);
      expect(jsonValues(r.body), hasLength(2));
    });

    test('keeps the whole chunk when a line ends inside it', () {
      final raw = '$head${_chunked(['{"n":', '1}\n{"n":2}\n', '{"n":3}\n'])}';
      final cut = truncationPoint(_bytes(raw), 1)!;
      expect(
        latin1.decode(_bytes(raw).sublist(0, cut)),
        '$head${_chunked(['{"n":', '1}\n{"n":2}\n'], last: false)}',
      );
    });

    test('is null when that chunk ends inside the next line', () {
      // A cut there would keep a partial line, which reads as text.
      final raw = '$head${_chunked(['{"n":', '1}\n{"n":2}\n{"n"', ':3}\n'])}';
      expect(truncationPoint(_bytes(raw), 1), isNull);
    });

    test('cuts a close-delimited body after the newline', () {
      final raw = '${_head('200 OK', [])}a\nb\nc\n';
      final cut = truncationPoint(_bytes(raw), 2)!;
      expect(latin1.decode(_bytes(raw).sublist(0, cut)), endsWith('a\nb\n'));
    });

    test('is null with too few lines or a Content-Length body', () {
      expect(truncationPoint(_bytes('$head${_chunked(['a\n'])}'), 2), isNull);
      expect(
        truncationPoint(
          _bytes('${_head('200 OK', ['Content-Length: 4'])}a\nb\n'),
          1,
        ),
        isNull,
      );
    });
  });

  group('classifyBody', () {
    Uint8List frame(int stream, String text) {
      final payload = utf8.encode(text);
      return Uint8List.fromList([
        stream,
        0,
        0,
        0,
        ...(ByteData(4)..setUint32(0, payload.length)).buffer.asUint8List(),
        ...payload,
      ]);
    }

    test('tells the kinds apart', () {
      expect(classifyBody(Uint8List(0)), BodyKind.empty);
      expect(classifyBody(_bytes('{"a":[1]}\n')), BodyKind.json);
      expect(classifyBody(_bytes('{"a":1}\n{"b":2}\n')), BodyKind.jsonLines);
      expect(classifyBody(_bytes('OK')), BodyKind.text);
      expect(
        classifyBody(_bytes('2026-01-01T00:00:00Z tty\r\n')),
        BodyKind.text,
      );
      final frames = Uint8List.fromList([
        ...frame(1, 'out\n'),
        ...frame(2, 'err\n'),
      ]);
      expect(classifyBody(frames), BodyKind.stdcopy);
      expect(
        classifyBody(Uint8List.sublistView(frames, 0, frames.length - 1)),
        BodyKind.text,
      );
      expect(
        [
          for (final (stream, payload) in stdcopyFrames(frames))
            '$stream ${utf8.decode(payload)}',
        ],
        ['1 out\n', '2 err\n'],
      );
    });
  });

  group('jsonKeyPaths', () {
    test('lists nested keys, merging list elements', () {
      expect(
        jsonKeyPaths({
          'Id': 'x',
          'State': {
            'Health': {
              'Status': 'healthy',
              'Log': [
                {'ExitCode': 0},
                {'Output': ''},
              ],
            },
          },
          'Names': ['/web'],
        }),
        {
          'Id',
          'State',
          'State.Health',
          'State.Health.Status',
          'State.Health.Log',
          'State.Health.Log[].ExitCode',
          'State.Health.Log[].Output',
          'Names',
        },
      );
      expect(
        jsonKeyPaths([
          {'a': 1},
          {'b': 2},
        ]),
        {'[].a', '[].b'},
      );
    });

    test('leaves out keys that follow the host, not the API', () {
      // Docker 25's /info on a cgroup v1 host and on a cgroup v2 host.
      final v1 = {'KernelMemory': true, 'KernelMemoryTCP': true, 'Name': 'h'};
      final v2 = {'Name': 'h'};
      expect(jsonKeyPaths(v1), {'Name'});
      expect(jsonKeyPaths(v1), jsonKeyPaths(v2));
      // Below the top level they are API shape: 1.41's inspect has them
      // in HostConfig, and later versions drop them.
      expect(
        jsonKeyPaths({
          'HostConfig': {'KernelMemory': 0},
        }),
        {'HostConfig', 'HostConfig.KernelMemory'},
      );
    });

    test('stops below free-form maps and collapses id keys', () {
      final id = 'a' * 64;
      expect(
        jsonKeyPaths({
          'Labels': {'com.example': 'v'},
          'memory_stats': {
            'stats': {'anon': 1},
          },
          'Containers': {
            id: {'Name': 'web'},
          },
        }),
        {
          'Labels',
          'memory_stats',
          'Containers',
          'Containers.<id>',
          'Containers.<id>.Name',
        },
      );
    });
  });

  group('check mode', () {
    Map<String, Uint8List> corpus({
      String version = '29.7.2',
      String id = 'one',
      String containersBody = '[{"Id":"one","Names":["/web"]}]',
      int status = 200,
      String contentType = 'application/json',
      List<String> extraHeaders = const [],
      List<String> order = const ['version', 'containers'],
    }) {
      final versionBody = '{"Version":"$version"}';
      final versionHead = _head('200 OK', [
        _json,
        'Api-Version: 1.55',
        'Content-Length: ${versionBody.length}',
      ]);
      final responses = {
        'version': ('GET /version', 200, '$versionHead$versionBody'),
        'containers': (
          'GET /v1.55/containers/json?all=1',
          status,
          _head('$status X', [
                'Content-Type: $contentType',
                'Date: Sat, 17 Oct 2026 10:00:0${id.length} GMT',
                ...extraHeaders,
                _te,
              ]) +
              _chunked([containersBody.replaceAll('one', id)]),
        ),
      };
      final manifest = CorpusManifest(
        corpus: 'api-1.55',
        capturedAt: '2026-10-17T10:00:00Z',
        daemon: DaemonFacts(
          runtime: 'docker',
          version: version,
          apiVersion: '1.55',
          minApiVersion: '1.40',
          details: const {'cgroupVersion': '2'},
        ),
        images: const {'seed': 'busybox'},
        seeded: {
          'containers': {'web': id},
        },
        exchanges: [
          for (final name in order)
            ExchangeEntry(
              name: name,
              request: responses[name]!.$1,
              status: responses[name]!.$2,
              contentType: name == 'version' ? _json : contentType,
              framing: name == 'version'
                  ? BodyFraming.length
                  : BodyFraming.chunked,
            ),
        ],
      );
      return {
        manifestFileName: _bytes(manifest.encode()),
        for (final MapEntry(:key, :value) in responses.entries)
          '$key.http': _bytes(value.$3),
      };
    }

    List<String> diff(Map<String, Uint8List> a, Map<String, Uint8List> b) =>
        compareCorpora(readCorpus((f) => a[f]), readCorpus((f) => b[f]));

    test('ignores ids, dates and the volatile headers', () {
      expect(diff(corpus(), corpus(id: 'another-id')), isEmpty);
    });

    test('reports a new or missing key', () {
      expect(
        diff(
          corpus(),
          corpus(containersBody: '[{"Id":"one","Names":[],"Health":{}}]'),
        ),
        ['containers: key [].Health is new'],
      );
      expect(diff(corpus(), corpus(containersBody: '[{"Id":"one"}]')), [
        'containers: key [].Names is gone',
      ]);
    });

    test('reports status, content type and header name changes', () {
      expect(
        diff(corpus(), corpus(status: 400, containersBody: '{"message":"x"}')),
        containsAll([
          'containers: status 200, now 400',
          'containers: key message is new',
        ]),
      );
      expect(diff(corpus(), corpus(contentType: 'text/plain')), [
        'containers: content type application/json, now text/plain',
      ]);
      expect(diff(corpus(), corpus(extraHeaders: ['Ostype: linux'])), [
        'containers: header ostype is new',
      ]);
    });

    test('reports the daemon version and the exchange order', () {
      expect(diff(corpus(), corpus(version: '29.7.3')), [
        'daemon version 29.7.2, now 29.7.3',
      ]);
      expect(diff(corpus(), corpus(order: ['containers', 'version'])), [
        'exchanges version containers, now containers version',
      ]);
    });

    test('refuses a file that disagrees with the manifest', () {
      final files = corpus();
      files['containers.http'] = _bytes(
        '${_head('404 Not Found', [_json, 'Content-Length: 2'])}{}',
      );
      expect(() => readCorpus((f) => files[f]), throwsFormatException);

      final cut = corpus();
      final raw = latin1.decode(cut['containers.http']!);
      cut['containers.http'] = _bytes(raw.replaceAll('0\r\n\r\n', ''));
      expect(() => readCorpus((f) => cut[f]), throwsFormatException);

      final missing = corpus()..remove('version.http');
      expect(() => readCorpus((f) => missing[f]), throwsFormatException);
    });

    test('round-trips the manifest', () {
      final json = utf8.decode(corpus()[manifestFileName]!);
      final manifest = CorpusManifest.fromJson(
        jsonDecode(json) as Map<String, Object?>,
      );
      expect(manifest.encode(), json);
      expect(manifest.daemon.details, {'cgroupVersion': '2'});
      expect(manifest.exchanges.last.target.queryParameters, {'all': '1'});
    });
  });
}
