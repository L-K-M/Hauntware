/// Reads `sudo -l`'s listing of the login user's rules (03 §7.17, D66):
/// whether a rule lets root run a program with any arguments, so the
/// engine elevates a detached runner only where sudo will run it.
library;

/// The line that opens sudo's list of the user's rules, from sudo and
/// sudo-rs alike: "User klab may run the following commands on host:".
const _rulesHeader = 'may run the following commands';

/// sudo's answer for a user with no rule at all.
const _noRules = 'is not allowed to run sudo';

/// The tags before a rule's commands, such as `NOPASSWD:` or `SETENV:`.
final _tags = RegExp(r'^(?:[A-Z_]+:\s*)+');

/// A comma between commands; sudoers escapes one inside a command.
final _commandSeparator = RegExp(r'(?<!\\),');

/// The characters that make a sudoers path a glob (sudoers(5), "Wildcards").
final _globCharacters = RegExp(r'[*?\[]');

/// Whether [output], `sudo -l` run as the login user, lets root run
/// [program] (a base name such as `systemd-run`) with any arguments: a
/// rule whose run-as user is root or `ALL` and whose commands hold `ALL`
/// or [program] without arguments, or with a lone `*`, which matches any.
/// A negated command naming [program] denies it unless a later one allows
/// it again: sudoers lets the last match win, and `sudo -l` lists the
/// rules in sudoers' order. Only [program]'s base name is known, not its
/// directory, so a glob counts one way only: a negated one whose base name
/// matches denies, and one that would allow allows nothing.
///
/// False when sudo says the user may run nothing; null when [output]
/// holds no listing at all (a refusal, a failed password, or another
/// tool's text), which tells the caller nothing.
bool? sudoListAllows(String output, String program) {
  final lines = output.split('\n');
  final start = lines.indexWhere((line) => line.contains(_rulesHeader));
  if (start < 0) return output.contains(_noRules) ? false : null;

  var allowed = false;
  for (final line in lines.skip(start + 1)) {
    if (line.trim().isEmpty) continue;
    // The rules are indented; the next section or sudo's next message
    // is not.
    if (!line.startsWith(' ') && !line.startsWith('\t')) break;

    final rule = _parseRule(line.trim());
    if (rule == null || !rule.asRoot) continue;
    for (final entry in rule.commands) {
      // Each command may carry its own tags: `/bin/ls, NOEXEC: /bin/vi`.
      final command = entry.replaceFirst(_tags, '');
      final negated = command.startsWith('!');
      final words = (negated ? command.substring(1) : command).trim().split(
        RegExp(r'\s+'),
      );
      final head = words.first;
      if (negated && _globMatches(_baseName(head), program)) {
        allowed = false;
        continue;
      }
      final names = head == 'ALL' || _baseName(head) == program;
      if (!names) continue;
      if (negated) {
        allowed = false;
        continue;
      }
      // Arguments in a rule restrict the command to exactly those, but a
      // lone `*` matches any.
      final anyArguments =
          words.length == 1 || (words.length == 2 && words[1] == '*');
      if (head == 'ALL' || anyArguments) allowed = true;
    }
  }
  return allowed;
}

/// One listed rule: whether it runs commands as root, and its commands.
({bool asRoot, List<String> commands})? _parseRule(String line) {
  if (!line.startsWith('(')) return null;
  final close = line.indexOf(')');
  if (close < 0) return null;

  // `(users)` or `(users : groups)`; the users decide root.
  final runAs = line.substring(1, close).split(':').first;
  final users = runAs.split(',').map((user) => user.trim()).toSet();
  final asRoot =
      users.contains('ALL') || users.contains('root') || users.contains('#0');

  final rest = line.substring(close + 1).trim().replaceFirst(_tags, '');
  final commands = [
    for (final command in rest.split(_commandSeparator))
      if (command.trim().isNotEmpty) command.trim(),
  ];
  return (asRoot: asRoot, commands: commands);
}

String _baseName(String path) => path.substring(path.lastIndexOf('/') + 1);

/// Whether [pattern], a sudoers glob's last path component, matches
/// [name]: `*`, `?` and bracket expressions, with `!` negating a bracket
/// as in fnmatch(3). A pattern without glob characters never matches here;
/// the exact comparison covers it.
bool _globMatches(String pattern, String name) {
  if (!pattern.contains(_globCharacters)) return false;

  final regex = StringBuffer('^');
  for (var i = 0; i < pattern.length; i++) {
    final char = pattern[i];
    if (char == '*') {
      regex.write('.*');
    } else if (char == '?') {
      regex.write('.');
    } else if (char == '[') {
      final close = pattern.indexOf(']', i + 2);
      if (close < 0) {
        regex.write(r'\[');
        continue;
      }
      var set = pattern.substring(i + 1, close);
      if (set.startsWith('!')) set = '^${set.substring(1)}';
      regex.write('[${set.replaceAll(r'\', r'\\')}]');
      i = close;
    } else {
      regex.write(RegExp.escape(char));
    }
  }
  regex.write(r'$');
  return RegExp(regex.toString()).hasMatch(name);
}
