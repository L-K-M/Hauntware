import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/seance_links.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

void main() {
  test('uses only the synchronized server id when one exists', () {
    final bookmark = _bookmark(
      const BookmarkServerRef(
        serverConfigId: '123e4567-e89b-42d3-a456-426614174000',
      ),
    );

    expect(
      seanceConnectUriForBookmark(bookmark).toString(),
      'seance://connect?serverId=123e4567-e89b-42d3-a456-426614174000',
    );
  });

  test('percent-encodes every embedded endpoint value', () {
    final bookmark = _bookmark(
      const BookmarkServerRef(
        identity: EmbeddedHostIdentity(
          host: 'fe80::1%en0',
          port: 2200,
          username: 'ops & build',
          authMethod: AuthMethod.password,
          secretRef: 'vault-password',
          identityFilePath: '~/.ssh/private-key',
        ),
      ),
    );

    final uri = seanceConnectUriForBookmark(bookmark);
    expect(uri.scheme, seanceDeepLinkScheme);
    expect(uri.host, seanceConnectRoute);
    expect(uri.queryParameters, {
      'host': 'fe80::1%en0',
      'port': '2200',
      'username': 'ops & build',
    });
    expect(uri.toString(), contains('host=fe80%3A%3A1%25en0'));
    expect(uri.toString(), contains('username=ops+%26+build'));
  });

  test('hides the command when no handler is available', () async {
    var launches = 0;
    final launcher = await SeanceLinkLauncher.probe(
      probe: (_) async => false,
      launch: (_) async {
        launches++;
        return true;
      },
      onError: (_, _) {},
    );

    expect(launcher.available, isFalse);
    await launcher.openServer(_server());
    expect(launches, 0);
  });

  test('fails the availability probe closed', () async {
    final errors = <Object>[];
    final launcher = await SeanceLinkLauncher.probe(
      probe: (_) async => throw StateError('probe failed'),
      launch: (_) async => true,
      onError: (error, _) => errors.add(error),
    );

    expect(launcher.available, isFalse);
    expect(errors, hasLength(1));
  });

  test('never retries a refused server-id link with host data', () async {
    final attempts = <Uri>[];
    final errors = <Object>[];
    final launcher = await SeanceLinkLauncher.probe(
      probe: (_) async => true,
      launch: (uri) async {
        attempts.add(uri);
        return false;
      },
      onError: (error, _) => errors.add(error),
    );

    await launcher.openServer(_server());

    expect(attempts, hasLength(1));
    expect(attempts.single.queryParameters, {'serverId': _serverId});
    expect(errors, hasLength(1));
  });
}

const _serverId = '123e4567-e89b-42d3-a456-426614174000';

ServerConfig _server() => const ServerConfig(
  id: _serverId,
  label: 'Example',
  host: 'files.example',
  port: 22,
  username: 'ops',
  authMethod: AuthMethod.privateKey,
  createdAt: 0,
  updatedAt: 0,
);

Bookmark _bookmark(BookmarkServerRef server) => Bookmark(
  id: 'favorite-1',
  kind: BookmarkKind.remotePath,
  label: 'Example',
  server: server,
  sortKey: 'a',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);
