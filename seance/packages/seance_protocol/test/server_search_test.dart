import 'package:seance_protocol/seance_protocol.dart';
import 'package:test/test.dart';

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

  test('serverSearchHaystack spells label, login, port and group', () {
    expect(
      serverSearchHaystack(_server('Web', group: 'Prod')),
      'web ops@web.example.com:22 prod',
    );
    expect(
      serverSearchHaystack(_server('db')),
      'db ops@db.example.com:22 ',
    );
  });
}
