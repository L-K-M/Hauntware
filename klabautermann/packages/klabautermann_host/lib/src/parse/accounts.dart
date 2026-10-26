/// Parser for ACC-01 and ACC-02's read (03 §7.9): `getent passwd` and
/// `getent group` (or the files themselves), then `who`, as
/// [HostCommands.accounts] prints them.
library;

import 'package:meta/meta.dart';

/// The section markers [HostCommands.accounts] prints between its parts.
const kAccountsGroupMarker = '== group';
const kAccountsWhoMarker = '== who';

/// How many accounts the read lists; a directory-backed host can
/// enumerate far more, which the read counts instead.
const kAccountsLimit = 2000;

/// Why an account can become root without a password prompt of its own
/// (ACC-01).
enum RootEquivalence {
  /// Its UID is 0.
  uidZero,

  /// It is in a group sudo or su grants root (`sudo`, `wheel`, `admin`).
  adminGroup,

  /// It is in the `docker` group, whose socket hands out root.
  dockerGroup,
}

/// The groups sudo and polkit commonly grant root to.
const _adminGroups = {'sudo', 'wheel', 'admin'};

/// The names of shells that let no one log in, wherever they are
/// installed (`/usr/sbin/nologin`, `/sbin/nologin`, `/bin/false`, a Nix
/// store path).
const _noLoginShells = {'nologin', 'false'};

/// The first UID most distributions give a person rather than a service.
const _firstPersonUid = 1000;

/// One account (ACC-01).
@immutable
final class HostAccount {
  HostAccount({
    required this.name,
    required this.uid,
    required this.gid,
    required this.home,
    required this.shell,
    required List<String> groups,
    required Set<RootEquivalence> rootEquivalence,
  }) : groups = List.unmodifiable(groups),
       rootEquivalence = Set.unmodifiable(rootEquivalence);

  final String name;
  final int uid;
  final int gid;
  final String home;
  final String shell;

  /// Its primary group's name first, where known, then the groups that
  /// list it, by name.
  final List<String> groups;

  /// Why it can become root; empty for most accounts.
  final Set<RootEquivalence> rootEquivalence;

  /// Whether it is a service account: no login shell, or a UID below the
  /// people's range other than root's.
  bool get isSystem =>
      _noLoginShells.contains(shell.split('/').last) ||
      (uid != 0 && uid < _firstPersonUid) ||
      uid == _nobodyUid;
}

/// `nobody`'s UID on most distributions, above the people's range.
const _nobodyUid = 65534;

/// One login `who` lists (ACC-02).
@immutable
final class HostSession {
  const HostSession({
    required this.user,
    required this.line,
    required this.since,
    this.from,
  });

  final String user;

  /// The terminal, such as `pts/0`.
  final String line;

  /// When it began, to the minute: `who` runs with `TZ=UTC`.
  final DateTime since;

  /// Where it came from, a host or address; null for a local login.
  final String? from;
}

/// What the read found.
@immutable
final class AccountsSnapshot {
  AccountsSnapshot({
    required List<HostAccount> accounts,
    required List<HostSession> sessions,
    this.notListed = 0,
    this.sessionsRead = true,
  }) : accounts = List.unmodifiable(accounts),
       sessions = List.unmodifiable(sessions);

  /// The accounts in the order the host lists them.
  final List<HostAccount> accounts;

  final List<HostSession> sessions;

  /// Accounts beyond [kAccountsLimit], counted rather than listed.
  final int notListed;

  /// False when `who` printed nothing it could read, as BusyBox's
  /// columns; the sessions are then unknown, not none.
  final bool sessionsRead;
}

/// GNU `who`'s line in the C locale: user, line, `YYYY-MM-DD HH:MM`,
/// and the origin in parentheses for a remote login.
final _whoLine = RegExp(
  r'^(\S+)\s+(\S+)\s+(\d{4}-\d\d-\d\d \d\d:\d\d)(?:\s+\((.*)\))?\s*$',
);

/// The accounts and sessions in [raw], or null when it is not the read's
/// output.
AccountsSnapshot? parseAccounts(String raw) {
  final lines = raw.split('\n');
  final groupAt = lines.indexOf(kAccountsGroupMarker);
  final whoAt = lines.indexOf(kAccountsWhoMarker);
  if (groupAt < 0 || whoAt < groupAt) return null;

  // name -> members, gid -> name.
  final members = <String, Set<String>>{};
  final groupNames = <int, String>{};
  for (final line in lines.sublist(groupAt + 1, whoAt)) {
    final fields = line.split(':');
    if (fields.length < 4) continue;
    final gid = int.tryParse(fields[2]);
    if (gid == null) continue;
    groupNames.putIfAbsent(gid, () => fields[0]);
    members[fields[0]] = {
      for (final member in fields[3].split(','))
        if (member.isNotEmpty) member,
    };
  }

  final accounts = <HostAccount>[];
  var notListed = 0;
  for (final line in lines.sublist(0, groupAt)) {
    final fields = line.split(':');
    if (fields.length < 7) continue;
    final uid = int.tryParse(fields[2]);
    final gid = int.tryParse(fields[3]);
    if (uid == null || gid == null) continue;
    if (accounts.length == kAccountsLimit) {
      notListed++;
      continue;
    }
    final name = fields[0];
    final primary = groupNames[gid];
    final listed = [
      for (final MapEntry(key: group, value: names) in members.entries)
        if (names.contains(name) && group != primary) group,
    ]..sort();
    final groups = [?primary, ...listed];
    accounts.add(
      HostAccount(
        name: name,
        uid: uid,
        gid: gid,
        home: fields[5],
        shell: fields[6],
        groups: groups,
        rootEquivalence: {
          if (uid == 0) RootEquivalence.uidZero,
          if (groups.any(_adminGroups.contains)) RootEquivalence.adminGroup,
          if (groups.contains('docker')) RootEquivalence.dockerGroup,
        },
      ),
    );
  }

  final whoLines = [
    for (final line in lines.sublist(whoAt + 1))
      if (line.trim().isNotEmpty) line,
  ];
  final sessions = [
    for (final line in whoLines)
      if (_whoLine.firstMatch(line) case final match?)
        HostSession(
          user: match[1]!,
          line: match[2]!,
          since: DateTime.parse('${match[3]!.replaceFirst(' ', 'T')}Z'),
          from: switch (match[4]) {
            final from? when from.isNotEmpty => from,
            _ => null,
          },
        ),
  ];
  return AccountsSnapshot(
    accounts: accounts,
    sessions: sessions,
    notListed: notListed,
    sessionsRead: whoLines.isEmpty || sessions.isNotEmpty,
  );
}
