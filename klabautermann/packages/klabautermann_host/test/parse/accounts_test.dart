// ACC-01 and ACC-02's parser: accounts with their groups and the reasons
// they can become root, and the logins `who` lists.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const _sample =
    '''
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
deploy:x:1000:1000:Deploy:/home/deploy:/bin/bash
ops:x:1001:1001::/home/ops:/bin/zsh
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
$kAccountsGroupMarker
root:x:0:
daemon:x:1:
sudo:x:27:deploy
docker:x:998:deploy,ops
deploy:x:1000:
ops:x:1001:
$kAccountsWhoMarker
deploy   pts/0        2026-10-26 01:23 (203.0.113.7)
ops      tty1         2026-10-25 22:05
''';

void main() {
  test('each account carries its primary group first, then the groups that '
      'list it, and why it can become root', () {
    final snapshot = parseAccounts(_sample)!;
    final byName = {
      for (final account in snapshot.accounts) account.name: account,
    };
    expect(byName.keys, ['root', 'daemon', 'deploy', 'ops', 'nobody']);

    expect(byName['root']!.rootEquivalence, {RootEquivalence.uidZero});
    expect(byName['deploy']!.groups, ['deploy', 'docker', 'sudo']);
    expect(byName['deploy']!.rootEquivalence, {
      RootEquivalence.adminGroup,
      RootEquivalence.dockerGroup,
    });
    expect(byName['ops']!.rootEquivalence, {RootEquivalence.dockerGroup});
    expect(byName['ops']!.shell, '/bin/zsh');
    expect(byName['daemon']!.rootEquivalence, isEmpty);

    expect(byName['root']!.isSystem, isFalse);
    expect(byName['deploy']!.isSystem, isFalse);
    expect(byName['daemon']!.isSystem, isTrue);
    expect(byName['nobody']!.isSystem, isTrue);
    expect(snapshot.notListed, 0);
  });

  test('who\'s logins carry their terminal, UTC start and origin', () {
    final snapshot = parseAccounts(_sample)!;
    expect(snapshot.sessionsRead, isTrue);
    final [remote, local] = snapshot.sessions;
    expect(remote.user, 'deploy');
    expect(remote.line, 'pts/0');
    expect(remote.since, DateTime.utc(2026, 10, 26, 1, 23));
    expect(remote.from, '203.0.113.7');
    expect(local.from, isNull);
  });

  test('no logins read as none, while a format who prints that does not '
      'parse reads as unknown', () {
    final none = parseAccounts(
      'root:x:0:0::/root:/bin/sh\n$kAccountsGroupMarker\n'
      '$kAccountsWhoMarker\n',
    )!;
    expect(none.sessions, isEmpty);
    expect(none.sessionsRead, isTrue);

    // BusyBox prints a header and its own time format.
    final busybox = parseAccounts(
      'root:x:0:0::/root:/bin/sh\n$kAccountsGroupMarker\n'
      '$kAccountsWhoMarker\n'
      'USER       TTY      IDLE      TIME            HOST\n'
      'root       pts/0    00:00     Oct 26 01:00:00 203.0.113.7\n',
    )!;
    expect(busybox.sessions, isEmpty);
    expect(busybox.sessionsRead, isFalse);
  });

  test('accounts past the limit are counted, malformed lines skipped, and '
      'output without the markers is not the read', () {
    final many = StringBuffer();
    for (var i = 0; i < kAccountsLimit + 3; i++) {
      many.writeln('u$i:x:${2000 + i}:100::/home/u$i:/bin/sh');
    }
    many
      ..writeln('broken line')
      ..writeln('bad:x:notanumber:1::/:/bin/sh')
      ..writeln(kAccountsGroupMarker)
      ..writeln(kAccountsWhoMarker);
    final snapshot = parseAccounts(many.toString())!;
    expect(snapshot.accounts, hasLength(kAccountsLimit));
    expect(snapshot.notListed, 3);
    // A primary group the group list lacks leaves the groups empty.
    expect(snapshot.accounts.first.groups, isEmpty);

    expect(parseAccounts('root:x:0:0::/root:/bin/sh\n'), isNull);
  });
}
