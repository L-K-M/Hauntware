import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/fleet/synced_fleet.dart';
import 'package:seance_core/seance_core.dart' show AuthMethod, ServerConfig;
import 'package:test/test.dart';

ServerConfig _server(
  String id, {
  String? jumpHostId,
  AuthMethod auth = AuthMethod.agent,
  String? identityFilePath,
  String username = 'deploy',
}) => ServerConfig(
  id: id,
  label: 'label-$id',
  host: '$id.example.com',
  port: 2222,
  username: username,
  authMethod: auth,
  identityFilePath: identityFilePath,
  jumpHostId: jumpHostId,
  group: 'prod',
  createdAt: 1,
  updatedAt: 1,
);

void main() {
  test('a synced server keeps its endpoint, group and sign-in', () {
    final [entry] = syncedFleetEntries([_server('a')]);

    expect(entry.serverId, 'a');
    expect(entry.label, 'label-a');
    expect(
      (entry.host, entry.port, entry.user),
      ('a.example.com', 2222, 'deploy'),
    );
    expect(entry.group, 'prod');
    expect(entry.origin, FleetEntryOrigin.synced);
    expect(entry.jumpRoute, isNull);
    expect(entry.authKind, FleetAuthKind.agent);
    expect(entry.searchText, contains('label-a'));
    expect(entry.locatorConflict, isNull);
  });

  test('sign-in kinds follow the server config', () {
    final entries = syncedFleetEntries([
      _server('p', auth: AuthMethod.password, username: ''),
      _server('k', auth: AuthMethod.privateKey),
      _server('f', auth: AuthMethod.privateKey, identityFilePath: '~/.ssh/id'),
    ]);

    expect(
      [for (final e in entries) e.authKind],
      [
        FleetAuthKind.password,
        FleetAuthKind.storedKey,
        FleetAuthKind.identityFile,
      ],
    );
    expect(entries.first.user, isNull, reason: 'no user name, no user');
  });

  test('a jump route lists its hops first hop first and never reads as '
      'direct when broken', () {
    final entries = syncedFleetEntries([
      _server('edge'),
      _server('mid', jumpHostId: 'edge'),
      _server('web', jumpHostId: 'mid'),
      _server('lost', jumpHostId: 'gone'),
      _server('x', jumpHostId: 'y'),
      _server('y', jumpHostId: 'x'),
      _server('self', jumpHostId: 'self'),
    ]);

    expect(
      {for (final e in entries) e.serverId: e.jumpRoute},
      {
        'edge': null,
        'mid': ['label-edge'],
        'web': ['label-edge', 'label-mid'],
        'lost': ['gone'],
        'x': ['label-y'],
        'y': ['label-x'],
        'self': ['label-self'],
      },
    );
  });
}
