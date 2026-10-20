// Exec endpoint tests (03 §5.7, §7.13 CTX-07, CTX-08) over a fake daemon:
// the create body by API version, a hijacked start whose stdcopy frames
// split across reads, the resize query rows first, and inspect.
import 'dart:convert';
import 'dart:typed_data';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

import 'harness.dart';

DockerClient _client(FakeDaemon daemon, ApiVersion version) => DockerClient(
  DockerHttpClient(() async => daemon.pair.client),
  apiVersion: version,
);

List<int> _json(String status, Object body) {
  final bytes = utf8.encode(jsonEncode(body));
  return wireResponse(
    status,
    headers: {
      'Content-Type': 'application/json',
      'Content-Length': '${bytes.length}',
    },
    body: bytes,
  );
}

/// The JSON body of the request [daemon] received.
Map<String, Object?> _body(FakeDaemon daemon) {
  final text = utf8.decode(daemon.received);
  return jsonDecode(text.substring(text.indexOf('\r\n\r\n') + 4))
      as Map<String, Object?>;
}

/// One stdcopy frame: type, three zero bytes, big-endian length, payload.
List<int> _frame(int type, String payload) {
  final bytes = utf8.encode(payload);
  final header = ByteData(8)
    ..setUint8(0, type)
    ..setUint32(4, bytes.length);
  return [...header.buffer.asUint8List(), ...bytes];
}

const _size = ExecConsoleSize(rows: 40, columns: 120);

void main() {
  group('create', () {
    test('attaches all three streams and sends the console size rows first '
        'from API 1.42', () async {
      final daemon = FakeDaemon();
      final sent = _client(daemon, const ApiVersion(1, 44)).createExec(
        'c1',
        ['/bin/sh'],
        tty: true,
        user: 'app',
        workingDir: '/srv',
        consoleSize: _size,
      );
      await daemon.gotText('}');
      daemon.feed(_json('201 Created', {'Id': 'e1'}));
      expect(await sent, 'e1');
      expect(daemon.text, startsWith('POST /v1.44/containers/c1/exec'));
      expect(_body(daemon), {
        'AttachStdin': true,
        'AttachStdout': true,
        'AttachStderr': true,
        'Tty': true,
        'Cmd': ['/bin/sh'],
        'User': 'app',
        'WorkingDir': '/srv',
        'ConsoleSize': [40, 120],
      });
    });

    test('leaves the console size out below API 1.42', () async {
      final daemon = FakeDaemon();
      final sent = _client(
        daemon,
        const ApiVersion(1, 41),
      ).createExec('c1', ['id'], stdin: false, consoleSize: _size);
      await daemon.gotText('}');
      daemon.feed(_json('201 Created', {'Id': 'e2'}));
      expect(await sent, 'e2');
      final body = _body(daemon);
      expect(body.containsKey('ConsoleSize'), isFalse);
      expect(body['AttachStdin'], isFalse);
      expect(body.containsKey('User'), isFalse);
    });

    test('a reply without an id is a protocol error', () async {
      final daemon = FakeDaemon();
      final sent = _client(
        daemon,
        const ApiVersion(1, 44),
      ).createExec('c1', ['id']);
      await daemon.gotText('}');
      daemon.feed(_json('201 Created', {'Warnings': []}));
      await expectLater(sent, throwsA(isA<DockerProtocolException>()));
    });

    test('an empty command is refused before any request', () {
      final daemon = FakeDaemon();
      expect(
        () => _client(daemon, const ApiVersion(1, 44)).createExec('c1', []),
        throwsArgumentError,
      );
    });
  });

  group('start', () {
    test('hijacks with Upgrade: tcp and demultiplexes frames split across '
        'reads', () async {
      final daemon = FakeDaemon();
      final sent = _client(
        daemon,
        const ApiVersion(1, 44),
      ).startExec('e1', consoleSize: _size);
      await daemon.gotText('}');
      final frames = [
        ..._frame(1, 'hello '),
        ..._frame(2, 'oops'),
        ..._frame(1, 'world'),
      ];
      daemon.feed(
        latin1.encode(
          'HTTP/1.1 101 UPGRADED\r\nContent-Type: '
          'application/vnd.docker.multiplexed-stream\r\n'
          'Connection: Upgrade\r\nUpgrade: tcp\r\n\r\n',
        ),
      );
      final res = await sent;
      expect(res.statusCode, 101);
      expect(daemon.text, startsWith('POST /v1.44/exec/e1/start'));
      expect(daemon.text, contains('Upgrade: tcp'));
      expect(_body(daemon), {
        'Detach': false,
        'Tty': false,
        'ConsoleSize': [40, 120],
      });

      final out = StringBuffer();
      final err = StringBuffer();
      final done = demuxStdcopy(res.body.stream).forEach((f) {
        (f.stream == StdcopyKind.stderr ? err : out).write(
          utf8.decode(f.bytes),
        );
      });
      // A split inside a header and another inside a payload.
      daemon.feedChunks([
        frames.sublist(0, 3),
        frames.sublist(3, 17),
        frames.sublist(17),
      ]);
      await pumpEventQueue();
      await daemon.eof();
      await done;
      expect(out.toString(), 'hello world');
      expect(err.toString(), 'oops');
      await res.body.close();
    });
  });

  test('resize takes rows as h and columns as w', () async {
    final daemon = FakeDaemon();
    final sent = _client(
      daemon,
      const ApiVersion(1, 44),
    ).resizeExec('e1', const ExecConsoleSize(rows: 24, columns: 80));
    await daemon.gotBytes(1);
    daemon.feed(wireResponse('201 Created', headers: {'Content-Length': '0'}));
    await sent;
    expect(daemon.text, startsWith('POST /v1.44/exec/e1/resize?h=24&w=80'));
  });

  test('inspect reads whether the exec runs and its exit code', () async {
    final daemon = FakeDaemon();
    final sent = _client(daemon, const ApiVersion(1, 44)).inspectExec('e1');
    await daemon.gotBytes(1);
    daemon.feed(
      _json('200 OK', {
        'ID': 'e1',
        'Running': false,
        'ExitCode': 3,
        'Pid': 0,
        'ContainerID': 'c1',
        'ProcessConfig': {'entrypoint': 'sh'},
      }),
    );
    final r = await sent;
    expect(daemon.text, startsWith('GET /v1.44/exec/e1/json'));
    expect(r.warnings, isEmpty);
    expect(r.value.running, isFalse);
    expect(r.value.exitCode, 3);
    expect(r.value.containerId, 'c1');
  });

  test('a malformed inspect warns instead of throwing', () {
    expect(parseExecInspect([1]).warnings, isNotEmpty);
  });
}
