// The wire parsers' read buffer (DKR-10): bytes in at the end, out at
// the front, whatever the split, with its store moved, grown and let go.
import 'dart:math';
import 'dart:typed_data';

import 'package:klabautermann_docker/src/byte_read_buffer.dart';
import 'package:test/test.dart';

void main() {
  test('takes, skips and indexes the unread bytes', () {
    final buffer = ByteReadBuffer()
      ..add([1, 2, 3])
      ..add(Uint8List.fromList([4, 5]));
    expect(buffer.length, 5);
    expect(buffer[0], 1);
    expect(buffer.take(2), [1, 2]);
    expect(buffer[0], 3);
    expect(buffer.indexOf(5), 2);
    expect(buffer.indexOf(1), -1, reason: 'consumed');
    buffer.skip(1);
    expect(buffer.view(0, 2), [4, 5]);
    expect(buffer.takeAll(), [4, 5]);
    expect(buffer.isEmpty, isTrue);
    expect(buffer.indexOf(4), -1, reason: 'bytes past the end are not read');
  });

  test('a taken list is a copy, apart from the store', () {
    final buffer = ByteReadBuffer()..add([1, 2, 3, 4]);
    final taken = buffer.take(2);
    buffer
      ..skip(2)
      ..add([9, 9, 9, 9]);
    expect(taken, [1, 2]);
  });

  test('finds a CR LF pair from an offset, and not half of one', () {
    final buffer = ByteReadBuffer()..add([0x61, 0x0D]);
    expect(buffer.indexOfCrlf(), -1);
    buffer.add([0x0A, 0x62, 0x0D, 0x0A]);
    expect(buffer.indexOfCrlf(), 1);
    expect(buffer.indexOfCrlf(1), 1);
    expect(buffer.indexOfCrlf(2), 4);
    buffer.skip(3);
    expect(buffer.indexOfCrlf(), 1);
    buffer.skip(1);
    expect(buffer.indexOfCrlf(), 0);
    buffer.skip(1);
    expect(buffer.indexOfCrlf(), -1, reason: 'the CR was consumed');
  });

  test('out of range reads and skips are errors', () {
    final buffer = ByteReadBuffer()..add([1, 2]);
    expect(() => buffer[2], throwsRangeError);
    expect(() => buffer.take(3), throwsRangeError);
    expect(() => buffer.skip(3), throwsRangeError);
    expect(() => buffer.view(1, 3), throwsRangeError);
  });

  test('keeps every byte in order across random adds and takes', () {
    final random = Random(7);
    final buffer = ByteReadBuffer();
    var written = 0;
    var read = 0;
    for (var round = 0; round < 5000; round++) {
      final adding = random.nextInt(round % 50 == 0 ? 300000 : 700);
      buffer.add([for (var i = 0; i < adding; i++) (written + i) & 0xFF]);
      written += adding;
      final taking = random.nextInt(buffer.length + 1);
      final taken = random.nextBool() || round % 97 == 0
          ? buffer.takeAll()
          : buffer.take(taking);
      for (var i = 0; i < taken.length; i++) {
        if (taken[i] != (read + i) & 0xFF) {
          fail('byte ${read + i} of round $round is ${taken[i]}');
        }
      }
      read += taken.length;
      expect(buffer.length, written - read);
    }
  });
}
