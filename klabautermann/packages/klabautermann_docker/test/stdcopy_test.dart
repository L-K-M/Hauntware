import 'dart:convert';
import 'dart:typed_data';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

import 'harness.dart';

/// One 8-byte-header stdcopy frame (03 §5.6).
List<int> frame(StdcopyKind kind, List<int> payload) {
  final n = payload.length;
  return <int>[
    kind.code,
    0,
    0,
    0,
    (n >> 24) & 0xFF,
    (n >> 16) & 0xFF,
    (n >> 8) & 0xFF,
    n & 0xFF,
    ...payload,
  ];
}

void main() {
  group('demuxStdcopy', () {
    test('frames of every stream type survive every split', () async {
      final wire = <int>[
        ...frame(StdcopyKind.stdout, utf8Of('hello\n')),
        ...frame(StdcopyKind.stderr, utf8Of('oops\n')),
        ...frame(StdcopyKind.stdin, utf8Of('in')),
        ...frame(StdcopyKind.systemerr, utf8Of('sys')),
        ...frame(StdcopyKind.stdout, utf8Of('world\n')),
      ];
      final expected = [
        (StdcopyKind.stdout, 'hello\n'),
        (StdcopyKind.stderr, 'oops\n'),
        (StdcopyKind.stdin, 'in'),
        (StdcopyKind.systemerr, 'sys'),
        (StdcopyKind.stdout, 'world\n'),
      ];
      for (var i = 0; i <= wire.length; i++) {
        final frames = await demuxStdcopy(
          Stream.fromIterable([wire.sublist(0, i), wire.sublist(i)]),
        ).toList();
        expect(
          frames.map((f) => '${f.stream.name}:${utf8.decode(f.bytes)}'),
          expected.map((e) => '${e.$1.name}:${e.$2}'),
          reason: 'split at byte $i',
        );
      }
    });

    test('an empty frame is legal', () async {
      final frames = await demuxStdcopy(
        Stream.value(frame(StdcopyKind.stdout, const <int>[])),
      ).toList();
      expect(frames.single.stream, StdcopyKind.stdout);
      expect(frames.single.bytes, isEmpty);
    });

    test('a frame over the size cap is a protocol error', () async {
      final wire = <int>[1, 0, 0, 0, 0, 0, 0, 100];
      await expectThrows<DockerProtocolException>(
        demuxStdcopy(Stream.value(wire), maxFrameBytes: 64).drain<void>(),
      );
    });

    test('an unknown stream type is a protocol error', () async {
      await expectThrows<DockerProtocolException>(
        demuxStdcopy(Stream.value(<int>[9, 0, 0, 0, 0, 0, 0, 0])).drain<void>(),
      );
    });

    test('a truncated frame at EOF is a protocol error', () async {
      final wire = frame(StdcopyKind.stdout, utf8Of('hello\n'));
      await expectThrows<DockerProtocolException>(
        demuxStdcopy(
          Stream.value(wire.sublist(0, wire.length - 3)),
        ).drain<void>(),
      );
    });

    test('a truncated header at EOF is a protocol error', () async {
      await expectThrows<DockerProtocolException>(
        demuxStdcopy(Stream.value(<int>[1, 0, 0])).drain<void>(),
      );
    });
  });

  group('rawLogFrames', () {
    test('each chunk becomes one stdout frame', () async {
      final frames = await rawLogFrames(
        Stream.fromIterable([utf8Of('a'), utf8Of('b')]),
      ).toList();
      expect(frames.map((f) => f.stream), [
        StdcopyKind.stdout,
        StdcopyKind.stdout,
      ]);
      expect(utf8.decode(frames[0].bytes), 'a');
    });
  });

  group('resolveLogFraming', () {
    const v141 = ApiVersion(1, 41);
    const v144 = ApiVersion(1, 44);

    test('below 1.42 Config.Tty decides', () {
      expect(
        resolveLogFraming(negotiated: v141, tty: true).framing,
        LogFraming.raw,
      );
      expect(
        resolveLogFraming(negotiated: v141, tty: false).framing,
        LogFraming.multiplexed,
      );
    });

    test('from 1.42 the header decides when present', () {
      expect(
        resolveLogFraming(
          negotiated: v144,
          tty: false,
          contentType: contentTypeMultiplexed,
        ).framing,
        LogFraming.multiplexed,
      );
      expect(
        resolveLogFraming(
          negotiated: v144,
          tty: true,
          contentType: contentTypeRawStream,
        ).framing,
        LogFraming.raw,
      );
    });

    test('a contradiction with Config.Tty warns', () {
      expect(
        resolveLogFraming(
          negotiated: v144,
          tty: true,
          contentType: contentTypeMultiplexed,
        ).warning,
        isNotNull,
      );
      expect(
        resolveLogFraming(
          negotiated: v144,
          tty: false,
          contentType: contentTypeRawStream,
        ).warning,
        isNotNull,
      );
      expect(
        resolveLogFraming(
          negotiated: v144,
          tty: false,
          contentType: contentTypeMultiplexed,
        ).warning,
        isNull,
      );
    });

    test(
      'missing or unknown header falls back to Config.Tty with a warning',
      () {
        for (final ct in <String?>[null, 'application/json']) {
          final c = resolveLogFraming(
            negotiated: v144,
            tty: false,
            contentType: ct,
          );
          expect(c.framing, LogFraming.multiplexed);
          expect(c.warning, isNotNull);
        }
      },
    );
  });

  group('splitLogLines', () {
    Future<List<String>> linesOf(
      List<StdcopyFrame> frames, {
      int? maxLineChars,
      StdcopyKind of = StdcopyKind.stdout,
    }) async {
      final lines = await splitLogLines(
        Stream.fromIterable(frames),
        maxLineChars: maxLineChars ?? defaultMaxLogLineChars,
      ).toList();
      return [for (final l in lines.where((l) => l.stream == of)) l.text];
    }

    StdcopyFrame out(String s) =>
        StdcopyFrame(StdcopyKind.stdout, Uint8List.fromList(utf8Of(s)));

    test('splits on \\n and normalizes \\r\\n', () async {
      expect(await linesOf([out('a\nb\r\nc')]), ['a', 'b', 'c']);
    });

    test('a partial final line flushes at EOF', () async {
      expect(await linesOf([out('a\ntail')]), ['a', 'tail']);
    });

    test('multibyte characters survive frame splits', () async {
      final text = 'héllo ✓ wörld\n';
      final bytes = utf8Of(text);
      for (var i = 0; i <= bytes.length; i++) {
        final lines = await linesOf([
          StdcopyFrame(
            StdcopyKind.stdout,
            Uint8List.fromList(bytes.sublist(0, i)),
          ),
          StdcopyFrame(
            StdcopyKind.stdout,
            Uint8List.fromList(bytes.sublist(i)),
          ),
        ]);
        expect(lines, ['héllo ✓ wörld'], reason: 'split at byte $i');
      }
    });

    test('overlong lines are hard split at the cap', () async {
      final s = 'x' * 300;
      expect(await linesOf([out('$s\ny')], maxLineChars: 100), [
        'x' * 100,
        'x' * 100,
        'x' * 100,
        'y',
      ]);
    });

    test('stdout and stderr keep separate pending lines', () async {
      final lines = await splitLogLines(
        Stream.fromIterable([
          out('out-a'),
          StdcopyFrame(StdcopyKind.stderr, Uint8List.fromList(utf8Of('err-a'))),
          out('-b\n'),
          StdcopyFrame(StdcopyKind.stderr, Uint8List.fromList(utf8Of('-b\n'))),
        ]),
      ).toList();
      expect(lines.map((l) => '${l.stream.name}:${l.text}'), [
        'stdout:out-a-b',
        'stderr:err-a-b',
      ]);
    });

    test('malformed UTF-8 is replaced, not thrown', () async {
      final frames = [
        StdcopyFrame(
          StdcopyKind.stdout,
          Uint8List.fromList(<int>[0x61, 0xFF, 0x62, 0x0A]),
        ),
      ];
      expect(await linesOf(frames), ['a�b']);
    });
  });

  group('BoundedLogRing', () {
    LogLine line(String s) => LogLine(StdcopyKind.stdout, s);

    test('drops the oldest lines past the count bound', () {
      final ring = BoundedLogRing(maxLines: 3, maxChars: 1 << 30);
      ring.addAll([line('a'), line('b'), line('c'), line('d')]);
      expect(ring.toList().map((l) => l.text), ['b', 'c', 'd']);
      expect(ring.dropped, 1);
    });

    test('drops by character budget too', () {
      final ring = BoundedLogRing(maxLines: 1 << 30, maxChars: 10);
      ring.addAll([line('12345'), line('67890'), line('ab')]);
      expect(ring.toList().map((l) => l.text), ['67890', 'ab']);
      expect(ring.dropped, 1);
    });

    test('reports the cumulative dropped count', () {
      final ring = BoundedLogRing(maxLines: 2, maxChars: 1 << 30);
      for (var i = 0; i < 7; i++) {
        ring.add(line('l$i'));
      }
      expect(ring.dropped, 5);
      expect(ring.droppedLabel, 'dropped 5 lines');
    });
  });
}
