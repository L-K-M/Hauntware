// The edit pipeline's builders (03 §8.5, §8.8, D67): the argv each
// returns, the paths and tokens they refuse, and the readers of their
// output. edit_shell_test.dart runs the scripts under real shells.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

// Low entropy, so the secret scan does not read it as a key.
const _tempId = 'feedfacefeedface';
const _target = '/etc/nginx/nginx.conf';
const _temp = '/etc/nginx/.nginx.conf.klabautermann-tmp-$_tempId';
final _hash = 'a' * 64;

Matcher _refused(String reason) =>
    throwsA(isA<HostCommandError>().having((e) => e.reason, 'reason', reason));

void main() {
  test('the temp file sits beside its target under a dotted name', () {
    expect(EditCommands.tempPathFor(_target, _tempId), _temp);
    expect(
      EditCommands.tempPathFor('/crontab', _tempId),
      '/.crontab.klabautermann-tmp-$_tempId',
    );
    expect(
      () => EditCommands.tempPathFor(_target, 'ABC'),
      _refused('not a temp token'),
    );
  });

  test('each builder names its script and passes paths as words', () {
    expect(EditCommands.readFile(_target, cap: 10).sublist(3), [
      'klabautermann-read',
      _target,
      '10',
    ]);
    expect(EditCommands.writeTemp(_temp).last, _temp);
    expect(EditCommands.copyAttributes(_target, _temp).sublist(3), [
      'klabautermann-attributes',
      _target,
      _temp,
    ]);
    expect(EditCommands.replaceIfHash(_target, _temp, _hash).sublist(3), [
      'klabautermann-replace',
      _target,
      _temp,
      _hash,
    ]);
    expect(EditCommands.restorecon(_target), ['restorecon', '--', _target]);
    expect(EditCommands.removeTemp(_temp), ['rm', '-f', '--', _temp]);
    expect(EditCommands.backupFile(_target, kRootBackupsDir).sublist(3), [
      'klabautermann-backup',
      _target,
      kRootBackupsDir,
    ]);
    expect(EditCommands.sha256List([_target]), ['sha256sum', '--', _target]);
  });

  test('crontab writes take stdin, for the login user or a named one', () {
    expect(EditCommands.crontabWrite(), ['crontab', '-']);
    expect(EditCommands.crontabWrite(user: 'www-data'), [
      'crontab',
      '-u',
      'www-data',
      '-',
    ]);
    for (final bad in ['-r', 'a b', 'Root']) {
      expect(
        () => EditCommands.crontabWrite(user: bad),
        _refused('not a user name'),
        reason: bad,
      );
    }
  });

  test('crontab swaps carry the hash first, then crontab\'s own words', () {
    expect(EditCommands.crontabWriteIfHash(_hash).sublist(3), [
      'klabautermann-crontab',
      _hash,
    ]);
    expect(
      EditCommands.crontabWriteIfHash(_hash, user: 'www-data').sublist(4),
      [_hash, '-u', 'www-data'],
    );
    expect(
      () => EditCommands.crontabWriteIfHash('abc'),
      _refused('not a SHA-256'),
    );
    expect(
      EditCommands.crontabBackup(
        kRootBackupsDir,
        indexName: 'crontab:root',
      ).sublist(3),
      ['klabautermann-crontab-backup', kRootBackupsDir, 'crontab:root'],
    );
    expect(
      () => EditCommands.crontabBackup(kRootBackupsDir, indexName: 'x'),
      _refused('not a crontab index name'),
    );
  });

  test('paths must be absolute, normalized files without control '
      'characters (03 §8.8)', () {
    for (final bad in [
      'etc/passwd',
      '/etc/../shadow',
      '/etc/./x',
      '/etc/',
      '/',
      '/etc/a\nb',
      '/etc/a\tb',
    ]) {
      expect(
        () => EditCommands.readFile(bad),
        throwsA(isA<HostCommandError>()),
        reason: bad,
      );
    }
    expect(
      () => EditCommands.readFile(_target, cap: -1),
      _refused('negative cap'),
    );
  });

  test("a temp must be its target's own", () {
    for (final bad in [
      '/etc/nginx/nginx.conf.klabautermann-tmp-$_tempId',
      '/etc/nginx/.nginx.conf.klabautermann-tmp-xyz',
      '/etc/nginx/.klabautermann-tmp-$_tempId',
      '/etc/nginx/.other.klabautermann-tmp-$_tempId',
      '/tmp/.nginx.conf.klabautermann-tmp-$_tempId',
    ]) {
      expect(
        () => EditCommands.copyAttributes(_target, bad),
        throwsA(isA<HostCommandError>()),
        reason: bad,
      );
    }
    expect(
      () => EditCommands.writeTemp('/etc/nginx/nginx.conf'),
      _refused('not an edit temp file'),
    );
    expect(
      () => EditCommands.replaceIfHash(_target, _temp, 'abc'),
      _refused('not a SHA-256'),
    );
  });

  test('backups go to the root directory or a user one only', () {
    expect(
      EditCommands.backupFile(
        _target,
        '/home/a/.local/state$kBackupsDirSuffix',
      ).last,
      '/home/a/.local/state/klabautermann/backups',
    );
    expect(
      () => EditCommands.backupFile(_target, '/var/backups'),
      _refused('not a backup directory'),
    );
    expect(() => EditCommands.sha256List([]), _refused('no paths'));
  });

  test('the scripts exit with the EditExit codes', () {
    expect(
      EditCommands.replaceIfHash(_target, _temp, _hash)[2],
      allOf(contains('exit ${EditExit.hashMismatch};')),
    );
    final attributes = EditCommands.copyAttributes(_target, _temp)[2];
    expect(attributes, contains('exit ${EditExit.aclNotCarried}\n'));
    expect(attributes, contains('exit ${EditExit.xattrNotCarried}\n'));
    expect(
      EditCommands.backupFile(_target, kRootBackupsDir)[2],
      contains('"\$d/$kEditBackupIndexName"'),
    );
  });

  test('the readers take what the scripts print', () {
    expect(parseReadHeader('120 0 4 640 $_hash'), (
      size: 120,
      uid: 0,
      gid: 4,
      mode: 416,
      sha256: _hash,
    ));
    expect(parseReadHeader('120 0 4 640 xyz'), isNull);
    expect(parseReadHeader('120 0 4 999 $_hash'), isNull);
    // `stat -c %a` drops leading zeros.
    expect(parseReadHeader('0 0 0 7 $_hash')?.mode, 7);
    expect(parseReadHeader('99999999999999999999 0 0 644 $_hash'), isNull);
    expect(parseSha256List('$_hash  /etc/a\n${'b' * 64}  /etc/b c\nnoise\n'), {
      '/etc/a': _hash,
      '/etc/b c': 'b' * 64,
    });
    // GNU escapes a path with a backslash and marks its line.
    expect(parseSha256List('\\$_hash  /etc/a\\\\b\n'), {r'/etc/a\b': _hash});
    // And a newline in the path the same way.
    expect(parseSha256List('\\$_hash  /etc/a\\nb\n'), {'/etc/a\nb': _hash});
    // BusyBox prints a backslash as it is, on an unmarked line.
    expect(parseSha256List('$_hash  /etc/a\\b\n'), {r'/etc/a\b': _hash});
  });
}
