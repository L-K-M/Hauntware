import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/catalog/server_drafts.dart';
import 'package:seance_core/seance_core.dart'
    show AuthMethod, ServerColor, ServerConfig, ServerIcon;
import 'package:test/test.dart';

final _stored = ServerConfig(
  id: 'srv-a',
  label: 'alpha',
  host: 'alpha.example.com',
  port: 2222,
  username: 'deploy',
  authMethod: AuthMethod.privateKey,
  secretRef: 'secret-a',
  identityFilePath: '/home/me/.ssh/id_ed25519',
  jumpHostId: 'srv-j',
  syncSecret: true,
  group: 'prod',
  color: ServerColor.blue,
  icon: ServerIcon.values.first,
  loginScript: 'cd /srv',
  startDirectory: '/srv/app',
  createdAt: 10,
  updatedAt: 20,
);

void main() {
  test('a stored config survives its draft, and the draft names what the '
      'editor shows', () {
    final draft = serverDraftOf(_stored);
    expect(draft.auth, ServerDraftAuth.privateKey);
    expect(draft.colorName, 'blue');

    final saved = serverConfigOfDraft(
      draft,
      existing: _stored,
      secretRef: _stored.secretRef,
      now: DateTime.fromMillisecondsSinceEpoch(5),
    );

    expect(
      saved.toJson()..remove('updatedAt'),
      {..._stored.toJson()}..remove('updatedAt'),
    );
    // The stamp outranks the stored one even from a clock behind it.
    expect(saved.updatedAt, 21);
  });

  test('a new server takes its creation time from now, and an unknown '
      'colour or icon name reads as none', () {
    final saved = serverConfigOfDraft(
      const ServerDraft(
        id: 'srv-new',
        label: ' web ',
        host: 'web.example.com',
        port: 22,
        username: 'deploy',
        auth: ServerDraftAuth.agent,
        colorName: 'ultraviolet',
        iconName: 'no-such-icon',
      ),
      existing: null,
      secretRef: null,
      now: DateTime.fromMillisecondsSinceEpoch(1000),
    );

    expect(saved.label, 'web');
    expect(saved.createdAt, 1000);
    expect(saved.color, isNull);
    expect(saved.icon, isNull);
    expect(saved.jumpHostId, isNull);
  });

  test('a blank field or a port out of range is refused', () {
    ServerDraft draft({String host = 'h', int port = 22}) => ServerDraft(
      id: 'srv',
      label: 'l',
      host: host,
      port: port,
      username: 'u',
      auth: ServerDraftAuth.agent,
    );

    expect(serverDraftProblem(draft()), isNull);
    expect(serverDraftProblem(draft(host: '  ')), isNotNull);
    expect(serverDraftProblem(draft(port: 0)), isNotNull);
    expect(serverDraftProblem(draft(port: 65536)), isNotNull);
  });
}
