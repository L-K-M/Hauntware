/// Redaction of raw captures before they become fixtures (03 §6.5).
///
/// Payloads are handled as Latin-1 so that every byte, valid UTF-8 or
/// not, survives unchanged unless a rule replaces it; the replacements
/// are ASCII. [Redactor.review] then reads the redacted text for what
/// the rules missed or cannot judge, and the capture tool writes nothing
/// while it finds anything.
library;

import 'dart:convert';
import 'dart:math';

import 'package:klabautermann_host/klabautermann_host.dart'
    show Collector, CronExpression, kTimeoutAbsentMarker;
import 'package:seance_core/seance_core.dart' show SecretRedactor;

/// Stands in for a removed argument, secret, field or `--redact` value.
const kRedacted = '[redacted]';

/// Host-specific values the capturing side knows, matched in any case.
/// A one-character value is skipped: as a word or anywhere it would hit
/// unrelated text.
final class RedactionLiterals {
  const RedactionLiterals({
    this.hostNames = const [],
    this.domains = const [],
    this.userNames = const [],
    this.homeDirs = const [],
    this.extra = const [],
  });

  /// The host's names, as whole words.
  final List<String> hostNames;

  /// The host's domains, as whole words: they also name its neighbours
  /// (`backup.corp.example`).
  final List<String> domains;

  /// Personal login names (not system accounts), as whole words.
  final List<String> userNames;

  /// Those accounts' home directories.
  final List<String> homeDirs;

  /// Values the reviewer names with `--redact`, wherever they occur.
  final List<String> extra;
}

/// One collector's redacted payload and what was replaced in it.
final class RedactedPayload {
  const RedactedPayload(this.bytes, this.counts);

  final List<int> bytes;

  /// Replacements per rule name; rules that matched nothing are absent.
  final Map<String, int> counts;
}

const _hostPlaceholder = 'fixture-host';
const _domainPlaceholder = 'example.net';
const _homePlaceholder = '/home/user';
const _userPlaceholder = 'user';
const _serverPlaceholder = 'fixture-nas';
const _emailPlaceholder = 'user@example.com';
const _uuidPlaceholder = '00000000-0000-0000-0000-000000000000';
const _macPlaceholder = '00:00:5e:00:53:01';
const _diskPlaceholder = 'fixture-disk';
const _devicePlaceholder = 'fixture-device';
const _ipv6Placeholder = '2001:db8::1';
const _ipv4Placeholder = '192.0.2.1';
const _macNamePlaceholder = '00005e005301';

/// Every placeholder. [Redactor.review] reads past them, as one can hold
/// a literal: `/home/user` holds the user `user`. An end that is a letter
/// or digit needs a non-word neighbour, so that `user` in `superuser`
/// stays text.
final _placeholder = RegExp(
  [
    for (final p in [
      _hostPlaceholder,
      _domainPlaceholder,
      _homePlaceholder,
      _userPlaceholder,
      _serverPlaceholder,
      _emailPlaceholder,
      _uuidPlaceholder,
      _macPlaceholder,
      _diskPlaceholder,
      _devicePlaceholder,
      _ipv6Placeholder,
      _ipv4Placeholder,
      kRedacted,
    ])
      [
        if (_wordChar.hasMatch(p[0])) '(?<![A-Za-z0-9])',
        RegExp.escape(p),
        if (_wordChar.hasMatch(p[p.length - 1])) '(?![A-Za-z0-9])',
      ].join(),
    '(?<![A-Za-z0-9])(0{32,}|(enx|wlx)$_macNamePlaceholder|fixture$_x2d'
        '(disk|device))(?![A-Za-z0-9])',
  ].join('|'),
);

final _wordChar = RegExp('[A-Za-z0-9]');

/// A `-` as systemd escapes it in a unit name (`\x2d`), its backslash
/// doubled inside JSON strings.
const _x2d = r'\\{1,2}x2d';

/// Any character as systemd escapes it in a unit name.
const _escape = r'\\{1,2}x[0-9a-fA-F]{2}';

enum _Literal {
  host('host name', _hostPlaceholder, 'still names the host'),
  domain('domain name', _domainPlaceholder, "still names the host's domain"),
  home('home directory', _homePlaceholder, 'still names a home directory'),
  user('user name', _userPlaceholder, 'still names a user'),
  extra('--redact value', kRedacted, 'still holds a --redact value');

  const _Literal(this.rule, this.replacement, this.residue);

  final String rule, replacement, residue;
}

final _secrets = SecretRedactor();

/// `SecretRedactor`'s mask, read from its output rather than copied, so
/// that it is mapped to the ASCII [kRedacted] even if the mask changes.
final _secretMask = _secrets.redact('token=x').substring('token='.length);

final _privateKeyHeader = RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----');

/// A shell word: quoted parts and unquoted characters, no whitespace. A
/// quote left open runs to the end of the line.
const _shellValue = r'''(?!\[redacted\])(?:"[^"\n]*"?|'[^'\n]*'?|[^\s"'])+''';

/// Whitespace within a line.
const _blank = r'[^\S\n]';

/// Words that make an assignment's name or an option's name secret.
const _secretWord = 'PASS|PWD|SECRET|TOKEN|KEY|AUTH|CRED';

/// Clients whose short option takes a password, as (program, option,
/// gap): the MySQL clients' `-p<password>` (`-p` alone prompts), sshpass,
/// the MongoDB tools, the OpenLDAP clients, redis-cli, zip and unzip,
/// 7-Zip's `-p<password>`. Elsewhere these letters are ports and flags.
const _passwordOptions = [
  (r'(?:mysql|mariadb)[a-z-]*', '-p', ''),
  ('sshpass', '-p', '$_blank*'),
  ('mongo[a-z]*', '-p', '$_blank*'),
  ('ldap[a-z]*', '-w', '$_blank*'),
  ('redis-cli', '-a', '$_blank*'),
  ('(?:un)?zip', '-P', '$_blank*'),
  ('7z[arz]?', '-p', ''),
];

/// Credential shapes `SecretRedactor` misses, common in crontabs; the
/// value after group 1 is replaced. An assignment to a name or an option
/// whose name holds a [_secretWord] (`PGPASSWORD=`, `--passphrase x`),
/// HTTP basic auth, curl's `-u` and `-U user:password`, Samba's
/// `-U user%password` and the [_passwordOptions].
final _credentials = [
  RegExp(
    '(?<![A-Za-z0-9_])([A-Za-z0-9_]*(?:$_secretWord)[A-Za-z0-9_]*=)'
    '$_shellValue',
    caseSensitive: false,
  ),
  RegExp(
    r'(Authorization:\s*Basic\s+)(?!\[redacted\])[A-Za-z0-9+/]+=*',
    caseSensitive: false,
  ),
  RegExp(
    r'(?<!\S)(-[uU]\s*|--(?:proxy-)?user[=\s]\s*)'
    '''['"]?[^\\s:%'"]+[:%](?!/)$_shellValue''',
  ),
  for (final (program, option, gap) in _passwordOptions)
    RegExp(
      '(?<![A-Za-z0-9])($program(?:$_blank+(?!$option)[^\\s|;&]+)*?'
      '$_blank+$option$gap)$_shellValue',
    ),
  // Last, so that a client's `-pPassw0rd` is its value, not an option.
  // A `--no-` option is a flag.
  RegExp(
    '(?<![A-Za-z0-9_-])(--?(?!-|no-)[A-Za-z0-9_-]*?(?:$_secretWord)'
    '[A-Za-z0-9_-]*'
    '(?:=|$_blank+))$_shellValue',
    caseSensitive: false,
  ),
];

/// A network filesystem's source starting a `df` row: NFS and sshfs
/// `[user@]server:/path`, CIFS `//server/share`. A server given by
/// address is left to the address rules.
final _mountSource = RegExp(
  r'^(?:(//)[A-Za-z][^/\s]*(?=/)|'
  r'(?:[^\s/@:]+@)?[A-Za-z][A-Za-z0-9.-]*(?=:/))',
  multiLine: true,
);

final _unitType = RegExp(
  r'\.(service|socket|device|mount|automount|swap|target|path|timer|slice|'
  r'scope)$',
);

final _patterns = <(String, RegExp, String Function(Match))>[
  // Every account's home, not only the literals': directory-service
  // accounts are missing from /etc/passwd, and homes also lie under
  // /var/home (Fedora Atomic) or in an NFS export.
  (
    'home directory',
    RegExp(r'''/home/[^/\s"'\\:;,)\]}\x00-\x1f]+'''),
    (_) => _homePlaceholder,
  ),
  // The same homes as mount unit names (`home-erin-Music.mount` for
  // /home/erin/Music), where systemd escapes a `-` or a non-ASCII byte.
  (
    'home directory',
    RegExp(
      '(?<![^\\s"\'\\[,])((?:(?:$_escape|[^\\s"\'@/\\\\-])+-)*home-)'
      '(?:$_escape|[^\\s"\'@/\\\\-])+'
      r'''(?=(-[^\s"']*)?\.(auto)?mount(?![A-Za-z0-9]))''',
    ),
    (m) => '${m[1]}$_userPlaceholder',
  ),
  // logind's session scopes, described as `Session <id> of User <name>`.
  (
    'user name',
    RegExp(r'(Session \S+ of User )([^\s"\\]+)'),
    (m) => m[2] == 'root' ? m[0]! : '${m[1]}$_userPlaceholder',
  ),
  (
    'URL credentials',
    RegExp(
      r'(?<![A-Za-z0-9+.-])([A-Za-z][A-Za-z0-9+.-]*://)[^\s/@:]*:[^\s/@]*@',
    ),
    (m) => '${m[1]}$kRedacted@',
  ),
  (
    'email address',
    RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'),
    // A systemd template instance (`getty@tty1.service`) has the same
    // shape; its unit type is the last label.
    (m) => _unitType.hasMatch(m[0]!) ? m[0]! : _emailPlaceholder,
  ),
  // udev's `/dev/<subsystem>/by-<kind>/` links carry a drive's model
  // and serial number, its WWN or SAS address (also in `by-path`), a
  // volume UUID or label, a USB serial adapter's or camera's serial
  // number; device unit names hold them systemd-escaped.
  (
    'device id',
    RegExp(r'''/dev/([A-Za-z0-9_]+)/by-([A-Za-z0-9-]+)/[^\s"']+'''),
    (m) =>
        '/dev/${m[1]}/by-${m[2]}/'
        '${m[1] == 'disk' ? _diskPlaceholder : _devicePlaceholder}',
  ),
  (
    'device id',
    RegExp(
      '(dev-([A-Za-z0-9_]+)-by($_x2d)(?:[A-Za-z0-9]|$_x2d)+?-)[^\\s"\']+?'
      r'''(?=\.(device|swap|service|target|mount)(?![A-Za-z0-9])|[\s"']|$)''',
    ),
    (m) => '${m[1]}fixture${m[3]}${m[2] == 'disk' ? 'disk' : 'device'}',
  ),
  (
    'UUID',
    RegExp(
      '(?:(?<![0-9A-Fa-f])|(?<=$_x2d))[0-9a-fA-F]{8}(-|$_x2d)[0-9a-fA-F]{4}'
      r'\1[0-9a-fA-F]{4}\1[0-9a-fA-F]{4}\1[0-9a-fA-F]{12}(?![0-9A-Fa-f-])',
    ),
    (m) => _uuidPlaceholder.replaceAll('-', m[1]!),
  ),
  // Machine and boot ids, container ids, digests.
  (
    'hex id',
    RegExp(r'(?<![0-9A-Fa-f])[0-9a-fA-F]{32,}(?![0-9A-Fa-f])'),
    (m) => '0' * m[0]!.length,
  ),
  (
    'MAC address',
    RegExp(
      r'(?<![0-9A-Fa-f:])([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}(?![0-9A-Fa-f:])',
    ),
    (_) => _macPlaceholder,
  ),
  // systemd names USB and wireless interfaces after their MAC.
  (
    'MAC address',
    RegExp(r'(?<![A-Za-z0-9])(enx|wlx)[0-9a-fA-F]{12}(?![A-Za-z0-9])'),
    (m) => '${m[1]}$_macNamePlaceholder',
  ),
  // hostnamectl's serial, asset tag and free-text naming fields.
  (
    'identity field',
    RegExp(
      r'"(\w*Serial\w*|\w*AssetTag|PrettyHostname|Location)"(\s*:\s*)"'
      r'(?:[^"\\]|\\.)*"',
    ),
    (m) => '"${m[1]}"${m[2]}"$kRedacted"',
  ),
  // systemd 256 and later repeat /etc/machine-info, 262 adds its TAGS= as
  // a list.
  (
    'identity field',
    RegExp(r'"(PRETTY_HOSTNAME|LOCATION|TAGS)=(?:[^"\\]|\\.)*"'),
    (m) => '"${m[1]}=$kRedacted"',
  ),
  (
    'identity field',
    RegExp(r'"MachineTags"(\s*:\s*)\[((?:[^\]"]|"(?:[^"\\]|\\.)*")*)\]'),
    (m) => m[2]!.contains('"') ? '"MachineTags"${m[1]}["$kRedacted"]' : m[0]!,
  ),
  (
    'IPv6 address',
    RegExp(
      // Not inside a longer colon run, but after a word's `:`, and before
      // a port printed without brackets (systemd's socket instance names).
      r'(?<![0-9A-Za-z]|(?<![0-9A-Za-z])[0-9a-fA-F]{1,4}:|::)'
      r'(([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|'
      r'([0-9a-fA-F]{1,4}:){1,7}:([0-9a-fA-F]{1,4}(:[0-9a-fA-F]{1,4}){0,6})?|'
      r'::[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{1,4}){0,6})'
      r'(?=(:\d{1,5})?(?![0-9A-Za-z:]|\.\d))',
    ),
    (m) => m[0] == '::1' ? '::1' : _ipv6Placeholder,
  ),
  (
    'IPv4 address',
    RegExp(
      r'(?<![0-9.])((25[0-5]|2[0-4]\d|1?\d?\d)\.){3}'
      // A `.` may end the sentence, not a longer dotted number.
      r'(25[0-5]|2[0-4]\d|1?\d?\d)(?!\.?[0-9])',
    ),
    (m) {
      final ip = m[0]!;
      return ip.startsWith('127.') || ip == '0.0.0.0' ? ip : _ipv4Placeholder;
    },
  ),
];

// What the review reports beyond literals and SecretRedactor's secrets:
// text no rule rewrites, because a guess could hide what a parser needs.
final _reviewPatterns = <(String, RegExp)>[
  ('mentions a private key', RegExp('private key', caseSensitive: false)),
  // Key material: 40 or more base64 characters mixing digits and both
  // cases, not starting a path.
  (
    'holds a long base64 run',
    RegExp(
      r'(?<![A-Za-z0-9+/])(?=[A-Za-z0-9+/]*\d)(?=[A-Za-z0-9+/]*[A-Z])'
      r'(?=[A-Za-z0-9+/]*[a-z])[A-Za-z0-9+][A-Za-z0-9+/]{39,}',
    ),
  ),
];

/// Applies the 03 §6.5 redaction to capture payloads.
final class Redactor {
  Redactor(RedactionLiterals literals)
    : this._(
        [
            for (final h in literals.hostNames) (_Literal.host, h),
            for (final d in literals.domains) (_Literal.domain, d),
            for (final h in literals.homeDirs) (_Literal.home, h),
            for (final u in literals.userNames) (_Literal.user, u),
            for (final e in literals.extra) (_Literal.extra, e),
          ].where((l) => l.$2.length > 1).toList()
          // Longest first, so a FQDN goes before its first label.
          ..sort((a, b) => b.$2.length - a.$2.length),
      );

  Redactor._(List<(_Literal, String)> literals)
    : _kinds = [for (final (kind, _) in literals) kind],
      _literal = literals.isEmpty
          ? null
          : RegExp(
              literals.map((l) => '(${_literalPattern(l.$1, l.$2)})').join('|'),
              caseSensitive: false,
            );

  final List<_Literal> _kinds;

  /// One alternative per literal, each in its own group.
  final RegExp? _literal;

  /// Redacts one payload. [collector] selects the argv rules for `procs`.
  RedactedPayload redact(String collector, List<int> payload) {
    final counts = <String, int>{};
    void count(String rule) => counts[rule] = (counts[rule] ?? 0) + 1;

    var text = latin1.decode(payload);
    if (collector == Collector.procs.wireName) text = _redactArgv(text, count);
    if (collector == Collector.cron.wireName) text = _redactCron(text, count);
    if (collector == Collector.fs.wireName) {
      text = text.replaceAllMapped(_mountSource, (m) {
        count('mount source');
        return '${m[1] ?? ''}$_serverPlaceholder';
      });
    }
    if (_literal case final literal?) {
      text = text.replaceAllMapped(literal, (m) {
        final kind = _kindOf(m);
        if (m[0] != kind.replacement) count(kind.rule);
        return kind.replacement;
      });
    }

    final masks = _secretMask.allMatches(text).length;
    text = _secrets.redact(text);
    final secrets = _secretMask.allMatches(text).length - masks;
    if (secrets > 0) counts['secret'] = secrets;
    text = text.replaceAll(_secretMask, kRedacted);
    for (final re in _credentials) {
      text = text.replaceAllMapped(re, (m) {
        count('secret');
        return '${m[1]}$kRedacted';
      });
    }
    text = text.replaceAllMapped(_privateKeyHeader, (_) {
      count('secret');
      return kRedacted;
    });

    for (final (rule, re, replace) in _patterns) {
      text = text.replaceAllMapped(re, (m) {
        final r = replace(m);
        if (r != m[0]) count(rule);
        return r;
      });
    }
    return RedactedPayload(latin1.encode(text), counts);
  }

  /// The 1-based line numbers of [text] that still hold a literal, a
  /// secret `SecretRedactor` would mask, or text no rule rewrites, each
  /// with the reason; empty when the text may be written.
  List<(int, String)> review(String text) {
    final findings = <(int, String)>[];
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final reasons = {
        if (_literal case final literal?)
          for (final m in literal.allMatches(
            line.replaceAll(_placeholder, ' '),
          ))
            _kindOf(m).residue,
        if (_secrets.redact(line).replaceAll(_secretMask, kRedacted) != line ||
            _credentials.any((re) => re.hasMatch(line)))
          'looks like a secret',
        for (final (reason, re) in _reviewPatterns)
          if (re.hasMatch(line)) reason,
      };
      findings.addAll([for (final r in reasons) (i + 1, r)]);
    }
    return findings;
  }

  _Literal _kindOf(Match m) {
    for (var g = 1; g <= _kinds.length; g++) {
      if (m[g] != null) return _kinds[g - 1];
    }
    throw StateError('no literal group matched');
  }

  /// Host names, domains and user names match as whole words (a letter or digit on
  /// neither side, so `home-anke.mount` matches and `anker` does not), a
  /// home directory as a whole path, a `--redact` value anywhere. A `-`
  /// also matches device-mapper's `--` and systemd's `\x2d`, so that
  /// `web-01` matches in `/dev/mapper/web--01--vg-root`; a name may
  /// follow any systemd escape (`\x2d`, a space's `\x20`).
  static String _literalPattern(_Literal kind, String value) {
    final escaped = latin1
        .decode(utf8.encode(value))
        .split('-')
        .map(RegExp.escape)
        .join('(?:-{1,2}|(?:$_x2d){1,2})');
    return switch (kind) {
      _Literal.host || _Literal.domain || _Literal.user =>
        '(?:(?<![A-Za-z0-9])|(?<=$_escape))$escaped(?![A-Za-z0-9])',
      _Literal.home => '$escaped(?![A-Za-z0-9._-])',
      _Literal.extra => escaped,
    };
  }
}

final _cmdlineHeader = RegExp(r'^==> \d+/cmdline <==$');

enum _ProcsPart { rows, cmdlineStart, cmdline, psHeader, ps }

/// Rewrites the argv sources of a `procs` payload (03 §7.2). Everything
/// after `== cmdline ==` is the `head` dump unless a `ps` or `ps_w`
/// block opens it. In the dump an argument may hold newlines, so every
/// line but a `==> <pid>/cmdline <==` header is argument text, block
/// headers included. In a `ps` block each row keeps the first word of
/// its command column; with no `COMMAND` header, of the whole row.
String _redactArgv(String text, void Function(String rule) count) {
  final out = <String>[];
  var part = _ProcsPart.rows;
  var entryStart = false;
  var column = 0;
  var userField = -1;
  for (final line in text.split('\n')) {
    var redacted = line;
    switch (part) {
      case _ProcsPart.rows:
        if (line == '== cmdline ==') part = _ProcsPart.cmdlineStart;
      case _ProcsPart.cmdlineStart || _ProcsPart.psHeader
          when line == kTimeoutAbsentMarker:
        break;
      case _ProcsPart.cmdlineStart
          when line == '== ps ==' || line == '== ps_w ==':
        part = _ProcsPart.psHeader;
      case _ProcsPart.cmdlineStart || _ProcsPart.cmdline:
        part = _ProcsPart.cmdline;
        if (_cmdlineHeader.hasMatch(line)) {
          entryStart = true;
          break;
        }
        // The first line of an entry starts with argv[0]; later lines
        // continue an argument that held a newline.
        final args = line.split('\x1f');
        final kept = entryStart ? _keepFirstWord(args.first) : null;
        redacted = [
          ?kept,
          for (final a in args.skip(kept == null ? 0 : 1))
            a.isEmpty ? a : kRedacted,
        ].join('\x1f');
        entryStart = false;
      case _ProcsPart.psHeader:
        column = max(0, line.indexOf('COMMAND'));
        userField = line.trim().split(RegExp(r'\s+')).indexOf('USER');
        part = _ProcsPart.ps;
      case _ProcsPart.ps:
        final cut = min(column, line.length);
        final head = line.substring(0, cut);
        final user = _psUser(head, userField);
        if (user != head) count('user name');
        redacted = user + _keepFirstWord(line.substring(cut));
        if (redacted.substring(user.length) != line.substring(cut)) {
          count('argv');
        }
        out.add(redacted);
        continue;
    }
    if (redacted != line) count('argv');
    out.add(redacted);
  }
  return out.join('\n');
}

/// A block header of a collector payload, as `splitBlocks` reads it.
final _blockHeader = RegExp(r'^== ([a-z0-9_-]+) ==$');

/// A crontab(5) environment line, as `parseCron` reads it: the name, `=`
/// and the blanks around it, then the value.
final _cronEnv = RegExp(r'^(\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*)([^\n]*)$');

/// A crontab job line: its schedule (an `@` macro or five fields) with
/// the blanks after it, then the rest.
final _cronJob = RegExp(
  r'^(\s*(@\S+|\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s+)(\S[^\n]*)$',
);

/// What follows a system crontab's schedule: the user field, then the
/// command.
final _cronUser = RegExp(r'^(\S+)(\s+)(\S[^\n]*)$');

/// The `crontab_meta` lines `parseCron` reads.
final _cronStatus = RegExp(r'^\s*(rc=-?\d+|tool=missing)\s*$');

/// A `cron_dirs` entry: `<period> <name>`.
final _cronDirEntry = RegExp(r'^\s*(hourly|daily|weekly|monthly) ');

final _firstWord = RegExp(r'^(\s*)(\S+)([^\n]*)$');

/// Rewrites a `cron` payload (03 §7.7) the way [_redactArgv] does
/// `procs`: a command carries the same secrets, user names and hosts as
/// an argv, and `parseCron` only keeps it as text. Each job keeps its
/// schedule, a user field of `root` (others read `user`) and the first
/// word of its command; comment text and environment values but
/// `CRON_TZ`, which jobs are evaluated in, read [kRedacted]. The blocks
/// are found as `parseCron` finds them; a line it reads as no job, entry
/// or status keeps its first word only. A failed `crontab -l` keeps its
/// output, from which `parseCron` reads "no crontab".
String _redactCron(String text, void Function(String rule) count) {
  final lines = text.split('\n');
  // parseCron reads the last `rc=` of every crontab_meta line.
  var block = '';
  var missing = false;
  int? rc;
  for (final line in lines) {
    final header = _blockHeader.firstMatch(line.trim());
    if (header != null) {
      block = header[1]!;
    } else if (block == 'crontab_meta') {
      final t = line.trim();
      if (t == 'tool=missing') missing = true;
      if (t.startsWith('rc=')) rc = int.tryParse(t.substring(3));
    }
  }
  final ownJobs = !missing && rc == 0;

  block = '';
  final out = <String>[];
  for (final line in lines) {
    final header = _blockHeader.firstMatch(line.trim());
    if (header != null) block = header[1]!;
    final tab = line.indexOf('\t');
    out.add(switch (block) {
      _ when header != null || line == kTimeoutAbsentMarker => line,
      'crontab_meta' when _cronStatus.hasMatch(line) => line,
      'crontab' when ownJobs => _crontabLine(line, false, count),
      'crontab' when line.toLowerCase().contains('no crontab') => line,
      'etc_crontab' => _crontabLine(line, true, count),
      'cron_d' when tab >= 0 =>
        line.substring(0, tab + 1) +
            _crontabLine(line.substring(tab + 1), true, count),
      'cron_dirs' when line.trim().isEmpty || _cronDirEntry.hasMatch(line) =>
        line,
      _ => _firstWordOnly(line, count),
    });
  }
  return out.join('\n');
}

/// One crontab line, `parseCron`'s order: a comment, an environment
/// line, a job; [system] for the user field of `/etc/crontab` and
/// `/etc/cron.d`. A line whose schedule does not parse keeps its first
/// word only, so that no name lands where a command word is kept.
String _crontabLine(String line, bool system, void Function(String) count) {
  final t = line.trim();
  if (t.isEmpty) return line;
  if (t.startsWith('#')) {
    if (t == '#') return line;
    count('cron text');
    return '${line.substring(0, line.indexOf('#') + 1)} $kRedacted';
  }
  if (_cronEnv.firstMatch(line) case final env?) {
    if (env[2] == 'CRON_TZ' || env[3]!.trim().isEmpty) return line;
    count('cron text');
    return '${env[1]}$kRedacted';
  }
  final job = _cronJob.firstMatch(line);
  if (job == null || CronExpression.parse(job[2]!) == null) {
    return _firstWordOnly(line, count);
  }
  var command = job[3]!;
  var user = '';
  if (system) {
    final field = _cronUser.firstMatch(command);
    if (field == null) return _firstWordOnly(line, count);
    final name = field[1]!;
    final kept = name == 'root' ? name : _userPlaceholder;
    if (kept != name) count('user name');
    user = '$kept${field[2]}';
    command = field[3]!;
  }
  return '${job[1]}$user${_firstWordOnly(command, count)}';
}

/// Keeps leading blanks and the first word of [s], then one [kRedacted]
/// for the rest. An assignment's value (`PGPASSWORD=x pg_dump`) goes too.
String _firstWordOnly(String s, void Function(String rule) count) {
  final m = _firstWord.firstMatch(s);
  if (m == null) return s;
  final word = m[2]!;
  final eq = word.indexOf('=');
  final kept = eq < 0 || eq == word.length - 1
      ? word
      : '${word.substring(0, eq + 1)}$kRedacted';
  final out = [
    '${m[1]}$kept',
    if (m[3]!.trim().isNotEmpty) kRedacted,
  ].join(' ');
  if (out != s) count('cron text');
  return out;
}

/// [head], the columns of a `ps` row before its command, with the word
/// in the USER column ([field], -1 for none) reading `user` unless it is
/// root, padded so that the columns stay aligned.
String _psUser(String head, int field) {
  if (field < 0) return head;
  final m = RegExp('^(\\s*(?:\\S+\\s+){$field})(\\S+)').firstMatch(head);
  if (m == null || m[2] == 'root') return head;
  return '${m[1]}${_userPlaceholder.padRight(m[2]!.length)}'
      '${head.substring(m.end)}';
}

/// Keeps leading spaces and the first word of [s]; anything after that
/// becomes one [kRedacted]. Process titles put user names there
/// (OpenSSH's `user [priv]`, `user@pts/0`).
String _keepFirstWord(String s) {
  final start = s.length - s.trimLeft().length;
  final space = s.indexOf(' ', start);
  return space < 0 ? s : '${s.substring(0, space)} $kRedacted';
}
