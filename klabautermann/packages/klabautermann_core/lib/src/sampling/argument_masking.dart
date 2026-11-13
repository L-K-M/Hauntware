/// Masking of a process's command line (03 §8.9, 7.2): the engine masks
/// every argument before a process row crosses to the app, so a secret
/// reaches it only behind [MaskedValue], whose display and `toString`
/// carry the mask and whose real text only the reveal action reads.
library;

import 'package:klabautermann_docker/klabautermann_docker.dart'
    show MaskedValue, isSecretKey, maskUrlCredentials, secretKeyPattern;

/// A whitespace-delimited token inside one argument.
final _token = RegExp(r'\S+');

/// An option without an attached value, such as `--password` or
/// `-passin`, whose value would be the next token.
final _option = RegExp(r'^--?([A-Za-z][A-Za-z0-9_.-]*)$');

/// The most whitespace tokens the masking of one procs reading reads
/// (03 §8.9). A token costs up to about a microsecond in the engine
/// isolate, which every server shares, and a 1 MiB section can hold half
/// a million; past them every argument is masked whole, which the reveal
/// undoes.
const kArgumentTokensMasked = 1 << 16;

/// The tokens the masking of one procs reading may still read.
final class ArgumentMaskingBudget {
  ArgumentMaskingBudget([this._tokensLeft = kArgumentTokensMasked]);

  int _tokensLeft;
}

/// Masks [arguments], one [MaskedValue] per argument, in order.
///
/// The rules read whitespace tokens, which inside an argument split a
/// shell's `-c` command line and, for a `ps` fallback row, are the
/// arguments themselves (7.2). A secret value that starts an argument
/// runs to that argument's end, spaces included; one inside an argument,
/// a word of a `-c` line, runs to the end of that word as the shell reads
/// it, through quotes and escaped spaces, and a `ps` row's value holding
/// spaces is masked up to its first space only. In each token, the first
/// rule that applies:
///
/// - the attached value of `-p<value>`, as the MySQL clients take a
///   password, whatever the option means to its program;
/// - the value of `name=value` whose name matches 03 §8.9's key pattern
///   (`--password=`, `-Dapp.token=`, `API_TOKEN=`), also where the name
///   runs through an earlier `=`, as in `--env=DB_PASSWORD=<value>`;
/// - URL credentials (`scheme://user:pass@`) anywhere else.
///
/// The token after an option whose name matches the key pattern
/// (`--password <value>`, `-passin <value>`) is a value too, unless it
/// starts with `-` or the option is a `--no-` flag. The program, the very
/// first token, is never read as an option, so a login shell's `-bash`
/// stays as it is.
///
/// Known tools add their own options ([_knownTools]): the program, or a
/// later token named like one (`sudo curl`, a `-c` line's `curl`), starts
/// that tool's command, which runs to a shell separator (`;`, `|`, `&`,
/// or a newline outside quotes in the argument after a shell's `-c`).
/// Its secret options mask their value, separate or attached, whole or
/// in part (`curl -u user:********`, `-H 'Authorization:********'`),
/// and a `-p 8080` stays visible wherever the table does not name it.
///
/// Over-masking is the safe direction (`-print` shows as `-p********`,
/// `MONKEY=1` is masked, and so is the rest of a `-c` line that starts
/// with a secret assignment): the reveal shows the real text.
///
/// [budget], one per procs reading, bounds the tokens read, those inside
/// a masked value included: past it, the rest of the argument and every
/// later one are masked whole. A call without one gets its own.
List<MaskedValue> maskCommandLine(
  List<String> arguments, {
  ArgumentMaskingBudget? budget,
}) {
  final tokens = budget ?? ArgumentMaskingBudget();
  final reader = _CommandLineReader();
  final masked = <MaskedValue>[];
  for (final (index, whole) in arguments.indexed) {
    if (tokens._tokensLeft < 0) {
      masked.add(
        whole.isEmpty ? MaskedValue.plain(whole) : MaskedValue.secret(whole),
      );
      continue;
    }

    List<_Shown>? shown;
    // Where the last masked value ends; the tokens before it belong to it.
    var maskedTo = 0;
    var startsArgument = true;
    final line = index > 0 && _shellCommandOption.hasMatch(arguments[index - 1])
        ? _ShellLine(whole)
        : null;
    for (final match in _token.allMatches(whole)) {
      final first = startsArgument;
      startsArgument = false;
      tokens._tokensLeft--;
      if (match.start < maskedTo) continue;
      if (line != null && line.separatesBefore(match.start)) {
        reader._endCommand();
      }
      if (tokens._tokensLeft < 0) {
        (shown ??= []).add((
          start: match.start,
          end: whole.length,
          display: MaskedValue.maskToken,
        ));
        break;
      }

      final text = match[0]!;
      final kept = reader.read(text, program: index == 0 && first);
      if (kept == null) {
        final display = maskUrlCredentials(text);
        if (display != text) {
          (shown ??= []).add((
            start: match.start,
            end: match.end,
            display: display,
          ));
        }
        continue;
      }

      final end = first ? whole.length : _shellWordEnd(whole, match.start);
      if (!first) reader.wordEnded(whole, tokenEnd: match.end, end: end);
      // A quote the kept prefix opens (`-u 'me:a b'`) stays closed.
      final hiddenTo = !first && _closesQuote(kept, whole.codeUnitAt(end - 1))
          ? end - 1
          : end;
      // A value prefix with nothing after it (`curl -u me:`) hides nothing.
      if (hiddenTo > match.end ||
          kept != whole.substring(match.start, hiddenTo)) {
        (shown ??= []).add((
          start: match.start,
          end: hiddenTo,
          display: '$kept${MaskedValue.maskToken}',
        ));
      }
      if (end == whole.length) break;
      maskedTo = end;
    }
    masked.add(_masked(whole, shown));
  }
  return masked;
}

/// The part of [token] shown before its secret value, which runs to the
/// token's end, or null when no value rule of [maskCommandLine] applies.
String? _keptBeforeValue(String token) {
  // An attached `-p` value goes first: read as `name=value`, a password
  // such as `-pmyAuth=xyz` would show all but its tail. `-password=x`
  // shows as `-p********` too.
  if (token.length > 2 && token.startsWith('-p')) return '-p';
  if (!token.contains('=')) return null;

  // The name runs to the first `=` after the leftmost key match, so a
  // secret assignment inside an option's value is found as well. That
  // match ends first: no word of the pattern holds another but `PASS`,
  // which comes before `PASSWORD`. One match keeps this linear in a
  // token a host user may fill with 128 KiB of `a=`.
  if (secretKeyPattern.firstMatch(token) case final key?) {
    final equals = token.indexOf('=', key.end);
    if (equals != -1 && equals < token.length - 1) {
      return '${maskUrlCredentials(token.substring(0, equals))}=';
    }
  }
  return null;
}

/// Where the shell word of [text] that starts at [start] ends: at the
/// first space, tab or newline outside quotes, or at the text's end while
/// a quote is open. A backslash escapes the next character, except inside
/// single quotes.
int _shellWordEnd(String text, int start) {
  int? quote;
  for (var at = start; at < text.length; at++) {
    final unit = text.codeUnitAt(at);
    if (quote == null && _blanks.contains(unit)) return at;
    if (unit == _backslash && quote != _singleQuote) {
      at++;
    } else if (unit == quote) {
      quote = null;
    } else if (quote == null && _quotes.contains(unit)) {
      quote = unit;
    }
  }
  return text.length;
}

/// Space, tab and newline: what a shell splits words at.
const _blanks = {0x20, 0x09, _newline};
const _newline = 0x0A;
const _singleQuote = 0x27;
const _quotes = {_singleQuote, 0x22};
const _backslash = 0x5C;

/// Whether [kept], a prefix shown before a mask, leaves a quote open that
/// [last], the last character of the masked shell word, closes.
bool _closesQuote(String kept, int last) {
  int? quote;
  for (var at = 0; at < kept.length; at++) {
    final unit = kept.codeUnitAt(at);
    if (unit == _backslash && quote != _singleQuote) {
      at++;
    } else if (unit == quote) {
      quote = null;
    } else if (quote == null && _quotes.contains(unit)) {
      quote = unit;
    }
  }
  return quote != null && quote == last;
}

/// A shell's `-c` option, alone or ending a cluster (`-c`, `-ec`, `-lc`):
/// the argument after it is a command line.
final _shellCommandOption = RegExp(r'^-[A-Za-z]*c$');

/// The quoting of a `-c` line read so far, which tells a newline that
/// separates commands from one inside a quoted value.
final class _ShellLine {
  _ShellLine(this._text);

  final String _text;
  var _at = 0;
  int? _quote;

  /// Whether a newline outside quotes lies between the end of the last
  /// call's span and [to]. Each character is read once over all calls.
  bool separatesBefore(int to) {
    var separates = false;
    for (; _at < to; _at++) {
      final unit = _text.codeUnitAt(_at);
      if (unit == _backslash && _quote != _singleQuote) {
        _at++;
      } else if (unit == _quote) {
        _quote = null;
      } else if (_quote == null && _quotes.contains(unit)) {
        _quote = unit;
      } else if (_quote == null && unit == _newline) {
        separates = true;
      }
    }
    return separates;
  }
}

/// Whether [token] is an option whose value, the next token, is secret.
bool _isSecretOption(String token) {
  if (!token.startsWith('-')) return false;
  final name = _option.firstMatch(token)?[1];
  return name != null && !name.startsWith('no-') && isSecretKey(name);
}

/// An argument's text from [start] to [end], shown as [display].
typedef _Shown = ({int start, int end, String display});

/// [argument] with each of [shown]'s spans replaced by its display.
MaskedValue _masked(String argument, List<_Shown>? shown) {
  if (shown == null) return MaskedValue.plain(argument);
  if (shown case [
    (start: 0, :final end, display: MaskedValue.maskToken),
  ] when end == argument.length) {
    return MaskedValue.secret(argument);
  }

  final display = StringBuffer();
  var at = 0;
  for (final (:start, :end, display: text) in shown) {
    display
      ..write(argument.substring(at, start))
      ..write(text);
    at = end;
  }
  display.write(argument.substring(at));
  return MaskedValue.redacted(display.toString(), argument);
}

/// Reads a command line's tokens in order for [maskCommandLine]: which
/// known tool's command they belong to and whether a token is the value
/// of the option before it.
final class _CommandLineReader {
  /// The known tool's command being read, or null outside one.
  _Command? _command;

  /// The shape of the next token, the value of the option just read.
  _Value? _pending;

  /// Whether [_pending] came from the key pattern alone, so that a next
  /// token starting with `-` is an option rather than its value.
  var _pendingYieldsToOption = false;

  /// Whether the last token read was a secret header's name and colon
  /// with its value still to come.
  var _headerNameOnly = false;

  /// Whether [_pending] is a secret header's value.
  var _pendingIsHeader = false;

  /// Whether the last token read ended with a secret header's value that
  /// is an auth scheme alone (`Bearer`), its credential still to come.
  var _headerSchemeOnly = false;

  /// The part of [text] shown before its secret value, as
  /// [_keptBeforeValue] answers it, with the known tools' rules first.
  String? read(String text, {required bool program}) {
    _headerNameOnly = false;
    _headerSchemeOnly = false;
    final kept = _read(text, program: program);
    if (_endsCommand(text.codeUnitAt(text.length - 1))) _endCommand();
    return kept;
  }

  /// The value whose prefix [read] kept from a token that ends at
  /// [tokenEnd] of [text] runs to [end], the end of its shell word.
  void wordEnded(String text, {required int tokenEnd, required int end}) {
    // `-H Authorization: Bearer x` in a ps fallback row or unquoted in a
    // `-c` line: the value is the next token, and after a scheme the one
    // after it, as far as it can be told.
    if (end == tokenEnd && (_headerNameOnly || _headerSchemeOnly)) {
      _pending = _Value.whole;
      _pendingIsHeader = _headerNameOnly;
    }
    if (end > tokenEnd && _endsCommand(text.codeUnitAt(end - 1))) {
      _endCommand();
    }
  }

  String? _read(String text, {required bool program}) {
    if (program) {
      _command = _Command.named(text);
      return null;
    }

    final pending = _pending;
    final yieldsToOption = _pendingYieldsToOption;
    final isHeader = _pendingIsHeader;
    _pending = null;
    _pendingYieldsToOption = false;
    _pendingIsHeader = false;
    if (pending != null && !(yieldsToOption && text.startsWith('-'))) {
      if (isHeader) _headerSchemeOnly = _isAuthScheme(text);
      return _keptOfValue(text, pending) ?? _keptBeforeValue(text);
    }

    if (text.length > 1 && text.startsWith('-')) return _readOption(text);
    return _readOperand(text);
  }

  String? _readOption(String text) {
    final option = _command?.option(text);
    if (option?.next case final next?) {
      _pending = next;
    } else if (_isSecretOption(text)) {
      _pending = _Value.whole;
      _pendingYieldsToOption = true;
    }

    if (option == null) return _keptBeforeValue(text);
    // An attached value the tool's rule leaves visible may still hold a
    // secret assignment (`--header=X-Q: token=abc`); a bare option name
    // holds no value at all.
    if (option.attached case final attached?) {
      final kept = _keptOfValue(attached.value, option.shape);
      if (kept != null) return '${attached.name}$kept';
      return _keptBeforeValue(text);
    }
    return null;
  }

  String? _readOperand(String text) {
    if (_command case final command?) {
      final tool = command.tool;
      final position = ++command.operands;
      final subcommand = position == 1 ? tool.subcommands[text] : null;
      if (subcommand != null) {
        _command = _Command(subcommand);
        return null;
      }
      if (position == tool.commandOperand) {
        _command = _Command.named(text);
        return _keptBeforeValue(text);
      }
      if (position == tool.secretOperand?.call(command.letters)) return '';
      if (tool.headerOperands) {
        if (_keptOfHeader(text) case final kept?) return kept;
      }
    }

    // An operand named like the tool being read is its own file
    // (`htpasswd -b /etc/htpasswd`), not a new command.
    if (_Command.named(text) case final named?
        when !identical(named.tool, _command?.tool)) {
      _command = named;
    }
    return _keptBeforeValue(text);
  }

  void _endCommand() {
    _command = null;
    _pending = null;
    _pendingYieldsToOption = false;
    _pendingIsHeader = false;
  }

  /// The part of [value] shown before its secret part, for an option
  /// value of [shape], or null when it holds no secret by that shape.
  String? _keptOfValue(String value, _Value shape) => switch (shape) {
    _Value.whole => '',
    _Value.afterColon => _keptThrough(value, ':', hiddenWithout: false),
    _Value.afterColonOrWhole => _keptThrough(value, ':', hiddenWithout: true),
    _Value.afterPercent => _keptThrough(value, '%', hiddenWithout: false),
    _Value.header => _keptOfHeader(value),
    _Value.notSecret => null,
  };

  /// The name and colon of a secret header (`Authorization: Bearer x`),
  /// after any opening quotes, or null for another header or none.
  String? _keptOfHeader(String value) {
    var start = 0;
    while (start < value.length && _quotes.contains(value.codeUnitAt(start))) {
      start++;
    }
    final colon = value.indexOf(':', start);
    if (colon == -1) {
      // `-H 'Authorization : x'`: a blank before the colon ends the token
      // at the name, so what follows it in the shell word or argument is
      // the value.
      return _isSecretHeader(value.substring(start)) ? value : null;
    }
    if (colon == start) return null;
    if (!_isSecretHeader(value.substring(start, colon))) return null;

    _headerNameOnly = colon == value.length - 1;
    _headerSchemeOnly = _isAuthScheme(value.substring(colon + 1));
    return value.substring(0, colon + 1);
  }
}

/// [value] through its first [separator], or the empty prefix (the whole
/// value hidden) when it has none and [hiddenWithout] holds.
String? _keptThrough(
  String value,
  String separator, {
  required bool hiddenWithout,
}) {
  final at = value.indexOf(separator);
  if (at == -1) return hiddenWithout ? '' : null;
  return value.substring(0, at + 1);
}

/// Whether a token or shell word that ends in [unit] ends a shell
/// command (`;`, `|`, `&`, so also `&&` and `||`).
bool _endsCommand(int unit) => unit == 0x3B || unit == 0x7C || unit == 0x26;

/// Header names whose value is a credential, in lower case.
const _secretHeaders = {
  'authorization',
  'proxy-authorization',
  'cookie',
  'set-cookie',
};

/// Name endings of headers that carry a credential by convention
/// (`X-Auth-Token`, `Private-Token`, `X-Api-Key`, `X-Client-Secret`).
const _secretHeaderEndings = ['-token', '-key', '-secret', '-auth'];

/// Whether a header named [name] carries a credential.
bool _isSecretHeader(String name) {
  final lower = name.toLowerCase();
  return _secretHeaders.contains(lower) ||
      _secretHeaderEndings.any(lower.endsWith) ||
      lower.contains('api-key');
}

/// HTTP authentication schemes in lower case, from the IANA registry and
/// common APIs (`Token`, `Bot`), which come before the credential. A
/// doubtful word is listed: masking one more token is the safe direction.
const _authSchemes = {
  'basic',
  'bearer',
  'digest',
  'dpop',
  'gnap',
  'hoba',
  'mutual',
  'negotiate',
  'ntlm',
  'oauth',
  'privatetoken',
  'scram-sha-1',
  'scram-sha-256',
  'vapid',
  'aws4-hmac-sha256',
  'token',
  'bot',
  'apikey',
  'key',
  'sso-key',
  'ssws',
  'splunk',
};

/// Whether [word] is an auth scheme alone, its credential still to come.
bool _isAuthScheme(String word) =>
    word.length <= _longestAuthScheme &&
    _authSchemes.contains(word.toLowerCase());

/// The length of the longest of [_authSchemes].
const _longestAuthScheme = 16;

/// Which part of an option's value is secret.
enum _Value {
  /// All of it.
  whole,

  /// What follows the first `:` (`user:password`, `cert:passphrase`);
  /// without one the value names a user or a file and stays visible.
  afterColon,

  /// What follows the first `:` (`pass:<secret>`, `env:<name>`); without
  /// one, all of it, as a bearer token is.
  afterColonOrWhole,

  /// What follows the first `%` (Samba's `user%password`); without one
  /// the value names a user and stays visible.
  afterPercent,

  /// A header's value, when its name is secret ([_isSecretHeader]).
  header,

  /// None of it: the option takes a value that is not a secret, read so
  /// that it does not count as an operand.
  notSecret,
}

/// The secret options of a known tool and how its operands are read.
final class _Tool {
  const _Tool(
    this.options, {
    this.getopt = true,
    this.subcommands = const {},
    this.commandOperand,
    this.secretOperand,
    this.headerOperands = false,
  });

  /// Options by name (`-u`, `--user`) and which part of their value is
  /// secret. An option whose name holds a key word of 03 §8.9's pattern
  /// (`--password`, `-token`) is masked without an entry here.
  final Map<String, _Value> options;

  /// Whether the tool reads short options as getopt does: clustered
  /// (`-su`) and with attached values (`-uuser:pass`). OpenSSL and Go
  /// tools take single-dash long options instead.
  final bool getopt;

  /// Subcommands with options of their own, named by the first operand.
  final Map<String, _Tool> subcommands;

  /// The operand, counted from 1, that starts the command the tool runs.
  final int? commandOperand;

  /// The operand, counted from 1, that is a secret, given the short
  /// option letters read so far; null when none is.
  final int? Function(Set<String> letters)? secretOperand;

  /// Whether operands of the form `Name:value` are request headers.
  final bool headerOperands;

  /// The longest name of a known tool, which bounds the scan for one.
  static const longestName = 16;
}

/// Known tools that take a secret as an option's separate value or in a
/// form the key pattern does not catch, by the program's base name.
/// Over-masking is the safe direction, so a doubtful option is listed.
const Map<String, _Tool> _knownTools = {
  // `-p` is the SSH password; the command it runs follows its own
  // options, so that command's `ssh -p 22` stays visible.
  'sshpass': _Tool({
    '-p': _Value.whole,
    '-f': _Value.notSecret,
    '-d': _Value.notSecret,
    '-P': _Value.notSecret,
  }, commandOperand: 1),
  'curl': _curl,
  // `--password`, `--http-password` and `--ftp-password` match the key
  // pattern; headers carry tokens.
  'wget': _Tool({'--header': _Value.header}),
  'http': _httpie,
  'https': _httpie,
  'httpie': _httpie,
  'xh': _httpie,
  'xhs': _httpie,
  // `-a` is the password (`-p` is the port); redis-cli reads only
  // separate values.
  'redis-cli': _Tool({'-a': _Value.whole}, getopt: false),
  // `-p` is the password (`--port` is the port).
  'mongo': _mongoShell,
  'mongosh': _mongoShell,
  // `-b` takes the password as the last operand: after the file and the
  // user, or after the user alone with `-n`, which writes no file.
  'htpasswd': _Tool({
    '-C': _Value.notSecret,
    '-r': _Value.notSecret,
  }, secretOperand: _htpasswdPassword),
  // Pass phrase arguments name their source (`pass:`, `env:`, `file:`),
  // which stays visible; `enc -k` is the password itself.
  'openssl': _Tool({
    '-pass': _Value.afterColonOrWhole,
    '-passin': _Value.afterColonOrWhole,
    '-passout': _Value.afterColonOrWhole,
    '-k': _Value.whole,
  }, getopt: false),
  // Samba's `-U user%password`.
  'smbclient': _samba,
  'rpcclient': _samba,
  // `login -p` is the registry password; global options that take a
  // value are listed so that the subcommand is found after them, and
  // `run -p 8080:80` stays visible.
  'docker': _Tool(
    {
      '-H': _Value.notSecret,
      '--host': _Value.notSecret,
      '-c': _Value.notSecret,
      '--context': _Value.notSecret,
      '--config': _Value.notSecret,
      '-l': _Value.notSecret,
      '--log-level': _Value.notSecret,
    },
    subcommands: {'login': _registryLogin},
  ),
  'podman': _Tool(
    {
      '-c': _Value.notSecret,
      '--connection': _Value.notSecret,
      '--url': _Value.notSecret,
      '--root': _Value.notSecret,
      '--runroot': _Value.notSecret,
    },
    subcommands: {'login': _registryLogin},
  ),
};

/// curl: `user:password` for the server and the proxy, a client
/// certificate's `file:passphrase`, headers, and cookies (a cookie string
/// or a file name, which over-masks). `--pass` and `--oauth2-bearer`
/// match the key pattern.
const _curl = _Tool({
  '-u': _Value.afterColon,
  '--user': _Value.afterColon,
  '-U': _Value.afterColon,
  '--proxy-user': _Value.afterColon,
  '-E': _Value.afterColon,
  '--cert': _Value.afterColon,
  '--proxy-cert': _Value.afterColon,
  '-H': _Value.header,
  '--header': _Value.header,
  '--proxy-header': _Value.header,
  '-b': _Value.whole,
  '--cookie': _Value.whole,
});

/// HTTPie and xh: `-a user:password` or a bearer token, and `Name:value`
/// header operands.
const _httpie = _Tool({
  '-a': _Value.afterColonOrWhole,
  '--auth': _Value.afterColonOrWhole,
}, headerOperands: true);

const _mongoShell = _Tool({'-p': _Value.whole}, getopt: false);

const _samba = _Tool({
  '-U': _Value.afterPercent,
  '--user': _Value.afterPercent,
});

/// `docker login` and `podman login`: `-p` is the registry password.
const _registryLogin = _Tool({
  '-p': _Value.whole,
  '--password': _Value.whole,
  '-u': _Value.notSecret,
  '--username': _Value.notSecret,
});

int? _htpasswdPassword(Set<String> letters) {
  if (!letters.contains('b')) return null;
  return letters.contains('n') ? 2 : 3;
}

/// A known tool's command being read.
final class _Command {
  _Command(this.tool);

  /// The command of the known tool [token] names by its base name, after
  /// any path, quote, `$(`, backquote or `=` before it, or null when it
  /// names none.
  static _Command? named(String token) {
    var start = token.length;
    while (start > 0 &&
        !_nameDelimiters.contains(token.codeUnitAt(start - 1))) {
      start--;
      if (token.length - start > _Tool.longestName) return null;
    }
    final tool = _knownTools[token.substring(start)];
    return tool == null ? null : _Command(tool);
  }

  final _Tool tool;

  /// The operands read so far.
  var operands = 0;

  /// The short option letters read so far, for [_Tool.secretOperand].
  final letters = <String>{};

  /// How [tool] reads [token], an option, or null when it names none of
  /// [_Tool.options].
  _OptionRead? option(String token) {
    if (tool.options[token] case final shape?) {
      return (shape: shape, next: shape, attached: null);
    }

    if (token.startsWith('--')) {
      final equals = token.indexOf('=');
      if (equals == -1) return null;
      final name = token.substring(0, equals);
      final shape = tool.options[name];
      if (shape == null) return null;
      return (
        shape: shape,
        next: null,
        attached: (name: '$name=', value: token.substring(equals + 1)),
      );
    }
    if (!tool.getopt) return null;

    // A cluster of short options; the first one the table names takes
    // the rest of the token, or the next token, as its value.
    for (var at = 1; at < token.length; at++) {
      final unit = token.codeUnitAt(at);
      if (!_isAlphanumeric(unit)) return null;
      final letter = String.fromCharCode(unit);
      letters.add(letter);
      final shape = tool.options['-$letter'];
      if (shape == null) continue;
      if (at == token.length - 1) {
        return (shape: shape, next: shape, attached: null);
      }
      return (
        shape: shape,
        next: null,
        attached: (
          name: token.substring(0, at + 1),
          value: token.substring(at + 1),
        ),
      );
    }
    return null;
  }
}

/// A known tool's option: its value's [shape], the [next] token's shape
/// when the value is separate, or the [attached] value and the text
/// before it.
typedef _OptionRead = ({
  _Value shape,
  _Value? next,
  ({String name, String value})? attached,
});

/// What may come right before a program's name in a token: a path's `/`,
/// quotes, `(` of `$(`, a backquote, or the `=` of an assignment.
const _nameDelimiters = {0x2F, 0x22, 0x27, 0x28, 0x60, 0x3D};

bool _isAlphanumeric(int unit) =>
    (unit >= 0x30 && unit <= 0x39) ||
    (unit >= 0x41 && unit <= 0x5A) ||
    (unit >= 0x61 && unit <= 0x7A);
