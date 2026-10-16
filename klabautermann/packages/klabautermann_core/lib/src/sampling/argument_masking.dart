/// Masking of a process's command line (03 §8.9, 7.2): the engine masks
/// every argument before a process row crosses to the app, so a secret
/// reaches it only behind [MaskedValue], whose display and `toString`
/// carry the mask and whose real text only the reveal action reads.
library;

import 'package:klabautermann_docker/klabautermann_docker.dart'
    show MaskedValue, isSecretKey, maskUrlCredentials;

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
/// a word of a `-c` line, ends at whitespace as the shell splits it, and
/// a `ps` row's value holding spaces is masked up to its first space
/// only. In each token:
///
/// - the value of `name=value` whose name matches 03 §8.9's key pattern
///   (`--password=`, `-Dapp.token=`, `API_TOKEN=`), also where the name
///   runs through an earlier `=`, as in `--env=DB_PASSWORD=<value>`;
/// - the attached value of `-p<value>`, as the MySQL clients take a
///   password, whatever the option means to its program;
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
  // The argument whose rest a value that starts it already masked.
  int? maskedArgument;
  for (final (argument, position, match) in tokens) {
    if (argument == maskedArgument) continue;
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

    final end = position == 0 ? arguments[argument].length : match.end;
    shown[argument].add((
      start: match.start,
      end: end,
      display: '$kept${MaskedValue.maskToken}',
    ));
    if (position == 0) maskedArgument = argument;
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

  // Each `=` before a non-empty value ends a candidate name, so a secret
  // assignment inside an option's value is found as well.
  var equals = token.indexOf('=', 1);
  while (equals != -1 && equals < token.length - 1) {
    final name = token.substring(0, equals);
    if (isSecretKey(name)) return '${maskUrlCredentials(name)}=';
    equals = token.indexOf('=', equals + 1);
  }
  if (token.length > 2 && token.startsWith('-p')) return '-p';
  return null;
}

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
