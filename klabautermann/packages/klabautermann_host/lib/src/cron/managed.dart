/// Crontab lines another manager owns (JOB-09, 03 §8.7): shown read-only,
/// and an edit that changes them needs the tier-2 "act anyway" naming
/// the manager.
library;

import 'document.dart' show kCrontabPauseMarker;

/// The managers whose crontab blocks JOB-09 recognizes (03 §8.7).
enum CrontabManager { dokku, coolify, dokploy, runtipi }

/// A comment naming a manager as a word, which opens its block [U]: the
/// managers' exact markers are not pinned, so the name is.
final _managerComment = RegExp(
  r'^\s*#.*\b(dokku|coolify|dokploy|runtipi)\b',
  caseSensitive: false,
);

/// The manager whose block holds each of [lines], one crontab's or one
/// `/etc/cron.d` file's lines in order, or null for a line no manager
/// owns. Dokku reserves its own account's crontab, so every line of
/// [user] `dokku`'s is Dokku's; a cron.d file named for a manager is
/// that manager's. Elsewhere a comment naming a manager opens its
/// block, which runs to the next blank line [U]. A marker can only make
/// a line more read-only, never less.
List<CrontabManager?> crontabOwners(
  List<String> lines, {
  String? user,
  String? cronDFile,
}) {
  final whole = user == 'dokku'
      ? CrontabManager.dokku
      : switch (cronDFile) {
          final name? => _managerNamed(name),
          null => null,
        };
  if (whole != null) return List.filled(lines.length, whole);

  final owners = <CrontabManager?>[];
  CrontabManager? block;
  for (final line in lines) {
    if (line.trim().isEmpty) {
      block = null;
    } else if (line.startsWith(kCrontabPauseMarker)) {
      // A job this app paused is a comment too; whatever its held
      // command names, it opens no manager's block.
    } else if (_managerComment.firstMatch(line) case final m?) {
      block = CrontabManager.values.byName(m[1]!.toLowerCase());
    }
    owners.add(block);
  }
  return owners;
}

/// The manager [name] names as a whole word, such as `dokku` or
/// `coolify-backups`, or null.
CrontabManager? _managerNamed(String name) {
  final lower = name.toLowerCase();
  for (final manager in CrontabManager.values) {
    if (RegExp('(^|[^a-z])${manager.name}(\$|[^a-z])').hasMatch(lower)) {
      return manager;
    }
  }
  return null;
}
