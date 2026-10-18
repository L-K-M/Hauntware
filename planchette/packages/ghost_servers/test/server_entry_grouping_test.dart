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

/// A host's own row type, as Klabautermann's fleet rows are: no record,
/// only what it shows, read through an adapter.
final class _HostRow {
  const _HostRow(this.key, this.folder);

  final String key;
  final String? folder;
}

GhostServerEntry _hostEntry(_HostRow row) =>
    GhostServerEntry(id: row.key, group: row.folder);

/// The sections as ids, so lists of different row types compare.
List<Object?> _shape<T>(
  GhostServerSections<T> sections,
  String Function(T) id,
) => [
  [for (final server in sections.pinned) id(server)],
  [for (final server in sections.ungrouped) id(server)],
  [
    for (final group in sections.groups)
      [
        group.name,
        group.key,
        [for (final server in group.servers) id(server)],
      ],
  ],
  sections.unpinnedCount,
];

/// The rendered rows as short strings, as server_grouping_test.dart has
/// them, with ids for server rows.
List<String> _rendered<T>(
  List<GhostServerListRow<T>> rows,
  String Function(T) id,
) => [
  for (final row in rows)
    switch (row) {
      GhostServerSectionRow(:final title, :final count, :final collapsed) =>
        '#$title:$count${collapsed ? '+' : ''}',
      GhostServerGroupHeaderRow(:final name, :final count, :final collapsed) =>
        '>$name:$count${collapsed ? '+' : ''}',
      GhostServerRow(:final server, :final depth) =>
        '${depth == 0 ? '-' : '--'}${id(server)}',
    },
];

void main() {
  // Every rule the record path has: case-folded groups keeping the first
  // spelling, blank and padded groups, a pinned server leaving its group,
  // and a pin naming no server.
  final records = [
    _server('loose'),
    _server('web', group: 'Production'),
    _server('runner', group: 'CI'),
    _server('blank', group: '   '),
    _server('db', group: ' production '),
    _server('cache', group: 'PRODUCTION'),
    _server('edge'),
  ];
  final entries = [
    for (final server in records)
      GhostServerEntry(id: server.id, group: server.group),
  ];
  final hostRows = [
    for (final server in records) _HostRow(server.id, server.group),
  ];
  const pinnedIds = {'cache', 'edge', 'gone'};

  final fromRecords = groupServers(records, pinnedIds: pinnedIds);
  final fromEntries = groupServerEntries(
    entries,
    (entry) => entry,
    pinnedIds: pinnedIds,
  );
  final fromHostRows = groupServerEntries(
    hostRows,
    _hostEntry,
    pinnedIds: pinnedIds,
  );

  String recordId(ServerConfig server) => server.id;
  String entryId(GhostServerEntry entry) => entry.id;
  String hostId(_HostRow row) => row.key;

  test('neutral entries section as their records do', () {
    final expected = _shape(fromRecords, recordId);
    expect(expected, [
      ['cache', 'edge'],
      ['loose', 'blank'],
      [
        [
          'CI',
          'ci',
          ['runner'],
        ],
        [
          'Production',
          'production',
          ['web', 'db'],
        ],
      ],
      5,
    ]);
    expect(_shape(fromEntries, entryId), expected);
    expect(_shape(fromHostRows, hostId), expected);
  });

  test('the sections keep the host\'s own rows', () {
    expect(fromHostRows.pinned, [hostRows[5], hostRows[6]]);
    expect(fromHostRows.groups.last.servers, [hostRows[1], hostRows[4]]);
  });

  test('neutral rows render as the records\' rows, folded or not', () {
    const labels = GhostServerSectionLabels(
      pinned: 'Gepinnt',
      servers: 'Hosts',
    );
    for (final collapsed in <Set<String>>[
      {},
      {kPinnedKey},
      {'production'},
      {kServersKey},
    ]) {
      final expected = _rendered(
        serverListRows(
          sections: fromRecords,
          collapsedKeys: collapsed,
          labels: labels,
        ),
        recordId,
      );
      expect(
        _rendered(
          serverListRows(
            sections: fromEntries,
            collapsedKeys: collapsed,
            labels: labels,
          ),
          entryId,
        ),
        expected,
        reason: 'collapsed $collapsed',
      );
      expect(
        _rendered(
          serverListRows(
            sections: fromHostRows,
            collapsedKeys: collapsed,
            labels: labels,
          ),
          hostId,
        ),
        expected,
        reason: 'collapsed $collapsed',
      );
    }
  });

  test('a kept section and the live rule agree across inputs', () {
    final kept = sectionsHoldingLive(fromRecords, (s) => s.id == 'web');
    expect(kept, {kServersKey});
    expect(sectionsHoldingLive(fromEntries, (e) => e.id == 'web'), kept);
    expect(sectionsHoldingLive(fromHostRows, (r) => r.key == 'web'), kept);

    final empty = groupServerEntries(<_HostRow>[], _hostEntry);
    expect(
      _rendered(
        serverListRows(
          sections: empty,
          collapsedKeys: const {},
          keptSections: kept,
        ),
        hostId,
      ),
      ['#Servers:0'],
    );
  });

  test('an entry compares by its id and group', () {
    expect(
      const GhostServerEntry(id: 'a', group: 'G'),
      const GhostServerEntry(id: 'a', group: 'G'),
    );
    expect(
      const GhostServerEntry(id: 'a', group: 'G'),
      isNot(const GhostServerEntry(id: 'a')),
    );
  });
}
