import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

void main() {
  group('StackScanCommands (STK-08)', () {
    test('one find over every folder, two levels deep, compose names only', () {
      expect(StackScanCommands.find(['/opt/stacks', '/srv/apps/']), [
        'find',
        '/opt/stacks/',
        '/srv/apps/',
        '-maxdepth',
        '2',
        '-type',
        'f',
        '(',
        '-name',
        'compose*.yml',
        '-o',
        '-name',
        'compose*.yaml',
        '-o',
        '-name',
        'docker-compose*.yml',
        '-o',
        '-name',
        'docker-compose*.yaml',
        ')',
        '-print0',
      ]);
    });

    test('refuses no folders, relative or unnormalized paths and control '
        'characters', () {
      for (final folders in [
        <String>[],
        ['opt/stacks'],
        ['/opt/../etc'],
        ['/opt/./stacks'],
        ['/opt/stacks\nx'],
        ['/opt/stacks', '-delete'],
      ]) {
        expect(
          () => StackScanCommands.find(folders),
          throwsA(isA<HostCommandError>()),
          reason: '$folders',
        );
      }
    });

    test('parses NUL-separated paths, sorted, inside the folders only', () {
      const out =
          '/opt/stacks/web/compose.yaml\u0000'
          '/opt/stacks/db/docker-compose.override.yml\u0000'
          '/opt/stacks/compose.yml\u0000'
          '/opt/stacks/web/compose.yaml\u0000'
          '/etc/compose.yaml\u0000'
          '/opt/stacks/web/notes.yaml\u0000'
          '/opt/stacks/odd\nname/compose.yaml\u0000';
      expect(StackScanCommands.parse(out, ['/opt/stacks']), [
        '/opt/stacks/compose.yml',
        '/opt/stacks/db/docker-compose.override.yml',
        '/opt/stacks/web/compose.yaml',
      ]);
    });

    test('a folder is matched as a whole path segment', () {
      expect(
        StackScanCommands.parse('/opt/stacks2/compose.yaml\u0000', [
          '/opt/stacks',
        ]),
        isEmpty,
      );
    });
  });
}
