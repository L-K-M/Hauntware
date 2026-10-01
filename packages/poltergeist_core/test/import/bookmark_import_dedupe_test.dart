import 'package:poltergeist_core/src/import/_bookmark_import_dedupe.dart';
import 'package:test/test.dart';

void main() {
  test('endpoint fields cannot collide through delimiter data', () {
    // These triples produced the same key when fields were NUL-delimited.
    final left = bookmarkImportEndpointKey('a', 22, 'x\u000023\u0000y');
    final right = bookmarkImportEndpointKey('a\u000022\u0000x', 23, 'y');

    expect(left, isNot(right));
  });

  test('third-party destinations include the case-sensitive remote path', () {
    final left = bookmarkImportDestinationKey('HOST', 22, 'alice', '/one');
    final right = bookmarkImportDestinationKey('host', 22, 'alice', '/two');

    expect(left, isNot(right));
  });
}
