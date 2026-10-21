/// Reads `sudo -l`'s listing of the login user's rules (03 §7.17, D66):
/// whether a rule lets root run a program with any arguments, so the
/// engine elevates a detached runner only where sudo will run it.
library;

/// The line that opens sudo's list of the user's rules, from sudo and
/// sudo-rs alike: "User klab may run the following commands on host:".
const _rulesHeader = 'may run the following commands';

/// sudo's answer for a user with no rule at all.
const _noRules = 'is not allowed to run sudo';

/// The options and tags before a rule's commands, such as `CWD=/srv`,
/// `TIMEOUT=5m`, `NOPASSWD:` or `SETENV:`; `sudo -l` lists the options
/// first (sudoers(5), "Cmnd_Spec").
final _tags = RegExp(r'^(?:[A-Z_]+(?::|=\S*)\s*)+');

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
      // A path ending in `/` names every file in that directory.
      final directory = head.endsWith('/');
      if (negated && (directory || _globMatches(_baseName(head), program))) {
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

/// The bracket expression opening at [start] as a regex character class,
/// and the index of its closing `]`; null when it never closes, which
/// leaves the `[` literal.
({String regex, int end})? _bracket(String pattern, int start) {
  var i = start + 1;
  final negate = i < pattern.length && (pattern[i] == '!' || pattern[i] == '^');
  if (negate) i++;

  // Each member as its literal character; a range joins two of them.
  final members = <String>[];
  // A `]` first in the set is a member, not its end.
  if (i < pattern.length && pattern[i] == ']') {
    members.add(']');
    i++;
  }
  final ranges = StringBuffer();
  for (; i < pattern.length; i++) {
    final c = pattern[i];
    if (c == ']') {
      final set = '${members.map(_classLiteral).join()}$ranges';
      // A set left with no members, such as `[z-a]`, matches nothing.
      final regex = set.isEmpty
          ? (negate ? '[^]' : '[]')
          : '[${negate ? '^' : ''}$set]';
      return (regex: regex, end: i);
    }
    // A `-` between two members makes a range; first or last in the set,
    // it is a member.
    final range =
        c == '-' &&
        members.isNotEmpty &&
        i + 1 < pattern.length &&
        pattern[i + 1] != ']';
    if (range) {
      final first = members.removeLast();
      var last = pattern[++i];
      if (last == r'\' && i + 1 < pattern.length) last = pattern[++i];
      // fnmatch(3) reads a reversed range as empty; a regex rejects it.
      if (first.compareTo(last) <= 0) {
        ranges.write('${_classLiteral(first)}-${_classLiteral(last)}');
      }
      continue;
    }
    members.add(c == r'\' && i + 1 < pattern.length ? pattern[++i] : c);
  }
  return null;
}

/// [c] as a literal member of a regex character class: letters and
/// digits as they are, since `\d` or `\w` would name a class, and any
/// other character escaped.
String _classLiteral(String c) =>
    RegExp(r'[A-Za-z0-9]').hasMatch(c) ? c : '\\$c';

String _baseName(String path) => path.substring(path.lastIndexOf('/') + 1);

/// Whether [pattern], a sudoers glob's last path component, matches
/// [name]: `*`, `?` and bracket expressions, with `!` or `^` negating a
/// bracket and a `]` first in one taken as a member, as in fnmatch(3),
/// and a backslash making the next character literal. A pattern without
/// glob characters never matches here; the exact comparison covers it.
bool _globMatches(String pattern, String name) {
  if (!pattern.contains(_globCharacters)) return false;

  final regex = StringBuffer('^');
  for (var i = 0; i < pattern.length; i++) {
    final char = pattern[i];
    if (char == r'\' && i + 1 < pattern.length) {
      regex.write(RegExp.escape(pattern[++i]));
    } else if (char == '*') {
      regex.write('.*');
    } else if (char == '?') {
      regex.write('.');
    } else if (char == '[') {
      final bracket = _bracket(pattern, i);
      if (bracket == null) {
        regex.write(r'\[');
        continue;
      }
      regex.write(bracket.regex);
      i = bracket.end;
    } else {
      regex.write(RegExp.escape(char));
    }
  }
  regex.write(r'$');
  return RegExp(regex.toString()).hasMatch(name);
}
