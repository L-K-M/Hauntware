import 'dart:async';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

import 'harness.dart';

/// Collects every value and error the stream emits until it ends. The
/// JSON stream scanner reports malformed input through `addError`, which
/// `Stream.asFuture` would rethrow; this keeps both in one list.
Future<List<Object?>> collectEvents(Stream<Object?> stream) async {
  final events = <Object?>[];
  final done = Completer<void>();
  stream.listen(events.add, onError: events.add, onDone: done.complete);
  await done.future;
  return events;
}

/// Feeds [bytes] to [transform] in every two-chunk split, then one byte
/// at a time, and checks each output against [expected].
Future<void> forEveryTransformSplit<T>(
  List<int> bytes,
  Stream<T> Function(Stream<List<int>>) transform,
  List<T> expected,
) async {
  for (var i = 0; i <= bytes.length; i++) {
    final out = await transform(
      Stream.fromIterable([bytes.sublist(0, i), bytes.sublist(i)]),
    ).toList();
    expect(out, expected, reason: 'split at byte $i');
  }
  final out = await transform(
    Stream.fromIterable([
      for (var i = 0; i < bytes.length; i++) bytes.sublist(i, i + 1),
    ]),
  ).toList();
  expect(out, expected, reason: 'one byte at a time');
}

void main() {
  group('byteStreamToLines', () {
    test('NDJSON lines at every split', () async {
      final bytes = utf8Of(
        '{"status":"pulling"}\n{"status":"done","id":42}\n{"ok":true}\n',
      );
      await forEveryTransformSplit<String>(bytes, byteStreamToLines, [
        '{"status":"pulling"}',
        '{"status":"done","id":42}',
        '{"ok":true}',
      ]);
    });

    test('json-seq RS separators are stripped at every split', () async {
      final bytes = <int>[
        0x1E,
        ...utf8Of('{"a":1}\n'),
        0x1E,
        ...utf8Of('{"b":2}\n'),
      ];
      await forEveryTransformSplit<String>(bytes, byteStreamToLines, [
        '{"a":1}',
        '{"b":2}',
      ]);
    });

    test('CRLF endings and empty lines are normalized away', () async {
      final bytes = utf8Of('{"a":1}\r\n\r\n{"b":2}\r\n');
      expect(await byteStreamToLines(Stream.value(bytes)).toList(), [
        '{"a":1}',
        '{"b":2}',
      ]);
    });

    test('a final line without a newline is still delivered', () async {
      final bytes = utf8Of('{"a":1}\n{"tail":true}');
      expect(await byteStreamToLines(Stream.value(bytes)).toList(), [
        '{"a":1}',
        '{"tail":true}',
      ]);
    });

    test('multibyte UTF-8 survives a split inside the character', () async {
      final bytes = utf8Of('{"name":"héllo wörld ✓"}\n');
      await forEveryTransformSplit<String>(bytes, byteStreamToLines, [
        '{"name":"héllo wörld ✓"}',
      ]);
    });

    test('malformed UTF-8 is replaced, not thrown', () async {
      final bytes = <int>[...utf8Of('{"x":"'), 0xFF, 0xFE, ...utf8Of('"}\n')];
      final lines = await byteStreamToLines(Stream.value(bytes)).toList();
      expect(lines, hasLength(1));
      expect(lines.single, contains('�'));
    });
  });

  group('byteStreamToJsonValues', () {
    test('concatenated objects without separators at every split', () async {
      final bytes = utf8Of('{"id":"a","n":1}{"id":"b","n":2}{"id":"c"}');
      await forEveryTransformSplit<Object?>(bytes, byteStreamToJsonValues, [
        {'id': 'a', 'n': 1},
        {'id': 'b', 'n': 2},
        {'id': 'c'},
      ]);
    });

    test('newline-separated pull progress shape at every split', () async {
      final bytes = utf8Of(
        '{"status":"Pulling fs layer","progressDetail":{}}\n'
        '{"status":"Download complete","id":"abc","progressDetail":{}}\n',
      );
      await forEveryTransformSplit<Object?>(bytes, byteStreamToJsonValues, [
        {'status': 'Pulling fs layer', 'progressDetail': <String, Object?>{}},
        {
          'status': 'Download complete',
          'id': 'abc',
          'progressDetail': <String, Object?>{},
        },
      ]);
    });

    test('mixed JSON kinds: arrays, strings, scalars', () async {
      final bytes = utf8Of('[1,2,3]"str"42 true null');
      expect(await byteStreamToJsonValues(Stream.value(bytes)).toList(), [
        [1, 2, 3],
        'str',
        42,
        true,
        null,
      ]);
    });

    test('a brace inside a string does not close the object', () async {
      final bytes = utf8Of('{"a":"}x\\""} {"b":1}');
      expect(await byteStreamToJsonValues(Stream.value(bytes)).toList(), [
        {'a': '}x"'},
        {'b': 1},
      ]);
    });

    test('json-seq RS between values is whitespace', () async {
      final bytes = <int>[
        0x1E,
        ...utf8Of('{"a":1}\n'),
        0x1E,
        ...utf8Of('{"b":2}\n'),
      ];
      expect(await byteStreamToJsonValues(Stream.value(bytes)).toList(), [
        {'a': 1},
        {'b': 2},
      ]);
    });

    test('malformed JSON surfaces a DockerProtocolException', () async {
      final bytes = utf8Of('{"ok":1} {not json}');
      final events = await collectEvents(
        byteStreamToJsonValues(Stream.value(bytes)),
      );
      expect(events, hasLength(2));
      expect(events.first, {'ok': 1});
      expect(events.last, isA<DockerProtocolException>());
    });

    test('a truncated final value at EOF is a protocol error', () async {
      final bytes = utf8Of('{"a":1} {"b":');
      final events = await collectEvents(
        byteStreamToJsonValues(Stream.value(bytes)),
      );
      expect(events.last, isA<DockerProtocolException>());
    });
  });
}
