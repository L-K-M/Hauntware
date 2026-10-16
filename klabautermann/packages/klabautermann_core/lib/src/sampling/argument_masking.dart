/// Masking of a process's command line (03 §8.9, 7.2): the engine masks
/// every argument before a process row crosses to the app, so a secret
/// reaches it only behind [MaskedValue], whose display and `toString`
/// carry the mask and whose real text only the reveal action reads.
library;

import 'package:klabautermann_docker/klabautermann_docker.dart'
    show MaskedValue, isSecretKey, maskUrlCredentials;

/// A whitespace-delimited token inside one argument.
final _token = RegExp(r'\S+');

/// `name=value` with a non-empty value; the name ends at the first `=`.
final _assignment = RegExp(r'^([^=]+)=(.+)$');

/// An option without an attached value, such as `--password` or
/// `-passin`, whose value would be the next token.
final _option = RegExp(r'^--?([A-Za-z][A-Za-z0-9_.-]*)$');

/// Masks [arguments], one [MaskedValue] per argument, in order.
///
/// The rules work on whitespace tokens, which inside an argument split a
/// shell's `-c` command line and, for a `ps` fallback row, are the
/// arguments themselves (7.2); a value holding spaces is therefore masked
/// only up to its first space there. In each token:
///
/// - the value of `name=value` whose name matches 03 §8.9's key pattern
///   (`--password=`, `-Dapp.token=`, `API_TOKEN=`);
/// - the attached value of `-p<value>`, as the MySQL clients take a
///   password, whatever the option means to its program;
/// - URL credentials (`scheme://user:pass@`) anywhere else.
///
/// The token after an option whose name matches the key pattern
/// (`--password <value>`, `-passin <value>`) is masked whole, unless it
/// starts with `-` or the option is a `--no-` flag. The program, the very
/// first token, is never read as an option, so a login shell's `-bash`
/// stays as it is. Over-masking is the safe direction (`-print` shows as
/// `-p********`, `MONKEY=1` is masked): the reveal shows the real text.
List<MaskedValue> maskCommandLine(List<String> arguments) {
  final tokens = [
    for (final (index, argument) in arguments.indexed)
      for (final match in _token.allMatches(argument)) (index, match),
  ];
  final shown = [for (final _ in arguments) <(Match, String)>[]];
  var valueOfSecretOption = false;
  for (final (position, (argument, match)) in tokens.indexed) {
    final text = match[0]!;
    final program = position == 0 && argument == 0;
    final display = valueOfSecretOption && !text.startsWith('-')
        ? MaskedValue.maskToken
        : _maskToken(text, program: program);
    if (display != text) shown[argument].add((match, display));
    valueOfSecretOption = !program && _isSecretOption(text);
  }

  return [
    for (final (index, argument) in arguments.indexed)
      _masked(argument, shown[index]),
  ];
}

/// [token] with its secret parts masked; the rules are [maskCommandLine]'s.
String _maskToken(String token, {required bool program}) {
  if (!program) {
    final assignment = _assignment.firstMatch(token);
    if (assignment != null && isSecretKey(assignment[1]!)) {
      return '${maskUrlCredentials(assignment[1]!)}=${MaskedValue.maskToken}';
    }
    if (token.length > 2 && token.startsWith('-p')) {
      return '-p${MaskedValue.maskToken}';
    }
  }
  return maskUrlCredentials(token);
}

/// Whether [token] is an option whose value, the next token, is secret.
bool _isSecretOption(String token) {
  final name = _option.firstMatch(token)?[1];
  return name != null && !name.startsWith('no-') && isSecretKey(name);
}

/// [argument] with each of [shown]'s tokens replaced by its display.
MaskedValue _masked(String argument, List<(Match, String)> shown) {
  if (shown.isEmpty) return MaskedValue.plain(argument);
  if (shown case [
    (final match, MaskedValue.maskToken),
  ] when match.start == 0 && match.end == argument.length) {
    return MaskedValue.secret(argument);
  }

  final display = StringBuffer();
  var at = 0;
  for (final (match, text) in shown) {
    display
      ..write(argument.substring(at, match.start))
      ..write(text);
    at = match.end;
  }
  display.write(argument.substring(at));
  return MaskedValue.redacted(display.toString(), argument);
}
