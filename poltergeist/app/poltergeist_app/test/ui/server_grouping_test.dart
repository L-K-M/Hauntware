// Partly ported from Séance app/seance_app/test/server_grouping_test.dart @ 8326f41f574fabce11986ea16137917626f67958: only the existingServerGroups cases are carried; see docs/PORTS.md.
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/ui/server_grouping.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

ServerConfig _server(String label, {String? group}) => ServerConfig(
  id: label,
  label: label,
  host: '$label.example.com',
  username: 'ops',
  authMethod: AuthMethod.password,
  group: group,
  createdAt: 0,
  updatedAt: 0,
);

void main() {
  group('existingServerGroups', () {
    test('lists each group once, sorted, in its first spelling', () {
      final groups = existingServerGroups([
        _server('a', group: 'Production'),
        _server('b', group: 'CI'),
        _server('c', group: 'production'),
        _server('d'),
      ]);
      expect(groups, ['CI', 'Production']);
    });

    test('is empty when nothing is grouped', () {
      expect(existingServerGroups([_server('a'), _server('b')]), isEmpty);
    });
  });
}
