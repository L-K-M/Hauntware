/// Severity of a flagged command pattern.
enum DangerSeverity { warning, critical }

class DangerFinding {
  final DangerSeverity severity;
  final String pattern;
  final String explanation;

  /// The 1-based line of the scanned text on which the flagged command
  /// starts. A command continued with a trailing backslash counts from its
  /// first line.
  final int line;

  const DangerFinding({
    required this.severity,
    required this.pattern,
    required this.explanation,
    required this.line,
  });
}

/// A client-side, model-independent check for obviously destructive commands.
/// It runs on every command the assistant proposes and on every paste, so a
/// dangerous suggestion is flagged even if the model failed to mark it — and
/// even if it was smuggled in via prompt injection.
///
/// This is a safety net, not a sandbox: it is intentionally conservative and
/// makes no attempt to fully parse shell grammar. Nothing is ever blocked
/// outright — findings are surfaced to the user, who still makes the call.
///
/// Rules match one command at a time, so a flag or path from the next
/// command cannot complete a pattern (`systemctl stop nginx; ssh host` is
/// benign) and a backslash-newline continuation cannot split one
/// (`userdel \` + newline + `-r deploy` is one command). [_ShellText]
/// describes the split and its limits.
class DangerLinter {
  /// `docker` and any global options before its subcommand, such as
  /// `--context prod` or `-H ssh://h`. An option's value is a word that
  /// does not start with `-`; backtracking lets a flag without one stand
  /// alone.
  static const _docker = r'\bdocker(?:\s+-\S+(?:\s+[^\s-]\S*)?)*';

  /// `kill`, unless its first argument means no signal is sent: -l, -L,
  /// --list and --table print signal names, and signal 0 (-0, -s 0, -n 0,
  /// --signal 0) only probes whether a process exists. Only the first
  /// argument counts, so a `# -l` comment cannot hide `kill -9 1`. The
  /// (?<![\w-]) and (?![\w-]) guards leave pkill, killall and tmux's
  /// kill-session alone.
  static const _kill =
      r'(?<![\w-])kill(?![\w-])'
      r'(?!\s+(?:-[lL]\b|--list\b|--table\b|-0\b|-[sn]\s*0\b'
      r'|--signal[=\s]\s*0\b))';

  /// Rejects a word that is the operand of a signal, queue or timeout
  /// option, so it is not read as a PID.
  static const _notOptionOperand =
      r'(?<!\s(?:-[snq]|--signal|--queue|--timeout))';

  static final List<_Rule> _rules = [
    _Rule(
      // A recursive/forced rm whose target is an ABSOLUTE path (/, /etc,
      // /var/lib, …), a home path (~, $HOME), or a wildcard. The lookahead
      // requires an -r/-f flag; the target must start after whitespace so a
      // relative path like `a/b` isn't matched. (The old rule only fired on a
      // bare `/`, `~`, `*`, or `$HOME`, so `rm -rf /etc` slipped through.)
      RegExp(r'\brm\b(?=[^\n]*\s-{1,2}[a-zA-Z]*[rf])[^\n]*\s(/\S*|~\S*|\$HOME\S*|\*)(\s|$)'),
      DangerSeverity.critical,
      'Recursive/forced delete of an absolute, home, or wildcard path.',
    ),
    _Rule(
      RegExp(r'\bdd\b.*\bof=/dev/'),
      DangerSeverity.critical,
      'dd writing directly to a device node can destroy a disk.',
    ),
    _Rule(
      RegExp(r'\bmkfs(\.\w+)?\b'),
      DangerSeverity.critical,
      'Creates a filesystem, erasing the target device.',
    ),
    _Rule(
      RegExp(r'\bwipefs\b'),
      DangerSeverity.critical,
      'wipefs erases the filesystem signatures from a device.',
    ),
    _Rule(
      RegExp(r'>\s*/dev/(sd|nvme|vd|hd)\w+'),
      DangerSeverity.critical,
      'Redirecting output onto a block device overwrites it.',
    ),
    _Rule(
      // Made of separators, so it is matched on the whole text.
      RegExp(r':\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:'),
      DangerSeverity.critical,
      'Classic fork bomb.',
      scope: _Scope.text,
    ),
    _Rule(
      RegExp(r'\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh)\b'),
      DangerSeverity.warning,
      'Piping a downloaded script straight into a shell runs unreviewed code.',
      scope: _Scope.pipeline,
    ),
    _Rule(
      RegExp(r'\bchmod\s+(-R\s+)?0?777\b'),
      DangerSeverity.warning,
      'World-writable permissions (777) are almost never intended.',
    ),
    _Rule(
      RegExp(r'\bshred\b'),
      DangerSeverity.warning,
      'shred overwrites a file so it cannot be recovered.',
    ),
    _Rule(
      RegExp(r'\bfind\b[^\n]*\s-delete\b'),
      DangerSeverity.warning,
      'find -delete removes every matched file.',
    ),
    _Rule(
      RegExp(r'\btruncate\b[^\n]*-s\s*0\b'),
      DangerSeverity.warning,
      'truncate -s 0 discards a file\'s contents.',
    ),
    _Rule(
      RegExp(r'\bgit\s+clean\b[^\n]*\s-[a-zA-Z]*f'),
      DangerSeverity.warning,
      'git clean -f deletes untracked files (-x/-d widen the blast radius).',
    ),
    _Rule(
      RegExp(r'\b(shutdown|reboot|halt|poweroff)\b'),
      DangerSeverity.warning,
      'Powers down or reboots the host.',
    ),
    _Rule(
      RegExp(r'\biptables\s+-F\b'),
      DangerSeverity.warning,
      'Flushes firewall rules; can lock you out of a remote host.',
    ),
    // Docker, systemd, cron, firewall and account rules (Klabautermann F2d,
    // docs/design/seance-core-transport.md §3.6). Critical is kept for mass
    // or unbounded destruction; scoped data loss and lockouts warn, as the
    // power and iptables rules above do.
    _Rule(
      // Plain `docker system prune` removes stopped containers, unused
      // networks, dangling images and build cache; --all/-a adds every
      // unused image and --volumes unused volumes. Since Docker 23 (API
      // 1.42) volume pruning takes only anonymous volumes unless
      // `docker volume prune` gets --all; older engines take named ones too.
      RegExp(
        '$_docker'
        r'\s+system\s+prune\b(?=[^\n]*(--volumes\b|--all\b|\s-\w*a))',
      ),
      DangerSeverity.critical,
      'docker system prune --all deletes every unused image; --volumes also '
      'deletes unused volumes and their data.',
    ),
    _Rule(
      RegExp('$_docker' r'\s+volume\s+prune\b'),
      DangerSeverity.critical,
      'Removes unused volumes and their data (named ones too with --all or '
      'before Docker 23).',
    ),
    _Rule(
      // `docker volume remove` is an alias of rm.
      RegExp('$_docker' r'\s+volume\s+(?:rm|remove)\b'),
      DangerSeverity.warning,
      'Deletes a named volume and its data.',
    ),
    _Rule(
      // Options may sit between compose and down (`-f f.yaml`, `-p web`);
      // only -v/--volumes after down drops volumes.
      RegExp(
        '(?:$_docker'
        r'\s+compose|\bdocker-compose)\b[^\n]*\sdown\b'
        r'(?=[^\n]*(--volumes\b|\s-\w*v))',
      ),
      DangerSeverity.critical,
      'compose down -v drops the stack\'s volumes.',
    ),
    _Rule(
      // Options, with or without a value, may come before the verb
      // (systemctl --now disable ssh, systemctl -H prod stop sshd), and
      // service(8) takes the unit first. The unit is ssh or sshd with an
      // optional suffix (ssh.socket, sshd@1.service), so sshfs, ssh-agent
      // and sshd-keygen are not matched; status and restart leave access
      // intact.
      RegExp(
        r'\bsystemctl(?:\s+-\S+(?:\s+[^\s-]\S*)?)*\s+(?:stop|disable|mask)\s'
        r'[^\n]*\bsshd?(?![\w-])'
        r'|\bservice\s+sshd?\s+stop\b',
      ),
      DangerSeverity.warning,
      'Stopping or masking sshd cuts future SSH access to the host.',
    ),
    _Rule(
      RegExp(r'\bcrontab\b[^\n]*\s-\w*r'),
      DangerSeverity.warning,
      'crontab -r deletes the user\'s whole cron table.',
    ),
    _Rule(
      // Skips leading options such as --force before the verb.
      RegExp(r'\bufw\b(?:\s+--?\w[\w-]*)*\s+(?:reset|disable)\b'),
      DangerSeverity.warning,
      'Removes or switches off the firewall.',
    ),
    _Rule(
      // A flushed table or chain keeps its base chains' policies, so a drop
      // policy then blocks everything, as after `iptables -F` above; a
      // flushed ruleset has no tables left and filters nothing.
      RegExp(r'\bnft\s+flush\s+(?:ruleset|table|chain)\b'),
      DangerSeverity.warning,
      'Drops nftables rules (a whole ruleset, table or chain); this can '
      'leave the host unfiltered or lock you out.',
    ),
    // The two account rules are mutually exclusive: each command's removal
    // flags are a negative lookahead here and a positive one below, so a
    // command gets one finding at the right severity. userdel is matched
    // case-sensitively because -R (--root) names a chroot, not a removal.
    // deluser NAME removes an account but deluser NAME GROUP only takes
    // NAME out of GROUP, and deluser --group NAME removes a group, so a
    // second operand or a leading --group rules the warning out. Neither
    // test reads a `#` comment, so a comment cannot hide the command. An
    // option that takes a value (--conf FILE) is read as an operand, which
    // misses that rare form. deluser --remove-home and --remove-all-files
    // destroy the home directory or more, so they are critical like
    // userdel -r.
    _Rule(
      RegExp(
        r'\buserdel\b(?![^\n]*(\s-\w*r|--remove\b))'
        r'|\bdeluser(?![^\n]*\s--remove-(?:home|all-files)\b)'
        r'(?:\s+(?!--group\b)-\S+)*\s+[^\s<>#-][^\s<>]*(?=\s|$)'
        r'(?!(?:\s+-\S+)*\s+[^\s<>#-][^\s<>]*(?=\s|$))',
      ),
      DangerSeverity.warning,
      'Removes a user account.',
    ),
    _Rule(
      RegExp(
        r'\buserdel\b(?=[^\n]*(\s-\w*r|--remove\b))'
        r'|\bdeluser\b(?=[^\n]*\s--remove-(?:home|all-files)\b)',
      ),
      DangerSeverity.critical,
      'userdel -r and deluser --remove-home also delete the home '
      'directory; deluser --remove-all-files deletes every file the user '
      'owns.',
    ),
    _Rule(
      // `\s1\b` needs a standalone 1, so PIDs such as 1000 and job specs
      // such as %1 do not match, and a 1 that is the operand of -s, -n,
      // --signal and the like is a signal, not a PID. PID 1 only receives
      // signals it handles (pid_namespaces(7)): systemd re-executes on TERM
      // but reboots on INT (systemd(1)), and a container's main process
      // usually exits on TERM.
      RegExp('$_kill' r'[^\n]*' '$_notOptionOperand' r'\s1\b'),
      DangerSeverity.warning,
      'Signals PID 1, the init process or a container\'s main process; '
      'this can reboot the host or stop the container.',
    ),
    _Rule(
      // PID -1 is every process the caller may signal (kill(2)). Only a
      // -1 after the first argument is a PID: a leading -1 is SIGHUP. This
      // warns like the PID 1 and power rules: processes stop, stored data
      // stays.
      RegExp(
        '$_kill'
        r'\s+\S+[^\n]*'
        '$_notOptionOperand'
        r'\s-1(?=\s|$)',
      ),
      DangerSeverity.warning,
      'Signals every process you are allowed to signal; as root that ends '
      'every service and session on the host.',
    ),
  ];

  /// Returns all findings for [command] (empty if it looks benign), one
  /// per rule and line, ordered by line and then by rule.
  static List<DangerFinding> scan(String command) {
    final shell = _ShellText.parse(command);
    final hits = <(int line, int rule)>{};
    for (final (index, rule) in _rules.indexed) {
      if (rule.scope == _Scope.text) {
        for (final match in rule.pattern.allMatches(shell.text)) {
          hits.add((shell.lineAt(match.start), index));
        }
        continue;
      }

      final segments = rule.scope == _Scope.pipeline
          ? shell.pipelines
          : shell.commands;
      for (final segment in segments) {
        if (rule.pattern.hasMatch(segment.text)) {
          hits.add((segment.line, index));
        }
      }
    }

    final ordered = hits.toList()
      ..sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
    return [
      for (final (line, index) in ordered)
        DangerFinding(
          severity: _rules[index].severity,
          pattern: _rules[index].pattern.pattern,
          explanation: _rules[index].explanation,
          line: line,
        ),
    ];
  }

  /// The most severe finding, or null if none.
  static DangerSeverity? worst(String command) {
    final findings = scan(command);
    if (findings.isEmpty) return null;
    return findings.any((f) => f.severity == DangerSeverity.critical)
        ? DangerSeverity.critical
        : DangerSeverity.warning;
  }
}

class _Rule {
  final RegExp pattern;
  final DangerSeverity severity;
  final String explanation;
  final _Scope scope;
  _Rule(
    this.pattern,
    this.severity,
    this.explanation, {
    this.scope = _Scope.command,
  });
}

/// The text a rule's pattern is matched against.
enum _Scope {
  /// One command: the text between unquoted separators.
  command,

  /// One pipeline: commands joined by `|` or `|&` stay together, so the
  /// pattern sees both ends of a pipe.
  pipeline,

  /// The whole text with continuations joined, for a pattern that is built
  /// from separators.
  text,
}

/// A command or pipeline and the 1-based line on which it starts.
typedef _Segment = ({String text, int line});

/// What [_ShellText.parse] is inside of; quotes and substitutions nest.
enum _Open { singleQuote, ansiQuote, doubleQuote, substitution, backtick }

/// Shell text split into commands and pipelines.
///
/// This is a scanner, not a shell parser. It removes backslash-newline
/// continuations and ends a command at an unquoted `;`, `&&`, `||`, `&`,
/// `|`, `|&` or newline; the pipes end a command but not its pipeline. It
/// splits only outside single quotes, `$'...'`, double quotes, `$(...)`,
/// `<(...)`, `>(...)` and backticks, and honours backslash escapes. `>&`,
/// `<&`, `&>` and `>|` are redirections, and a `#` that starts a word runs
/// to the end of the line without opening quotes.
///
/// It errs toward keeping a command together: extra text only risks a
/// false positive, while a wrong split can hide part of a match. Known
/// gaps: a `case` pattern's `)` inside `$(...)` ends the substitution
/// early, here-document bodies are split like commands, and aliases,
/// functions and `eval` are not expanded.
final class _ShellText {
  _ShellText._(this.text, this._lineStarts, this.commands, this.pipelines);

  /// The input with backslash-newline continuations removed.
  final String text;

  /// Offsets in [text] at which input lines 2, 3, ... begin.
  final List<int> _lineStarts;

  final List<_Segment> commands;
  final List<_Segment> pipelines;

  /// Characters before which an unquoted `#` starts a comment.
  static const _wordBreaks = ' \t\n;&|()<>';

  factory _ShellText.parse(String input) {
    final out = StringBuffer();
    final lineStarts = <int>[];
    final commandBounds = <(int, int)>[];
    final pipelineBounds = <(int, int)>[];
    final open = <_Open>[];
    var commandStart = 0;
    var pipelineStart = 0;

    void emit(String char) {
      out.write(char);
      if (char == '\n') lineStarts.add(out.length);
    }

    void separate(String operator, {required bool pipe}) {
      commandBounds.add((commandStart, out.length));
      if (!pipe) pipelineBounds.add((pipelineStart, out.length));
      operator.split('').forEach(emit);
      commandStart = out.length;
      if (!pipe) pipelineStart = out.length;
    }

    var i = 0;
    while (i < input.length) {
      final char = input[i];
      final next = i + 1 < input.length ? input[i + 1] : '';
      final prev = i > 0 ? input[i - 1] : '';
      final inner = open.isEmpty ? null : open.last;
      // Input characters copied unchanged after the checks below.
      var width = 1;

      if (inner == _Open.singleQuote) {
        if (char == "'") open.removeLast();
      } else if (char == r'\') {
        if (next == '\n' && inner != _Open.ansiQuote) {
          // The shell drops both characters and joins the lines.
          lineStarts.add(out.length);
          i += 2;
          continue;
        }
        width = 2;
      } else if (inner == _Open.ansiQuote) {
        if (char == "'") open.removeLast();
      } else if (inner == _Open.doubleQuote) {
        if (char == '"') {
          open.removeLast();
        } else if (char == '`') {
          open.add(_Open.backtick);
        } else if (char == '(' && prev == r'$') {
          open.add(_Open.substitution);
        }
      } else if (char == "'") {
        open.add(_Open.singleQuote);
      } else if (char == '"') {
        open.add(_Open.doubleQuote);
      } else if (char == r'$' && next == "'") {
        open.add(_Open.ansiQuote);
        width = 2;
      } else if (char == '`') {
        inner == _Open.backtick ? open.removeLast() : open.add(_Open.backtick);
      } else if (char == '(' &&
          (inner == _Open.substitution ||
              (prev.isNotEmpty && r'$<>'.contains(prev)))) {
        open.add(_Open.substitution);
      } else if (char == ')' && inner == _Open.substitution) {
        open.removeLast();
      } else if (inner == null) {
        if (char == '#' && (prev == '' || _wordBreaks.contains(prev))) {
          final end = input.indexOf('\n', i);
          final stop = end < 0 ? input.length : end;
          while (i < stop) {
            emit(input[i++]);
          }
          continue;
        }
        if (char == '\n' || char == ';') {
          separate(char, pipe: false);
          i++;
          continue;
        }
        if ((char == '|' || char == '&') && next == char) {
          separate('$char$next', pipe: false);
          i += 2;
          continue;
        }
        if (char == '|' && prev != '>') {
          final operator = next == '&' ? '|&' : '|';
          separate(operator, pipe: true);
          i += operator.length;
          continue;
        }
        if (char == '&' && next != '>' && prev != '>' && prev != '<') {
          separate(char, pipe: false);
          i++;
          continue;
        }
      }

      for (var k = 0; k < width && i < input.length; k++) {
        emit(input[i++]);
      }
    }
    commandBounds.add((commandStart, out.length));
    pipelineBounds.add((pipelineStart, out.length));

    final text = out.toString();
    final shell = _ShellText._(text, lineStarts, [], []);
    void collect(List<(int, int)> bounds, List<_Segment> into) {
      for (final (start, end) in bounds) {
        final raw = text.substring(start, end);
        final trimmed = raw.trim();
        if (trimmed.isEmpty) continue;
        final first = start + raw.length - raw.trimLeft().length;
        into.add((text: trimmed, line: shell.lineAt(first)));
      }
    }

    collect(commandBounds, shell.commands);
    collect(pipelineBounds, shell.pipelines);
    return shell;
  }

  /// The 1-based input line of [offset] in [text].
  int lineAt(int offset) {
    // Counts the line starts at or before offset.
    var low = 0;
    var high = _lineStarts.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (_lineStarts[mid] <= offset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low + 1;
  }
}
