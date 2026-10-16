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
/// stays as it is. Over-masking is the safe direction (`-print` shows as
/// `-p********`, `MONKEY=1` is masked, and so is the rest of a `-c` line
/// that starts with a secret assignment): the reveal shows the real text.
List<MaskedValue> maskCommandLine(List<String> arguments) {
  final tokens = [
    for (final (argument, text) in arguments.indexed)
      for (final (position, match) in _token.allMatches(text).indexed)
        (argument, position, match),
  ];
  final shown = [for (final _ in arguments) <_Shown>[]];
  var valueOfSecretOption = false;
  // Where the last masked value ends in its argument; the tokens before
  // that end belong to it.
  var maskedTo = (argument: -1, end: 0);
  for (final (argument, position, match) in tokens) {
    if (argument == maskedTo.argument && match.start < maskedTo.end) continue;
    final text = match[0]!;
    final program = argument == 0 && position == 0;
    final kept = valueOfSecretOption && !text.startsWith('-')
        ? ''
        : _keptBeforeValue(text, program: program);
    valueOfSecretOption = !program && _isSecretOption(text);
    if (kept == null) {
      final display = maskUrlCredentials(text);
      if (display != text) {
        shown[argument].add((
          start: match.start,
          end: match.end,
          display: display,
        ));
      }
      continue;
    }

    final whole = arguments[argument];
    final end = position == 0
        ? whole.length
        : _shellWordEnd(whole, match.start);
    shown[argument].add((
      start: match.start,
      end: end,
      display: '$kept${MaskedValue.maskToken}',
    ));
    maskedTo = (argument: argument, end: end);
  }

  return [
    for (final (index, argument) in arguments.indexed)
      _masked(argument, shown[index]),
  ];
}

/// The part of [token] shown before its secret value, which runs to the
/// token's end, or null when no value rule of [maskCommandLine] applies.
String? _keptBeforeValue(String token, {required bool program}) {
  if (program) return null;

  // An attached `-p` value goes first: read as `name=value`, a password
  // such as `-pmyAuth=xyz` would show all but its tail. `-password=x`
  // shows as `-p********` too.
  if (token.length > 2 && token.startsWith('-p')) return '-p';

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
const _blanks = {0x20, 0x09, 0x0A};
const _singleQuote = 0x27;
const _quotes = {_singleQuote, 0x22};
const _backslash = 0x5C;

/// Whether [token] is an option whose value, the next token, is secret.
bool _isSecretOption(String token) {
  final name = _option.firstMatch(token)?[1];
  return name != null && !name.startsWith('no-') && isSecretKey(name);
}

/// An argument's text from [start] to [end], shown as [display].
typedef _Shown = ({int start, int end, String display});

/// [argument] with each of [shown]'s spans replaced by its display.
MaskedValue _masked(String argument, List<_Shown> shown) {
  if (shown.isEmpty) return MaskedValue.plain(argument);
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
