import 'ssh_config_settings.dart' show parseSshPort;

/// What ssh's `valid_domain()` accepts as an ssh URI's host, besides two
/// dots in a row: a letter or digit, then letters, digits, `.`, `-` and
/// `_`.
final RegExp _domain = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$');

/// A `%` that `urldecode()` cannot decode: one not followed by two hex
/// digits.
final RegExp _undecodablePercent = RegExp('%(?![0-9A-Fa-f]{2})');

/// What `isspace()` finds in the C locale.
const String _cWhitespace = ' \t\n\v\f\r';

/// Whether ssh's `parse_jump()` accepts a `ProxyJump` [value], the rest
/// of its line after the keyword and the whitespace and `=` that follow.
/// ssh checks every `ProxyJump` line so, in a block that applies or not,
/// and rejects the whole config over one it does not accept ("Invalid
/// ProxyJump"). As for `Port`, a service name other than `ssh`, `http`
/// and `https`, which ssh may resolve, counts as a port it rejects.
///
/// This is ssh's syntax alone; the route follower that consumes an
/// accepted value accepts fewer routes.
bool sshAcceptsProxyJump(String value) {
  if (value.toLowerCase() == 'none') return true;

  final hash = value.indexOf('#');
  var text = hash < 0 ? value : value.substring(0, hash);
  // rtrim() ends the value at each whitespace character after the first.
  for (var index = 1; index < text.length; index++) {
    if (_cWhitespace.contains(text[index])) {
      text = text.substring(0, index);
      break;
    }
  }
  return text
      .split(',')
      .every(
        (hop) => hop.startsWith('ssh://')
            ? _acceptsSshUri(hop.substring('ssh://'.length))
            : _acceptsUserHostPort(hop),
      );
}

/// Whether ssh's `parse_user_host_port()` reads [text]: a user before the
/// last `@` must not be empty, nor a host outside brackets, and a port
/// follows only a `:`.
bool _acceptsUserHostPort(String text) {
  final at = text.lastIndexOf('@');
  if (at == 0) return false;

  final rest = at < 0 ? text : text.substring(at + 1);
  final split = splitSshHost(rest);
  if (split == null || split.delimiter == '/') return false;
  if (split.host.isEmpty && !rest.startsWith('[')) return false;
  return split.rest.isEmpty || parseSshPort(split.rest) != null;
}

/// Whether ssh's `parse_ssh_uri()` reads [text], an ssh URI after
/// `ssh://`: a user before the first `@`, its `;` parameters dropped,
/// must not be empty and must decode, the host must be a domain name,
/// and no path may follow.
bool _acceptsSshUri(String text) {
  final at = text.indexOf('@');
  if (at >= 0) {
    final info = text.substring(0, at).split(';').first;
    if (info.isEmpty || _undecodablePercent.hasMatch(info)) return false;
  }

  final split = splitSshHost(at < 0 ? text : text.substring(at + 1));
  if (split == null ||
      !_domain.hasMatch(split.host) ||
      split.host.contains('..')) {
    return false;
  }
  if (split.delimiter != ':' || split.rest.isEmpty) return split.rest.isEmpty;

  final slash = split.rest.indexOf('/');
  final port = slash < 0 ? split.rest : split.rest.substring(0, slash);
  return parseSshPort(port) != null &&
      (slash < 0 || slash == split.rest.length - 1);
}

/// ssh's `hpdelim2()` and `cleanhostname()`: the host at the start of
/// [text], without brackets, the `:` or `/` after it (null at the end)
/// and what follows; null when a bracket is not closed or another
/// character follows it.
({String host, String? delimiter, String rest})? splitSshHost(String text) {
  final String host;
  final int end;
  if (text.startsWith('[')) {
    final close = text.indexOf(']');
    if (close < 0) return null;
    host = text.substring(1, close);
    end = close + 1;
  } else {
    final at = text.indexOf(RegExp('[:/]'));
    end = at < 0 ? text.length : at;
    host = text.substring(0, end);
  }

  if (end == text.length) return (host: host, delimiter: null, rest: '');
  final delimiter = text[end];
  if (delimiter != ':' && delimiter != '/') return null;
  return (host: host, delimiter: delimiter, rest: text.substring(end + 1));
}
