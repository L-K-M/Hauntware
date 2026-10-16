/// Redaction of raw captures before they become fixtures (03 §6.5).
///
/// Payloads are handled byte for byte ([_decode]), so that every byte,
/// valid UTF-8 or not, survives unchanged unless a rule replaces it; the
/// replacements are ASCII. [Redactor.review] then reads the redacted text
/// for what the rules missed or cannot judge, and the capture tool writes
/// nothing while it finds anything.
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

/// Every placeholder, also numbered (`user2`, [_Pseudonyms]).
/// [Redactor.review] reads past them, as one can hold a literal:
/// `/home/user` holds the user `user`. An end that is a letter or digit
/// needs a non-word neighbour, so that `user` in `superuser` stays text.
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
        if (_wordChar.hasMatch(p[p.length - 1])) r'\d*(?![A-Za-z0-9])',
      ].join(),
    '(?<![A-Za-z0-9])(0{32,}|(en|wl|ww)x$_macNamePlaceholder|fixture$_x2d'
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

/// Distinct values keep distinct placeholders, numbered in the order they
/// are met, so that a fixture still tells two containers or two homes
/// apart: `parseFs` joins its tables on the mount point. One instance
/// serves every payload of a capture.
final class _Pseudonyms {
  final _seen = <String, Map<String, int>>{};

  int _index(String kind, String key) {
    final seen = _seen[kind] ??= {};
    return seen.putIfAbsent(key, () => seen.length);
  }

  /// `user`, then `user2`, `user3`, ... per account name, in any case and
  /// systemd escaping.
  String user(String name) {
    final i = _index('user', _unescape(name).toLowerCase());
    return i == 0 ? _userPlaceholder : '$_userPlaceholder${i + 1}';
  }

  /// [id]'s length of zeros that end in its ordinal, in hex.
  String hex(String id) =>
      _index('hex', id.toLowerCase()).toRadixString(16).padLeft(id.length, '0');

  /// The UUID placeholder ending in [id]'s ordinal, its groups joined by
  /// [separator].
  String uuid(String id, String separator) {
    final i = _index('uuid', _unescape(id).toLowerCase());
    return '${_uuidPlaceholder.substring(0, 24)}'
            '${i.toRadixString(16).padLeft(12, '0')}'
        .replaceAll('-', separator);
  }
}

/// [text] with each systemd escape (`\x2d`, its backslash doubled in
/// JSON) read as the byte it stands for, as [_decode] maps it.
String _unescape(String text) =>
    text.replaceAllMapped(RegExp(r'\\{1,2}x([0-9a-fA-F]{2})'), (m) {
      final b = int.parse(m[1]!, radix: 16);
      return String.fromCharCode(b < 0x80 ? b : _byte + b);
    });

/// [bytes] as text the rules read: ASCII as itself, every other byte as
/// a private-use character. As Latin-1, the A0 that ends many UTF-8
/// characters (`à`, `Р`) would be a blank to `\s` and cut the character.
String _decode(List<int> bytes) =>
    String.fromCharCodes([for (final b in bytes) b < 0x80 ? b : _byte + b]);

/// The bytes of text from [_decode], with ASCII replacements.
List<int> _encode(String text) => [
  for (final c in text.codeUnits) c >= _byte ? c - _byte : c,
];

/// Where [_decode] puts the bytes from 0x80: the private-use area, which
/// holds no blank, letter or case pair.
const _byte = 0xE000;

/// [text] from [_decode] rewritten by [rewrite] as UTF-8 text when it is
/// valid UTF-8, so that `\s` splits it where a parser of the decoded
/// payload does (a no-break space included).
String _asUtf8(String text, String Function(String text) rewrite) {
  final String decoded;
  try {
    decoded = utf8.decode(_encode(text));
  } on FormatException {
    return rewrite(text);
  }
  return _decode(utf8.encode(rewrite(decoded)));
}

final _secrets = SecretRedactor();

/// `SecretRedactor`'s mask, read from its output rather than copied, so
/// that it is mapped to the ASCII [kRedacted] even if the mask changes.
final _secretMask = _secrets.redact('token=x').substring('token='.length);

final _privateKeyHeader = RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----');

/// A shell word: quoted parts, backslash escapes and unquoted
/// characters, no whitespace. A quote left open runs to the end of the
/// line. A word that is just [kRedacted] is done; one that only starts
/// with it (a `--redact` value's replacement) is not.
const _shellValue =
    r'''(?!\[redacted\](?![^\s"']))'''
    r'''(?:\\[^\n]?|"[^"\n]*"?|'[^'\n]*'?|[^\s"'\\])+''';

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

/// A network filesystem's source starting a `df` row, up to its path: a
/// URL (davfs, curlftpfs's `curlftpfs#ftp://`), CIFS `//server/share`,
/// and NFS, sshfs, Ceph and GlusterFS
/// `[user@]server[:port][,server[:port]]...:[path]`. A server given by
/// address is left to the address rules.
final _mountSource = RegExp(
  r'^(?:([^\s#/]*#)?([A-Za-z][A-Za-z0-9+.-]*://)(?:[^\s/@]*@)?'
  r'[A-Za-z][^\s/:]*|'
  r'(//)(?:[^\s/@]*@)?[A-Za-z][^/\s]*(?=/)|'
  r'(?:[^\s/@:]+@)?[A-Za-z][A-Za-z0-9.-]+(?::\d+)?'
  r'(?:,[A-Za-z0-9][A-Za-z0-9.-]*(?::\d+)?)*(?=:(?!//)))',
  multiLine: true,
);

/// The login before a network mount server given by address, which
/// [_mountSource] leaves to the address rules (`dave@10.0.0.5:/data`,
/// `//dave@10.0.0.5/share`), a password with it.
final _mountUser = RegExp(
  r'^((?:[^\s#/]*#)?(?:[A-Za-z][A-Za-z0-9+.-]*://|//)?)[^\s/@]+@',
  multiLine: true,
);

/// An IPv4 octet, also zero-padded.
const _octet = r'(25[0-5]|2[0-4]\d|[01]?\d?\d)';

final _unitType = RegExp(
  r'\.(service|socket|device|mount|automount|swap|target|path|timer|slice|'
  r'scope)$',
);

/// A rule: its name for the counts, its pattern and the replacement of
/// a match.
typedef _Rule = (String, RegExp, String Function(Match m, _Pseudonyms ids));

/// The rules for account names in fixed positions. They run before the
/// literals, which number the same names, so that no rule reads a name
/// another has already replaced.
final _accountPatterns = <_Rule>[
  // Every account's home, not only the literals': directory-service
  // accounts are missing from /etc/passwd, and homes also lie under
  // /var/home (Fedora Atomic) or in an NFS export.
  (
    'home directory',
    RegExp(r'''/home/([^/\s"'\\:;,)\]}\x00-\x1f]+)'''),
    (m, ids) => '/home/${ids.user(m[1]!)}',
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
    (m, ids) => '${m[1]}${ids.user(m[0]!.substring(m[1]!.length))}',
  ),
  // logind's session scopes, described as `Session <id> of User <name>`
  // (`of user` before systemd 249).
  (
    'user name',
    RegExp(r'(Session \S+ of User )([^\s"\\]+)', caseSensitive: false),
    (m, ids) => m[2] == 'root' ? m[0]! : '${m[1]}${ids.user(m[2]!)}',
  ),
];

final _patterns = <_Rule>[
  (
    'URL credentials',
    RegExp(
      // Not across a `"`: a URL ending one JSON string is no user name.
      r'(?<![A-Za-z0-9+.-])([A-Za-z][A-Za-z0-9+.-]*://)[^\s/@:"]*:[^\s/@"]*@',
    ),
    (m, _) => '${m[1]}$kRedacted@',
  ),
  (
    'email address',
    RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'),
    // A systemd template instance (`getty@tty1.service`) has the same
    // shape; its unit type is the last label.
    (m, _) => _unitType.hasMatch(m[0]!) ? m[0]! : _emailPlaceholder,
  ),
  // udev's `/dev/<subsystem>/by-<kind>/` links carry a drive's model
  // and serial number, its WWN or SAS address (also in `by-path`), a
  // volume UUID or label, a USB serial adapter's or camera's serial
  // number; device unit names hold them systemd-escaped.
  (
    'device id',
    RegExp(r'''/dev/([A-Za-z0-9_]+)/by-([A-Za-z0-9-]+)/[^\s"']+'''),
    (m, _) =>
        '/dev/${m[1]}/by-${m[2]}/'
        '${m[1] == 'disk' ? _diskPlaceholder : _devicePlaceholder}',
  ),
  (
    'device id',
    RegExp(
      '(dev-([A-Za-z0-9_]+)-by($_x2d)(?:[A-Za-z0-9]|$_x2d)+?-)[^\\s"\']+?'
      r'''(?=\.(device|swap|service|target|mount)(?![A-Za-z0-9])|[\s"']|$)''',
    ),
    (m, _) => '${m[1]}fixture${m[3]}${m[2] == 'disk' ? 'disk' : 'device'}',
  ),
  (
    'UUID',
    RegExp(
      '(?:(?<![0-9A-Fa-f])|(?<=$_x2d))[0-9a-fA-F]{8}(-|$_x2d)[0-9a-fA-F]{4}'
      r'\1[0-9a-fA-F]{4}\1[0-9a-fA-F]{4}\1[0-9a-fA-F]{12}(?![0-9A-Fa-f-])',
    ),
    (m, ids) => ids.uuid(m[0]!, m[1]!),
  ),
  // Machine and boot ids, container ids, digests.
  (
    'hex id',
    RegExp(r'(?<![0-9A-Fa-f])[0-9a-fA-F]{32,}(?![0-9A-Fa-f])'),
    (m, ids) => ids.hex(m[0]!),
  ),
  (
    'MAC address',
    RegExp(
      r'(?<![0-9A-Fa-f:])([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}(?![0-9A-Fa-f:])',
    ),
    (_, _) => _macPlaceholder,
  ),
  // The same in the notations of other systems and network gear.
  (
    'MAC address',
    RegExp(
      r'(?<![0-9A-Fa-f-])([0-9a-fA-F]{2}-){5}[0-9a-fA-F]{2}(?![0-9A-Fa-f-])',
    ),
    (_, _) => _macPlaceholder.replaceAll(':', '-'),
  ),
  (
    'MAC address',
    RegExp(
      r'(?<![0-9A-Fa-f.])([0-9a-fA-F]{4}\.){2}[0-9a-fA-F]{4}(?![0-9A-Fa-f.])',
    ),
    (_, _) => '0000.5e00.5301',
  ),
  // systemd names USB, wireless and WWAN interfaces after their MAC.
  (
    'MAC address',
    RegExp(r'(?<![A-Za-z0-9])(en|wl|ww)x[0-9a-fA-F]{12}(?![A-Za-z0-9])'),
    (m, _) => '${m[1]}x$_macNamePlaceholder',
  ),
  // hostnamectl's serial, asset tag and free-text naming fields.
  (
    'identity field',
    RegExp(
      r'"(\w*Serial\w*|\w*AssetTag|PrettyHostname|Location)"(\s*:\s*)"'
      r'(?:[^"\\]|\\.)*"',
    ),
    (m, _) => '"${m[1]}"${m[2]}"$kRedacted"',
  ),
  // systemd 256 and later repeat /etc/machine-info, 262 adds its TAGS= as
  // a list.
  (
    'identity field',
    RegExp(r'"(PRETTY_HOSTNAME|LOCATION|TAGS)=(?:[^"\\]|\\.)*"'),
    (m, _) => '"${m[1]}=$kRedacted"',
  ),
  (
    'identity field',
    RegExp(r'"MachineTags"(\s*:\s*)\[((?:[^\]"]|"(?:[^"\\]|\\.)*")*)\]'),
    // Each tag, so that the list keeps its length.
    (m, _) =>
        '"MachineTags"${m[1]}['
        '${m[2]!.replaceAll(RegExp(r'"(?:[^"\\]|\\.)*"'), '"$kRedacted"')}]',
  ),
  // An IPv6 address ending in an IPv4 one: this rule takes the prefix,
  // unless it is the generic IPv4-mapped or NAT64 one, the IPv4 rule the
  // tail.
  (
    'IPv6 address',
    RegExp(
      r'(?<![0-9A-Za-z:])((?:[0-9a-fA-F]{1,4}:){6}|'
      r'(?:(?:[0-9a-fA-F]{1,4}:)+|:):(?:[0-9a-fA-F]{1,4}:)*)'
      '(?=($_octet\\.){3}$_octet(?![0-9]))',
    ),
    (m, _) => const {'::', '::ffff:', '64:ff9b::'}.contains(m[0]!.toLowerCase())
        ? m[0]!
        : '2001:db8::',
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
    (m, _) => m[0] == '::1' ? '::1' : _ipv6Placeholder,
  ),
  (
    'IPv4 address',
    RegExp(
      // Not inside a longer dotted number (`so.1.2.3.4`, `1.2.3.4.5`), but
      // after an ellipsis; a `.` after it may end the sentence.
      '(?<![0-9]|[0-9A-Za-z]\\.)($_octet\\.){3}$_octet(?!\\.?[0-9])',
    ),
    (m, _) {
      final ip = m[0]!;
      return ip.startsWith('127.') || ip == '0.0.0.0' ? ip : _ipv4Placeholder;
    },
  ),
  // EC2's internal host names spell the address with hyphens.
  (
    'IPv4 address',
    RegExp('(?<![A-Za-z0-9])ip-($_octet-){3}$_octet(?![0-9])'),
    (_, _) => 'ip-${_ipv4Placeholder.replaceAll('.', '-')}',
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

  final _ids = _Pseudonyms();

  /// One alternative per literal, each in its own group.
  final RegExp? _literal;

  /// Redacts one payload. [collector] selects the argv rules for `procs`.
  RedactedPayload redact(String collector, List<int> payload) {
    final counts = <String, int>{};
    void count(String rule) => counts[rule] = (counts[rule] ?? 0) + 1;

    var text = _decode(payload);
    if (collector == Collector.procs.wireName) text = _redactArgv(text, count);
    if (collector == Collector.cron.wireName) {
      text = _asUtf8(text, (t) => _redactCron(t, count));
    }
    if (collector == Collector.units.wireName) text = _redactUnits(text, count);
    if (collector == Collector.fs.wireName) {
      text = text.replaceAllMapped(_mountSource, (m) {
        count('mount source');
        return '${m[1] ?? ''}${m[2] ?? ''}${m[3] ?? ''}$_serverPlaceholder';
      });
      text = text.replaceAllMapped(_mountUser, (m) {
        final r = '${m[1]}$_userPlaceholder@';
        if (r != m[0]) count('mount source');
        return r;
      });
    }
    text = _apply(text, _accountPatterns, count);
    if (_literal case final literal?) {
      text = text.replaceAllMapped(literal, (m) {
        final kind = _kindOf(m);
        final r = switch (kind) {
          _Literal.user => _ids.user(m[0]!),
          // Numbered by the last directory, its account in the usual case.
          _Literal.home => '/home/${_ids.user(m[0]!.split('/').last)}',
          _ => kind.replacement,
        };
        if (r != m[0]) count(kind.rule);
        return r;
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

    return RedactedPayload(_encode(_apply(text, _patterns, count)), counts);
  }

  String _apply(
    String text,
    List<_Rule> rules,
    void Function(String rule) count,
  ) {
    for (final (rule, re, replace) in rules) {
      text = text.replaceAllMapped(re, (m) {
        final r = replace(m, _ids);
        if (r != m[0]) count(rule);
        return r;
      });
    }
    return text;
  }

  /// The 1-based line numbers of [text], a file's bytes as Latin-1, that
  /// still hold a literal, a secret `SecretRedactor` would mask, or text
  /// no rule rewrites, each with the reason; empty when the text may be
  /// written.
  List<(int, String)> review(String text) {
    final findings = <(int, String)>[];
    final lines = _decode(latin1.encode(text)).split('\n');
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
  /// follow any systemd escape (`\x2d`, a space's `\x20`), and a
  /// non-ASCII byte also matches its own (`j\xc3\xbcrgen`).
  static String _literalPattern(_Literal kind, String value) {
    String byte(int b) => b < 0x80
        ? RegExp.escape(String.fromCharCode(b))
        : '(?:${String.fromCharCode(_byte + b)}|\\\\{1,2}x'
              '${b.toRadixString(16)})';
    final escaped = value
        .split('-')
        .map((part) => utf8.encode(part).map(byte).join())
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
/// and the blanks around it, then the value. `.` stops at a CR, so a
/// CRLF line is a job line to `parseCron`, and to this.
final _cronEnv = RegExp(r'^(\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*)(.*)$');

/// A trimmed crontab job line as `parseCron` splits it: its schedule (an
/// `@` macro or five fields), the blanks after it, then the rest.
final _cronJob = RegExp(
  r'^(@\S+|\S+\s+\S+\s+\S+\s+\S+\s+\S+)(\s+)(\S[\s\S]*)$',
);

/// What follows a system crontab's schedule: the user field, then the
/// command.
final _cronUser = RegExp(r'^(\S+)(\s+)(\S[\s\S]*)$');

/// The `crontab_meta` lines `parseCron` reads.
final _cronStatus = RegExp(r'^\s*(rc=-?\d+|tool=missing)\s*$');

/// A `cron_dirs` entry: `<period> <name>`.
final _cronDirEntry = RegExp(r'^\s*(hourly|daily|weekly|monthly) ');

/// Words of a cron command that stay wherever they stand: those
/// `mergeJobs` reads to find what runs the periodic directories
/// (`run-parts`, the directory, anacron). They are fixed, so no secret.
final _periodicWord = RegExp(
  r'^(?:(?:(?:/usr)?/s?bin/)?run-parts|'
  r'/etc/cron\.(?:hourly|daily|weekly|monthly)/?|'
  r'(?:(?:/usr)?/s?bin/|/etc/init\.d/)?anacron)$',
);

/// Rewrites a `cron` payload (03 §7.7) the way [_redactArgv] does
/// `procs`: a command carries the same secrets, user names and hosts as
/// an argv, and `parseCron` only keeps it as text. Each job keeps its
/// schedule, a user field of `root` (others read `user`), the first word
/// of its command when that is a program (no user field, or `root`) and
/// the [_periodicWord]s; comment text and environment values but
/// `CRON_TZ`, which jobs are evaluated in, read [kRedacted]. The blocks
/// are found as `parseCron` finds them; a line it reads as no job, entry
/// or status keeps no word. A failed `crontab -l` keeps its output, from
/// which `parseCron` reads "no crontab".
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
      _ => _cronLineText(line, (_) => kRedacted, count),
    });
  }
  return out.join('\n');
}

/// One crontab line, `parseCron`'s order: a comment, an environment
/// line, a job; [system] for the user field of `/etc/crontab` and
/// `/etc/cron.d`.
String _crontabLine(String line, bool system, void Function(String) count) {
  if (_cronEnv.firstMatch(line) case final env?) {
    if (env[2] == 'CRON_TZ' || env[3]!.trim().isEmpty) return line;
    count('cron text');
    return '${env[1]}$kRedacted';
  }
  return _cronLineText(line, (t) {
    if (t.startsWith('#')) return t == '#' ? t : '# $kRedacted';
    return _cronJobText(t, system, count);
  }, count);
}

/// [line] with its trimmed text rewritten by [rewrite]; the blanks
/// around it, a CR among them, stay.
String _cronLineText(
  String line,
  String Function(String text) rewrite,
  void Function(String rule) count,
) {
  final body = line.trimRight();
  final t = body.trimLeft();
  if (t.isEmpty) return line;
  final redacted = rewrite(t);
  if (redacted == t) return line;
  count('cron text');
  return '${body.substring(0, body.length - t.length)}$redacted'
      '${line.substring(body.length)}';
}

/// A trimmed job line [t] as `parseCron` splits it. A line too short for
/// a job keeps no word; so does a job whose schedule does not parse, but
/// it keeps its shape (five fields, a user field, a command), as
/// `parseCron` still lists it. A user field other than `root` may be a
/// command shifted left by a missing user field, so that job's command
/// keeps no first word.
String _cronJobText(String t, bool system, void Function(String) count) {
  final job = _cronJob.firstMatch(t);
  final macro = t.startsWith('@');
  if (macro && job == null) {
    return CronExpression.parse(t) == null ? '@$kRedacted' : t;
  }
  if (job == null ||
      !macro && t.split(RegExp(r'\s+')).length < (system ? 7 : 6)) {
    return kRedacted;
  }
  final schedule = macro ? job[1]! : job[1]!.split(RegExp(r'\s+')).join(' ');
  if (CronExpression.parse(schedule) == null) {
    return macro
        ? '@$kRedacted $kRedacted'
        : [
            for (var i = 0; i < 5; i++) kRedacted,
            if (system) _userPlaceholder,
            kRedacted,
          ].join(' ');
  }
  final head = '${job[1]}${job[2]}';
  if (!system) return '$head${_cronCommand(job[3]!, keepFirst: true)}';
  final field = _cronUser.firstMatch(job[3]!);
  if (field == null) return '$head$kRedacted';
  final root = field[1] == 'root';
  if (!root && field[1] != _userPlaceholder) count('user name');
  return '$head${root ? 'root' : _userPlaceholder}${field[2]}'
      '${_cronCommand(field[3]!, keepFirst: root)}';
}

/// [command] reduced to the first word if [keepFirst] (up to a `%`,
/// which starts the job's input, and without an assignment's value:
/// `PGPASSWORD=x pg_dump`) and the [_periodicWord]s, split on `;` as
/// `mergeJobs` splits them; each run of other words reads one
/// [kRedacted].
String _cronCommand(String command, {required bool keepFirst}) {
  final out = <String>[];
  void add(String word) {
    if (word != kRedacted || out.lastOrNull != kRedacted) out.add(word);
  }

  for (final (i, word) in command.trim().split(RegExp(r'\s+')).indexed) {
    if (i == 0 && keepFirst) {
      final percent = word.indexOf('%');
      final name = percent < 0 ? word : word.substring(0, percent);
      final eq = name.indexOf('=');
      if (name.isNotEmpty) {
        add(
          eq < 0 || eq == name.length - 1
              ? name
              : '${name.substring(0, eq + 1)}$kRedacted',
        );
      }
      if (percent >= 0) add(kRedacted);
    } else if (word
        .split(';')
        .every((w) => w.isEmpty || _periodicWord.hasMatch(w))) {
      add(word);
    } else {
      add(kRedacted);
    }
  }
  return out.join(' ');
}

/// One object of a `units_json` or `failed_json` array.
final _unitObject = RegExp(r'\{(?:[^{}"]|"(?:[^"\\]|\\.)*")*\}');

final _unitName = RegExp(r'"unit"\s*:\s*"((?:[^"\\]|\\.)*)"');

final _unitDescription = RegExp(r'("description"\s*:\s*")((?:[^"\\]|\\.)*)"');

/// A `units_text` or `failed_text` row: `UNIT LOAD ACTIVE SUB`, then the
/// description.
final _unitRow = RegExp(r'^(\s*(\S+)\s+\S+\s+\S+\s+\S+\s+)(\S.*)$');

/// The tag systemd-run puts before the command line it describes a
/// transient unit by since systemd 257 (`[systemd-run] `, `[run0] `).
final _runTag = RegExp(r'^\[[A-Za-z0-9_.-]+\] ');

/// Where a command line starts whose program systemd-run made absolute,
/// quoted since systemd 255 when it holds a blank, `\"` inside JSON.
final _absoluteProgram = RegExp(r'^(?:\\?")?/');

/// Rewrites the unit descriptions of a `units` payload (03 §7.5). A
/// transient unit that systemd-run started is described by its command
/// line (run.c), which keeps its first word, as an argv does; before
/// systemd 257 that line starts with the program's absolute path when
/// started locally, so every description starting with one does too (a
/// mount point keeps its first word). A device unit's description
/// appends the filesystem label or partition name to the model
/// (device.c), so it reads [kRedacted] whole.
String _redactUnits(String text, void Function(String rule) count) {
  String describe(String unit, String description) {
    final String kept;
    if (unit.endsWith('.device')) {
      kept = description.isEmpty ? description : kRedacted;
    } else if (_runTag.firstMatch(description) case final tag?) {
      kept = tag[0]! + _keepFirstWord(description.substring(tag.end));
    } else if (_absoluteProgram.hasMatch(description)) {
      kept = _keepFirstWord(description);
    } else {
      return description;
    }
    if (kept != description) count('unit description');
    return kept;
  }

  text = text.replaceAllMapped(_unitObject, (object) {
    final unit = _unitName.firstMatch(object[0]!)?[1];
    if (unit == null) return object[0]!;
    return object[0]!.replaceFirstMapped(
      _unitDescription,
      (d) => '${d[1]}${describe(unit, d[2]!)}"',
    );
  });
  var block = '';
  final out = <String>[];
  for (final line in text.split('\n')) {
    final header = _blockHeader.firstMatch(line.trim());
    if (header != null) block = header[1]!;
    // units_text and failed_text.
    final row = header == null && block.endsWith('_text')
        ? _unitRow.firstMatch(line)
        : null;
    out.add(row == null ? line : '${row[1]}${describe(row[2]!, row[3]!)}');
  }
  return out.join('\n');
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
