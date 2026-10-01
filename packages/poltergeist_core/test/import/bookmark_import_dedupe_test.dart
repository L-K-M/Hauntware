import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_core/src/import/_bookmark_import_dedupe.dart';
import 'package:test/test.dart';

Bookmark _bookmark(String id, String label) {
  final now = DateTime.utc(2026, 10, 1);
  return Bookmark(
    id: id,
    kind: BookmarkKind.remotePath,
    label: label,
    server: const BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: 'files.example.com',
        port: 22,
        username: 'alice',
        authMethod: AuthMethod.password,
      ),
    ),
    remotePath: '/srv/archive',
    sortKey: id,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  test('endpoint fields cannot collide through delimiter data', () {
    // These triples produced the same key when fields were NUL-delimited.
    final left = bookmarkImportEndpointKey('a', 22, 'x\u000023\u0000y');
    final right = bookmarkImportEndpointKey('a\u000022\u0000x', 23, 'y');

    expect(left, isNot(right));
  });

  test('third-party destinations include the case-sensitive remote path', () {
    final left = bookmarkImportDestinationKey('host', 22, 'alice', '/one');
    final right = bookmarkImportDestinationKey('host', 22, 'alice', '/two');

    expect(left, isNot(right));
  });

  test('duplicate indexes preserve the first matching bookmark label', () {
    final bookmarks = [_bookmark('a', 'First'), _bookmark('b', 'Second')];
    final endpoint = bookmarkImportEndpointKey(
      'files.example.com',
      22,
      'alice',
    );
    final destination = bookmarkImportDestinationKey(
      'files.example.com',
      22,
      'alice',
      '/srv/archive',
    );

    expect([
      existingBookmarkImportEndpoints(bookmarks)[endpoint],
      existingBookmarkImportDestinations(bookmarks)[destination],
    ], everyElement('First'));
  });
}
