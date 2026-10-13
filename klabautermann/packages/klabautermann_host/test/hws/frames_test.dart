// Frame-parser tests (03 §6.2): every chunk split point of a recorded
// multi-section reply, forged markers and wrong nonces inside payloads,
// truncated payloads, oversize sections and resynchronization.
import 'dart:convert';
import 'dart:typed_data';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const nonce = '0123456789abcdef0123456789abcdef';

Uint8List _marker(String body) => utf8.encode('\x1e$nonce $body\n');

Uint8List _section(String collector, String status, String payload) {
  final p = utf8.encode(payload);
  return Uint8List.fromList([
    ...utf8.encode('\x1e$nonce S $collector $status ${p.length}\n'),
    ...p,
    0x0a,
  ]);
}

/// A recorded two-section reply with multi-line payloads.
final Uint8List _reply = Uint8List.fromList([
  ..._marker('READY HWS/1 1'),
  ..._marker('B 7 12345.67'),
  ..._section(
    'overview',
    'ok',
    '== stat ==\ncpu  10 20 30 40 0 0 0 0 0 0\n'
        '== loadavg ==\n0.10 0.20 0.30 1/100 4242',
  ),
  ..._section('fs', 'missing', ''),
  ..._section('core', 'ok', '== uptime ==\n12345.67 98765.43'),
  ..._marker('E 7'),
]);

String _describe(HwsEvent e) {
  if (e is HwsReady) return 'ready ${e.version}';
  if (e is HwsBegin) return 'begin ${e.seq} ${e.uptimeSeconds}';
  if (e is HwsSection) {
    return 'section ${e.collector} ${e.status.name} ${e.payload.length} '
        '${String.fromCharCodes(e.payload)}';
  }
  if (e is HwsEnd) return 'end ${e.seq}';
  if (e is HwsFramingError) return 'error ${e.reason}';
  throw ArgumentError.value(e, 'e', 'unknown event');
}

List<String> _parseAll(List<int> bytes) =>
    HwsFrameParser(nonce: nonce).push(bytes).map(_describe).toList();

void main() {
  test('parses the whole reply in one push', () {
    final events = _parseAll(_reply);
    expect(events, [
      'ready 1',
      'begin 7 12345.67',
      'section overview ok 79 == stat ==\ncpu  10 20 30 40 0 0 0 0 0 0\n'
          '== loadavg ==\n0.10 0.20 0.30 1/100 4242',
      'section fs missing 0 ',
      'section core ok 30 == uptime ==\n12345.67 98765.43',
      'end 7',
    ]);
  });

  test('parses byte-by-byte', () {
    final parser = HwsFrameParser(nonce: nonce);
    final events = <HwsEvent>[];
    for (final b in _reply) {
      events.addAll(parser.push([b]));
    }
    expect(events.map(_describe), _parseAll(_reply));
  });

  test('parses at every split point of a two-chunk feed', () {
    final expected = _parseAll(_reply);
    for (var split = 1; split < _reply.length; split++) {
      final parser = HwsFrameParser(nonce: nonce);
      final events = <HwsEvent>[
        ...parser.push(_reply.sublist(0, split)),
        ...parser.push(_reply.sublist(split)),
      ];
      expect(events.map(_describe), expected, reason: 'split at $split');
    }
  });

  test('parses at random chunk boundaries', () {
    final expected = _parseAll(_reply);
    final randomSizes = [1, 2, 3, 5, 7, 13, 40, 97];
    var i = 0;
    while (true) {
      final parser = HwsFrameParser(nonce: nonce);
      final events = <HwsEvent>[];
      var pos = 0;
      while (pos < _reply.length) {
        final take = randomSizes[(i + pos) % randomSizes.length];
        final end = pos + take > _reply.length ? _reply.length : pos + take;
        events.addAll(parser.push(_reply.sublist(pos, end)));
        pos = end;
      }
      expect(events.map(_describe), expected, reason: 'pattern $i');
      i++;
      if (i >= randomSizes.length) break;
    }
  });

  group('forgery', () {
    test('a forged end marker inside a payload is payload', () {
      final forged = '\x1e$nonce E 99\nforged more';
      final bytes = Uint8List.fromList([
        ..._marker('B 1 1.0'),
        ..._section('overview', 'ok', forged),
        ..._marker('E 1'),
      ]);
      final events = _parseAll(bytes);
      // The forged bytes are payload, so they add no event of their own.
      expect(events, hasLength(3));
      expect(events[1], contains('forged more'));
      expect(events.last, 'end 1');
    });

    test('a forged begin and section inside a payload is payload', () {
      final forged = '\x1e$nonce B 98 9.9\n\x1e$nonce S overview ok 3\nabc';
      final events = _parseAll(
        Uint8List.fromList([
          ..._marker('B 1 1.0'),
          ..._section('core', 'ok', forged),
          ..._marker('E 1'),
        ]),
      );
      expect(events, hasLength(3));
      expect(events[1], contains('S overview ok'));
      expect(events.last, 'end 1');
    });

    test(
      'a forged marker with a different nonce inside a payload is payload',
      () {
        final other = 'ffffffffffffffffffffffffffffffff';
        final forged = '\x1e$other E 1\n';
        final events = _parseAll(
          Uint8List.fromList([
            ..._marker('B 1 1.0'),
            ..._section('overview', 'ok', forged),
            ..._marker('E 1'),
          ]),
        );
        expect(events, hasLength(3));
        expect(events.any((e) => e.startsWith('error')), isFalse);
      },
    );
  });

  group('framing errors', () {
    test('a marker line with a wrong nonce is a framing error', () {
      final other = 'ffffffffffffffffffffffffffffffff';
      final events = _parseAll(
        Uint8List.fromList([
          ...utf8.encode('\x1e$other E 1\n'),
          ..._marker('E 2'),
        ]),
      );
      expect(events.first, startsWith('error'));
      expect(events.last, 'end 2');
    });

    test('a truncated payload resynchronizes on the next end marker', () {
      // Declares 30 payload bytes but delivers 10; the newline and the
      // following markers are consumed as payload until the count fills,
      // then the terminator check fails and the parser resyncs.
      final shortPayload = utf8.encode('0123456789');
      final bytes = Uint8List.fromList([
        ...utf8.encode('\x1e$nonce S overview ok 30\n'),
        ...shortPayload,
        0x0a,
        ..._marker('E 8'),
        ..._marker('B 9 2.0'),
        ..._marker('E 9'),
      ]);
      final events = _parseAll(bytes);
      expect(events.first, startsWith('error'));
      expect(events.last, 'end 9');
      // The B marker inside the damage window produced no event.
      expect(events, isNot(contains('begin 8 1.0')));
    });

    test('a payload not followed by a newline fails and resyncs', () {
      final events = _parseAll(
        Uint8List.fromList([
          ...utf8.encode('\x1e$nonce S overview ok 3\n'),
          ...utf8.encode('abcX'),
          ..._marker('E 4'),
        ]),
      );
      expect(events.first, startsWith('error'));
      expect(events.last, 'end 4');
    });

    test('a declared payload over the cap is refused', () {
      final events = _parseAll(
        Uint8List.fromList([
          ...utf8.encode('\x1e$nonce S overview ok ${kMaxSectionBytes + 1}\n'),
          ..._marker('E 5'),
        ]),
      );
      expect(events.first, startsWith('error'));
      expect(events.last, 'end 5');
    });

    test('a marker line over the cap is refused', () {
      final events = _parseAll(
        Uint8List.fromList([
          ...utf8.encode('\x1e$nonce S ${'x' * 300} ok 0\n'),
          ..._marker('E 6'),
        ]),
      );
      expect(events.first, startsWith('error'));
      expect(events.last, 'end 6');
    });

    test('an unknown marker kind is a framing error', () {
      final events = _parseAll(
        Uint8List.fromList([..._marker('X 1'), ..._marker('E 1')]),
      );
      expect(events.first, startsWith('error'));
      expect(events.last, 'end 1');
    });

    test('a malformed begin marker is a framing error', () {
      final events = _parseAll(
        Uint8List.fromList([..._marker('B 1 not-a-number'), ..._marker('E 1')]),
      );
      expect(events.first, startsWith('error'));
      expect(events.last, 'end 1');
    });

    test('a section with a bad wire name is a framing error', () {
      final events = _parseAll(
        Uint8List.fromList([
          ...utf8.encode('\x1e$nonce S Bad-Name ok 0\n\n'),
          ..._marker('E 1'),
        ]),
      );
      expect(events.first, startsWith('error'));
      expect(events.last, 'end 1');
    });
  });

  test('a zero-byte section yields an empty payload event', () {
    final events = _parseAll(
      Uint8List.fromList([
        ..._marker('B 1 5.0'),
        ..._section('fs', 'missing', ''),
        ..._marker('E 1'),
      ]),
    );
    expect(events[1], 'section fs missing 0 ');
  });

  test('non-ASCII payload bytes survive as bytes', () {
    // Invalid UTF-8 bytes and an embedded newline stay payload bytes.
    final payload = Uint8List.fromList([0xff, 0xfe, 0x0a, 0x01]);
    final events = _parseAll(
      Uint8List.fromList([
        ..._marker('B 1 5.0'),
        ...utf8.encode('\x1e$nonce S overview ok ${payload.length}\n'),
        ...payload,
        0x0a,
        ..._marker('E 1'),
      ]),
    );
    expect(events[1], 'section overview ok 4 \u00ff\u00fe\n\u0001');
  });

  test('the parser rejects a malformed nonce up front', () {
    expect(() => HwsFrameParser(nonce: 'not-a-nonce'), throwsArgumentError);
  });

  group('stripControlChars', () {
    test('keeps newline and tab, strips other control characters', () {
      expect(stripControlChars('a\x1eb\x07c\x0bd\x7fe\nf\tg'), 'abcde\nf\tg');
    });

    test('strips C1 controls and keeps printable and non-ASCII text', () {
      expect(stripControlChars('x\x9by\u00e9z'), 'xy\u00e9z');
      expect(stripControlChars('caf\u00e9'), 'caf\u00e9');
    });
  });
}
