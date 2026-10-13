/// Severity of a flagged command pattern.
enum DangerSeverity { warning, critical }

class DangerFinding {
  final DangerSeverity severity;
  final String pattern;
  final String explanation;

  const DangerFinding({
    required this.severity,
    required this.pattern,
    required this.explanation,
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
class DangerLinter {
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
      RegExp(r':\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:'),
      DangerSeverity.critical,
      'Classic fork bomb.',
    ),
    _Rule(
      RegExp(r'\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh)\b'),
      DangerSeverity.warning,
      'Piping a downloaded script straight into a shell runs unreviewed code.',
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
        r'\bdocker\s+system\s+prune\b(?=[^\n]*(--volumes\b|--all\b|\s-\w*a))',
      ),
      DangerSeverity.critical,
      'docker system prune --all deletes every unused image; --volumes also '
      'deletes unused volumes and their data.',
    ),
    _Rule(
      RegExp(r'\bdocker\s+volume\s+prune\b'),
      DangerSeverity.critical,
      'Removes unused volumes and their data (named ones too with --all or '
      'before Docker 23).',
    ),
    _Rule(
      RegExp(r'\bdocker\s+volume\s+rm\b'),
      DangerSeverity.warning,
      'Deletes a named volume and its data.',
    ),
    _Rule(
      // Options may sit between compose and down (`-f f.yaml`, `-p web`);
      // only -v/--volumes after down drops volumes.
      RegExp(
        r'\b(?:docker\s+compose|docker-compose)\b[^\n]*\sdown\b'
        r'(?=[^\n]*(--volumes\b|\s-\w*v))',
      ),
      DangerSeverity.critical,
      'compose down -v drops the stack\'s volumes.',
    ),
    _Rule(
      // Matches ssh, sshd, ssh.service and ssh.socket; status and restart
      // leave access intact and are not flagged.
      RegExp(r'\bsystemctl\s+(?:stop|disable|mask)\b[^\n]*\bssh'),
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
      RegExp(r'\bnft\s+flush\s+ruleset\b'),
      DangerSeverity.warning,
      'Drops the entire nftables ruleset.',
    ),
    // The two userdel rules are mutually exclusive: the same -r/--remove
    // condition is a negative lookahead here and a positive one below, so a
    // command gets one finding at the right severity. The match is
    // case-sensitive because -R (--root) names a chroot, not a removal.
    _Rule(
      RegExp(r'\buserdel\b(?![^\n]*(\s-\w*r|--remove\b))'),
      DangerSeverity.warning,
      'Removes a user account.',
    ),
    _Rule(
      RegExp(r'\buserdel\b(?=[^\n]*(\s-\w*r|--remove\b))'),
      DangerSeverity.critical,
      'userdel -r also deletes the home directory.',
    ),
    _Rule(
      // `\s1\b` needs a standalone 1, so PIDs such as 1000 and job specs
      // such as %1 do not match, and a 1 that is the operand of -s, -n or
      // -l is a signal, not a PID. The (?<![\w-]) and (?![\w-]) guards
      // leave pkill, killall and tmux's kill-session alone. PID 1 only
      // receives signals it handles (pid_namespaces(7)): systemd
      // re-executes on TERM but reboots on INT (systemd(1)), and a
      // container's main process usually exits on TERM.
      RegExp(r'(?<![\w-])kill(?![\w-])[^\n]*(?<!\s-[snl])\s1\b'),
      DangerSeverity.warning,
      'Signals PID 1, the init process or a container\'s main process; '
      'this can reboot the host or stop the container.',
    ),
  ];

  /// Returns all findings for [command] (empty if it looks benign).
  static List<DangerFinding> scan(String command) {
    final normalized = command.trim();
    final findings = <DangerFinding>[];
    for (final rule in _rules) {
      if (rule.pattern.hasMatch(normalized)) {
        findings.add(DangerFinding(
          severity: rule.severity,
          pattern: rule.pattern.pattern,
          explanation: rule.explanation,
        ));
      }
    }
    return findings;
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
  _Rule(this.pattern, this.severity, this.explanation);
}
