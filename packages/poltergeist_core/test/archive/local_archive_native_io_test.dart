import 'package:poltergeist_core/src/archive/local_archive_service.dart'
    as archive_internals;
import 'package:test/test.dart';

void main() {
  test('native reads continue after short chunks', () {
    final calls = <(int, int)>[];
    final chunks = <int>[2, 1, 2].iterator;

    final total = archive_internals.readNativeFileFully(5, (offset, remaining) {
      calls.add((offset, remaining));
      expect(chunks.moveNext(), isTrue);
      return chunks.current;
    });

    expect(total, 5);
    expect(calls, [(0, 5), (2, 3), (3, 2)]);
  });

  test('native reads stop only when the source reaches EOF', () {
    final calls = <(int, int)>[];
    final chunks = <int>[2, 0].iterator;

    final total = archive_internals.readNativeFileFully(5, (offset, remaining) {
      calls.add((offset, remaining));
      expect(chunks.moveNext(), isTrue);
      return chunks.current;
    });

    expect(total, 2);
    expect(calls, [(0, 5), (2, 3)]);
  });
}
