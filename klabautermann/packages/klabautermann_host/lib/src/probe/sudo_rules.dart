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

/// Whether [output], `sudo -l` run as the login user, lets root run
/// [program] (a base name such as `systemd-run`) with any arguments: a
/// rule whose run-as user is root or `ALL` and whose commands hold `ALL`
/// or [program] without arguments, or with a lone `*`, which matches any.
/// A negated command naming [program] denies it unless a later one allows
/// it again: sudoers lets the last match win, and `sudo -l` lists the
/// rules in sudoers' order.
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
    for (final command in rule.commands) {
      final negated = command.startsWith('!');
      final words = (negated ? command.substring(1) : command).trim().split(
        RegExp(r'\s+'),
      );
      final head = words.first;
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
