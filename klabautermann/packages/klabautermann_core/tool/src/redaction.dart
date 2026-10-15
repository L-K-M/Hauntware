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
    show Collector, kTimeoutAbsentMarker;
import 'package:seance_core/seance_core.dart' show SecretRedactor;

/// Stands in for a removed argument, secret, field or `--redact` value.
const kRedacted = '[redacted]';

/// Host-specific values the capturing side knows, matched in any case.
/// A one-character value is skipped: as a word or anywhere it would hit
/// unrelated text.
final class RedactionLiterals {
  const RedactionLiterals({
    this.hostNames = const [],
    this.userNames = const [],
    this.homeDirs = const [],
    this.extra = const [],
  });

  /// The host's names, as whole words.
  final List<String> hostNames;

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
const _homePlaceholder = '/home/user';
const _userPlaceholder = 'user';
const _serverPlaceholder = 'fixture-nas';
const _emailPlaceholder = 'user@example.com';
const _uuidPlaceholder = '00000000-0000-0000-0000-000000000000';
const _macPlaceholder = '00:00:5e:00:53:01';
const _diskPlaceholder = 'fixture-disk';
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
      _homePlaceholder,
      _userPlaceholder,
      _serverPlaceholder,
      _emailPlaceholder,
      _uuidPlaceholder,
      _macPlaceholder,
      _diskPlaceholder,
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
        'disk)(?![A-Za-z0-9])',
  ].join('|'),
);

final _wordChar = RegExp('[A-Za-z0-9]');

/// A `-` as systemd escapes it in a unit name (`\x2d`), its backslash
/// doubled inside JSON strings.
const _x2d = r'\\{1,2}x2d';

/// The `/dev/disk/by-*` links that name a disk by its serial, WWN, UUID
/// or label rather than by its bus position.
const _diskLinkKinds = 'id|uuid|partuuid|label|partlabel';

enum _Literal {
  host('host name', _hostPlaceholder, 'still names the host'),
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

/// A shell word: quoted parts and unquoted characters, no whitespace.
const _shellValue = r'''(?!\[redacted\])(?:"[^"\n]*"|'[^'\n]*'|[^\s"'])+''';

/// Credential shapes `SecretRedactor` misses, common in crontabs; the
/// value after group 1 is replaced. An assignment to a name holding
/// PASS, PWD, SECRET, TOKEN or KEY (`PGPASSWORD=`, `MYSQL_PWD=`), HTTP
/// basic auth, curl's `-u user:password`, and the `-p<password>` of the
/// MySQL clients and of sshpass. `-p` alone is a port or a flag in most
/// programs and the MySQL clients' password prompt.
final _credentials = [
  RegExp(
    '(?<![A-Za-z0-9_])([A-Za-z0-9_]*(?:PASS|PWD|SECRET|TOKEN|KEY)'
    '[A-Za-z0-9_]*=)'
    '$_shellValue',
    caseSensitive: false,
  ),
  RegExp(
    r'(Authorization:\s*Basic\s+)(?!\[redacted\])[A-Za-z0-9+/]+=*',
    caseSensitive: false,
  ),
  RegExp(
    '''(?<!\\S)(-u\\s*|--user[=\\s]\\s*)['"]?[^\\s:'"]+:(?!/)$_shellValue''',
  ),
  RegExp(
    r'(?<![A-Za-z0-9])((?:mysql|mariadb)[a-z-]*(?:\s+(?!-p)[^\s|;&]+)*?\s+-p)'
    '$_shellValue',
  ),
  RegExp(
    r'(?<![A-Za-z0-9])(sshpass\s+(?:-\S+\s+)*?-p\s*)'
    '$_shellValue',
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
  (
    'URL credentials',
    RegExp(
      r'(?<![A-Za-z0-9+.-])([A-Za-z][A-Za-z0-9+.-]*://)[^\s/@:]+:[^\s/@]*@',
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
  // udev's links carry the drive's model and serial number or a volume
  // UUID; device unit names hold them systemd-escaped.
  (
    'disk id',
    RegExp('/dev/disk/by-($_diskLinkKinds)/[^\\s"\']+'),
    (m) => '/dev/disk/by-${m[1]}/$_diskPlaceholder',
  ),
  (
    'disk id',
    RegExp(
      '(dev-disk-by($_x2d)($_diskLinkKinds)-)[^\\s"\']+?'
      r'''(?=\.(device|swap|service|target)(?![A-Za-z0-9])|[\s"']|$)''',
    ),
    (m) => '${m[1]}fixture${m[2]}disk',
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
  (
    'IPv6 address',
    RegExp(
      r'(?<![0-9A-Za-z:])(([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|'
      r'([0-9a-fA-F]{1,4}:){1,7}:([0-9a-fA-F]{1,4}(:[0-9a-fA-F]{1,4}){0,6})?|'
      r'::[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{1,4}){0,6})(?![0-9A-Za-z:]|\.\d)',
    ),
    (m) => m[0] == '::1' ? '::1' : _ipv6Placeholder,
  ),
  (
    'IPv4 address',
    RegExp(
      r'(?<![0-9.])((25[0-5]|2[0-4]\d|1?\d?\d)\.){3}'
      r'(25[0-5]|2[0-4]\d|1?\d?\d)(?![0-9.])',
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
  (
    'passes a secret option',
    RegExp(
      r'(?<![A-Za-z0-9])--?(pass(word)?|passwd|token|secret|api-?key)'
      r'(\s+|=)(?!\[redacted\])\S',
      caseSensitive: false,
    ),
  ),
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

  /// Host and user names match as whole words (a letter or digit on
  /// neither side, so `home-anke.mount` matches and `anker` does not), a
  /// home directory as a whole path, a `--redact` value anywhere. A `-`
  /// also matches device-mapper's `--` and systemd's `\x2d`, so that
  /// `web-01` matches in `/dev/mapper/web--01--vg-root`; a name may
  /// follow a `\x2d`.
  static String _literalPattern(_Literal kind, String value) {
    final escaped = latin1
        .decode(utf8.encode(value))
        .split('-')
        .map(RegExp.escape)
        .join('(?:-{1,2}|(?:$_x2d){1,2})');
    return switch (kind) {
      _Literal.host ||
      _Literal.user => '(?:(?<![A-Za-z0-9])|(?<=$_x2d))$escaped(?![A-Za-z0-9])',
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
        part = _ProcsPart.ps;
      case _ProcsPart.ps when line.length > column:
        redacted =
            line.substring(0, column) + _keepFirstWord(line.substring(column));
      case _ProcsPart.ps:
        break;
    }
    if (redacted != line) count('argv');
    out.add(redacted);
  }
  return out.join('\n');
}

/// Keeps leading spaces and the first word of [s]; anything after that
/// becomes one [kRedacted]. Process titles put user names there
/// (OpenSSH's `user [priv]`, `user@pts/0`).
String _keepFirstWord(String s) {
  final start = s.length - s.trimLeft().length;
  final space = s.indexOf(' ', start);
  return space < 0 ? s : '${s.substring(0, space)} $kRedacted';
}
