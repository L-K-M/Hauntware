import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_servers/ghost_servers.dart';
import 'package:ghost_servers/server_config_draft.dart';
import 'package:seance_protocol/seance_protocol.dart';

final _stored = ServerConfig(
  id: 'srv-a',
  label: 'alpha',
  host: 'alpha.example.com',
  port: 2222,
  username: 'deploy',
  authMethod: AuthMethod.privateKey,
  secretRef: 'secret-a',
  identityFilePath: '~/.ssh/id_ed25519',
  jumpHostId: 'srv-j',
  syncSecret: true,
  group: 'prod',
  color: ServerColor.blue,
  customColor: '#3A7BD5',
  icon: ServerIcon.values.first,
  iconEmoji: '🚀',
  loginScript: 'cd /srv',
  startDirectory: '/srv/app',
  excludeFromSync: true,
  createdAt: 10,
  updatedAt: 20,
);

GhostServerDraft _draft({String? colorName, String? iconName}) =>
    GhostServerDraft(
      id: 'srv-new',
      label: 'web',
      host: 'web.example.com',
      port: 22,
      username: 'deploy',
      authMethod: GhostAuthMethod.agent,
      syncSecret: false,
      excludeFromSync: false,
      colorName: colorName,
      iconName: iconName,
    );

void main() {
  test('a stored config survives its draft, with the jump route and the '
      'creation time from the stored one', () {
    final saved = serverConfigOfGhostDraft(
      ghostServerDraftOf(_stored),
      existing: _stored,
      secretRef: _stored.secretRef,
      now: 30,
    );

    expect(
      saved.toJson()..remove('updatedAt'),
      _stored.toJson()..remove('updatedAt'),
    );
    expect(saved.updatedAt, 30);
  });

  test('a new server has no route, and its creation time is now', () {
    final saved = serverConfigOfGhostDraft(
      _draft(),
      existing: null,
      secretRef: null,
      now: 1000,
    );

    expect(saved.jumpHostId, isNull);
    expect(saved.createdAt, 1000);
    expect(saved.updatedAt, 1000);
  });

  test('a colour or icon name this build does not know reads as none', () {
    final saved = serverConfigOfGhostDraft(
      _draft(colorName: 'ultraviolet', iconName: 'no-such-icon'),
      existing: null,
      secretRef: null,
      now: 0,
    );

    expect(saved.color, isNull);
    expect(saved.icon, isNull);
  });

  test('every sign-in method maps both ways', () {
    for (final method in AuthMethod.values) {
      expect(authMethodOfGhost(ghostAuthMethodOf(method)), method);
    }
  });

  test('only excluding a server that may have synced asks first', () {
    final included = ghostServerDraftOf(
      ServerConfig.fromJson({..._stored.toJson(), 'excludeFromSync': false}),
    );
    final excluded = ghostServerDraftOf(_stored);

    for (final (existing, configured, asks) in [
      (included, true, true),
      (included, false, false),
      (excluded, true, false),
      (null, true, false),
    ]) {
      expect(
        ghostExcludingNeedsConfirmation(
          existing: existing,
          syncConfigured: configured,
        ),
        asks,
        reason: '${existing?.excludeFromSync}, $configured',
      );
    }
  });
}
