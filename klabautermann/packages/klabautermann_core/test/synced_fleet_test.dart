import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/fleet/synced_fleet.dart';
import 'package:seance_core/catalog.dart' show EndpointPin;
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
    final [entry] = SyncedFleet([_server('a')]).entries;

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
    expect(entry.endpoint, EndpointConfirmation.unconfirmed);
  });

  test('sign-in kinds follow the server config', () {
    final entries = SyncedFleet([
      _server('p', auth: AuthMethod.password, username: ''),
      _server('k', auth: AuthMethod.privateKey),
      _server('f', auth: AuthMethod.privateKey, identityFilePath: '~/.ssh/id'),
    ]).entries;

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
    final entries = SyncedFleet([
      _server('edge'),
      _server('mid', jumpHostId: 'edge'),
      _server('web', jumpHostId: 'mid'),
      _server('lost', jumpHostId: 'gone'),
      _server('x', jumpHostId: 'y'),
      _server('y', jumpHostId: 'x'),
      _server('self', jumpHostId: 'self'),
    ]).entries;

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

  // 03 §4.7, SAF-09: a synced server is dialed only while its own pin and
  // each hop's match; a change to any element asks again.
  group('endpoint confirmation', () {
    final at = DateTime.utc(2026, 10, 17);
    final edge = _server('edge');
    final web = _server('web', jumpHostId: 'edge');

    Map<String, EndpointPin> pinsOf(List<ServerConfig> servers) => {
      for (final pin in SyncedFleet(
        servers,
      ).pinsFor([for (final server in servers) server.id], at))
        pin.serverId: pin,
    };

    Map<String, EndpointConfirmation?> states(SyncedFleet fleet) => {
      for (final entry in fleet.entries) entry.serverId: entry.endpoint,
    };

    test('an unconfirmed server has no config and is rejected for it', () {
      final fleet = SyncedFleet([edge, web]);

      expect(fleet.confirmedIds, isEmpty);
      expect(fleet.serverConfig('web'), isNull);
      expect(
        fleet.missingConfigReason('web'),
        ConnectRejectedReason.endpointNotConfirmed,
      );
      expect(fleet.missingConfigReason('ssh-config:web'), isNull);
    });

    test('a confirmed server dials with its synced config', () {
      final fleet = SyncedFleet([edge, web], pins: pinsOf([edge, web]));

      expect(states(fleet), {
        'edge': EndpointConfirmation.confirmed,
        'web': EndpointConfirmation.confirmed,
      });
      expect(fleet.serverConfig('web'), same(web));
      expect(fleet.missingConfigReason('web'), isNull);
    });

    test('a change to the host, port, user or jump route asks again', () {
      final pins = pinsOf([edge, web, _server('other')]);
      for (final changed in [
        web.copyWith(host: 'moved.example.com'),
        web.copyWith(port: 22),
        web.copyWith(username: 'root'),
        web.copyWith(jumpHostId: 'other'),
        web.copyWith(clearJumpHostId: true),
      ]) {
        final fleet = SyncedFleet([
          edge,
          changed,
          _server('other'),
        ], pins: pins);
        expect(fleet.entries[1].endpoint, EndpointConfirmation.changed);
        expect(fleet.serverConfig('web'), isNull);
        expect(fleet.confirmedIds, {'edge', 'other'});
      }
    });

    test('a changed jump host asks again for every server behind it', () {
      final fleet = SyncedFleet([
        edge.copyWith(host: 'moved.example.com'),
        web,
      ], pins: pinsOf([edge, web]));

      expect(states(fleet), {
        'edge': EndpointConfirmation.changed,
        'web': EndpointConfirmation.changed,
      });
      expect(fleet.serverConfig('edge'), isNull);
    });

    test('confirming a server pins its never-confirmed hops, but never '
        're-pins a hop that changed (D64)', () {
      final fresh = SyncedFleet([edge, web]).pinsFor(['web', 'gone'], at);
      expect([for (final pin in fresh) pin.serverId], ['web', 'edge']);
      final [webPin, edgePin] = fresh;
      expect(
        (webPin.host, webPin.port, webPin.username),
        ('web.example.com', 2222, 'deploy'),
      );
      expect(webPin.jumpRouteIds, ['edge']);
      expect(edgePin.jumpRouteIds, isEmpty);
      expect(webPin.confirmedAt, at);

      final moved = SyncedFleet([
        edge.copyWith(host: 'moved.example.com'),
        web,
      ], pins: pinsOf([edge, web]));
      expect(
        [
          for (final pin in moved.pinsFor(['web'], at)) pin.serverId,
        ],
        ['web'],
      );
    });
  });
}
