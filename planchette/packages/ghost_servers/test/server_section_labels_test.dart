import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_servers/ghost_servers.dart';
import 'package:seance_protocol/seance_protocol.dart';

ServerConfig _server(String id, {String? group}) => ServerConfig(
  id: id,
  label: id,
  host: '$id.example.com',
  username: 'ops',
  authMethod: AuthMethod.password,
  group: group,
  createdAt: 0,
  updatedAt: 0,
);

/// The section headers' (title, key) pairs, in order.
List<(String, String)> _sectionHeaders(List<ServerListRow> rows) => [
  for (final row in rows)
    if (row case ServerSectionRow(:final title, :final key)) (title, key),
];

void main() {
  final sections = groupServers(
    [_server('a'), _server('b', group: 'Production')],
    pinnedIds: {'a'},
  );

  test('the default labels are Séance\'s section titles', () {
    const labels = GhostServerSectionLabels();
    expect(labels.pinned, kPinnedLabel);
    expect(labels.servers, kServersLabel);
    expect(
      _sectionHeaders(
        serverListRows(sections: sections, collapsedKeys: const {}),
      ),
      [(kPinnedLabel, kPinnedKey), (kServersLabel, kServersKey)],
    );
  });

  test('a host\'s labels title the headers; the keys stay put', () {
    final rows = serverListRows(
      sections: sections,
      collapsedKeys: const {kPinnedKey},
      labels: const GhostServerSectionLabels(
        pinned: 'Angeheftet',
        servers: 'Rechner',
      ),
    );
    // The persisted collapse keys never follow the copy: a folded section
    // stays folded when the app's language changes.
    expect(_sectionHeaders(rows), [
      ('Angeheftet', kPinnedKey),
      ('Rechner', kServersKey),
    ]);
    expect(rows.whereType<ServerGroupHeaderRow>().map((row) => row.name), [
      'Production',
    ]);
  });
}
