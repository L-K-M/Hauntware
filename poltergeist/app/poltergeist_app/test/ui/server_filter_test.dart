// Ported from Séance app/seance_app/test/server_filter_test.dart @ ded9228; see docs/PORTS.md.
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/ui/sidebar/sidebar_facts.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

ServerConfig _server({
  required String label,
  String host = 'example.com',
  String username = 'ops',
  int port = 22,
  String? group,
}) => ServerConfig(
  id: label,
  label: label,
  host: host,
  port: port,
  username: username,
  authMethod: AuthMethod.privateKey,
  group: group,
  createdAt: 0,
  updatedAt: 0,
);

/// The catalog's filter: Séance's term rule over the server haystack.
List<ServerConfig> _catalogFilter(
  List<ServerConfig> servers,
  String query,
) => [
  for (final server in servers)
    if (sidebarQueryMatches(serverSearchHaystack(server), query)) server,
];

void main() {
  final servers = [
    _server(label: 'prod web', host: 'prod-web-01.eu-west.example.com'),
    _server(label: 'prod db', host: 'prod-db-01.us-east.example.com'),
    _server(
      label: 'lab',
      host: '10.0.0.5',
      username: 'root',
      port: 2222,
      group: 'Home lab',
    ),
  ];

  group('sidebarQueryMatches over serverSearchHaystack', () {
    test('an empty or whitespace query matches everything', () {
      for (final query in ['', '   ', '\t']) {
        expect(_catalogFilter(servers, query).length, servers.length);
      }
    });

    test('matches the label, host, user, and port', () {
      expect(_catalogFilter(servers, 'lab').single.label, 'lab');
      expect(_catalogFilter(servers, 'us-east').single.label, 'prod db');
      expect(_catalogFilter(servers, 'root').single.label, 'lab');
      expect(_catalogFilter(servers, '2222').single.label, 'lab');
    });

    test('matches the group, so a section name narrows to that section', () {
      expect(_catalogFilter(servers, 'home lab').single.label, 'lab');
      // And composes with the other terms like anything else in the haystack.
      expect(_catalogFilter(servers, 'home root').single.label, 'lab');
    });

    test('a server with no group is unaffected by group matching', () {
      // "home" belongs to one server's group only; the ungrouped two must not
      // pick it up from an empty group reading as a wildcard.
      expect(_catalogFilter(servers, 'home'), hasLength(1));
    });

    test('is case-insensitive', () {
      expect(_catalogFilter(servers, 'PROD DB').single.label, 'prod db');
    });

    test('every term must match, in any order', () {
      expect(_catalogFilter(servers, 'web eu').single.label, 'prod web');
      expect(_catalogFilter(servers, 'eu web').single.label, 'prod web');
      // "prod" matches two hosts; adding a term that only one carries narrows.
      expect(_catalogFilter(servers, 'prod').length, 2);
      expect(_catalogFilter(servers, 'prod us-east').single.label, 'prod db');
      // A term no server carries excludes everything.
      expect(_catalogFilter(servers, 'prod nonexistent'), isEmpty);
    });
  });
}
