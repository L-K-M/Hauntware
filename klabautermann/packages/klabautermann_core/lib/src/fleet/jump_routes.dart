import 'dart:io' show InternetAddress;

import 'package:seance_core/seance_core.dart' show ImportedHost;

import '../engine/protocol.dart' show kSshDefaultPort;

/// Prefixes a [JumpHop.id]. Import ids are `ssh-config:<alias>` and synced
/// ids bare UUIDs, so a hop id collides with neither.
const String _hopIdPrefix = 'ssh-config-hop:';

/// The most hops a route may have: Séance's connector refuses a longer one
/// (`_maxJumpHosts` in seance_core's `ssh_session.dart`), so the engine
/// never imports a route it could not dial.
const int _maxJumpHops = 16;

/// A decimal TCP port, as the engine reads one in a `ProxyJump`.
final RegExp _decimal = RegExp(r'^[0-9]+$');

/// What ssh's `valid_domain()` accepts as an ssh URI's host: a letter,
/// digit or `_`, then letters, digits, `.`, `-` and `_`.
final RegExp _domain = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]*$');

/// The characters, besides whitespace and control characters, that ssh's
/// `valid_hostname()` rejects; the shell that runs the hops reads them.
const String _shellCharacters = '\'`"\$\\;&<>|(){}';

/// One jump host on an imported server's route (03 §10.1): the hop as its
/// `ProxyJump` names it and the endpoint ssh would dial for it.
final class JumpHop {
  const JumpHop._({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    this.user,
    this.identityFile,
    required this._written,
  });

  /// `ssh-config-hop:` and the names of the route up to and including this
  /// hop, joined by commas: the same config gives the same ids on every
  /// import and start, and servers that share the start of a route share
  /// its hops.
  final String id;

  /// The hop as written: an alias, `[user@]host[:port]` or an ssh URI.
  final String name;

  /// The address to dial: the `HostName` of the host or hop record
  /// [name] names, else the host [name] gives.
  final String host;

  final int port;

  /// The hop's own user, else the record's `User`; null leaves the login
  /// name to the local account, as for a host without `User`.
  final String? user;

  /// The record's `IdentityFile`, as written; null signs in with the
  /// agent.
  final String? identityFile;

  /// The hop as [name] gives it, which ssh compares with the next host to
  /// catch a loop.
  final _Hop _written;
}

/// The jump route of each of [hosts], keyed by alias: its hops, first hop
/// first, empty for a direct connection, or null when the engine cannot
/// follow its `ProxyJump` the way ssh would. [hosts] holds one host per
/// alias, and [hops] the settings ssh would use for each other name a
/// route gives, keyed by that name as the alias; [leftOut] names hosts
/// and hop names of the config that are in neither.
///
/// What ssh does, and so what this does (ssh_config(5) and OpenSSH's
/// `parse_jump()` and `ssh.c`): a `ProxyJump` of `a,b` dials `a`, then `b`
/// through `a`, then the host through `b`, and `none` means direct. ssh
/// reaches each hop with a nested ssh that reads the config for the hop's
/// name, so a hop takes the `HostName`, `Port`, `User` and `IdentityFile`
/// of the host or hop record its name gives (exactly, as `Host` patterns
/// match), with the hop's own user and port first; a name with neither
/// is dialed as written. Only the first hop's own `ProxyJump` applies:
/// the nested ssh for every later hop gets the hops before it with `-J`,
/// which overrides the hop's own.
///
/// A host's route is null when its `ProxyJump`:
///
/// - is one ssh rejects, or names a port other than a decimal 1 to 65535
///   (ssh also resolves service names);
/// - has a hop whose user or host holds whitespace, a quote or another
///   character the shell reads, or starts with `-`, or a hop before the
///   last that holds such a character as written: ssh runs the route as
///   a `ProxyCommand` through `/bin/sh`, putting the last hop's user and
///   host in it and the hops before as written, and the nested ssh
///   rejects such a host name or reads it as an option;
/// - has a `#` comment holding a comma: ssh hands the hops before the
///   last on from the value as written, up to its last comma, so the
///   comment reaches the shell;
/// - contains `%`, which ssh expands as a token (ssh_config(5), TOKENS);
/// - loops back through first hops to a host already on the way;
/// - has a hop, as written, that is the host or hop it leads to, which
///   ssh refuses as a jumphost loop (see [_isJumpLoop]);
/// - makes a route of more than 16 hops, the first hop's own route
///   included, which Séance's connector refuses to dial;
/// - names a host in [leftOut], or one whose own route is null: ssh would
///   take that host's settings, or as a first hop its route, from what
///   the engine cannot evaluate or follow. This holds for a later hop
///   too, although ssh ignores a later hop's own route: a hop left out
///   only for its `ProxyCommand`, its `ProxyJump` or a `Match` that could
///   set its route leaves out every host behind it, where ssh would
///   still reach them. That is conservative, not what ssh does.
///
/// The work is linear in the hosts: following a route stops past 16 hops,
/// and each null route reaches the hosts that name it once.
Map<String, List<JumpHop>?> jumpRoutes(
  List<ImportedHost> hosts, {
  List<ImportedHost> hops = const [],
  Set<String> leftOut = const {},
}) {
  final named = [...hosts, ...hops];
  final byAlias = {for (final host in named) host.alias: host};
  final parsed = {
    for (final host in named)
      host.alias: switch (host.proxyJump) {
        null => const <_Hop>[],
        final value => _parseProxyJump(value),
      },
  };

  // The route of [host] in at most [limit] hops, or null. [visiting] holds
  // the hosts whose first hop led here, to catch a loop.
  List<JumpHop>? follow(ImportedHost host, Set<String> visiting, int limit) {
    final own = parsed[host.alias];
    if (own == null || own.length > limit) return null;

    final route = <JumpHop>[];
    for (final (index, (:name, :user, host: hopHost, :port)) in own.indexed) {
      if (leftOut.contains(hopHost)) return null;

      final alias = byAlias[hopHost];
      if (index == 0 && alias != null) {
        if (!visiting.add(alias.alias)) return null;

        // ssh reaches the first hop through its own ProxyJump, so that
        // route comes first and leaves room for this host's hops.
        final upstream = follow(alias, visiting, limit - own.length);
        if (upstream == null) return null;
        route.addAll(upstream);
      }

      final previous = route.lastOrNull;
      final hop = JumpHop._(
        id: previous == null ? '$_hopIdPrefix$name' : '${previous.id},$name',
        name: name,
        host: alias?.effectiveHost ?? hopHost,
        port: port ?? alias?.port ?? kSshDefaultPort,
        user: user ?? alias?.user,
        identityFile: alias?.identityFile,
        written: own[index],
      );
      if (previous != null &&
          _isJumpLoop(previous._written, hop.host, hop.port, hop.user)) {
        return null;
      }
      route.add(hop);
    }
    return List.unmodifiable(route);
  }

  // A hop record's own last hop is checked where a route reaches it as a
  // first hop, with that route's user and port.
  final routes = {
    for (final hop in hops) hop.alias: follow(hop, {hop.alias}, _maxJumpHops),
    for (final host in hosts)
      host.alias: switch (follow(host, {host.alias}, _maxJumpHops)) {
        final route?
            when route.isNotEmpty &&
                _isJumpLoop(
                  route.last._written,
                  host.effectiveHost,
                  host.port ?? kSshDefaultPort,
                  host.user,
                ) =>
          null,
        final route => route,
      },
  };

  // A host whose route is null is left out, so every route that names it
  // is null too, and so on. Following who names whom reaches each host
  // once, however long the chain.
  final namedBy = <String, List<String>>{};
  for (final MapEntry(key: alias, value: own) in parsed.entries) {
    for (final hop in own ?? const <_Hop>[]) {
      (namedBy[hop.host] ??= []).add(alias);
    }
  }
  final failed = [
    for (final MapEntry(:key, :value) in routes.entries)
      if (value == null) key,
  ];
  while (failed.isNotEmpty) {
    for (final alias in namedBy[failed.removeLast()] ?? const <String>[]) {
      if (routes[alias] == null) continue;

      routes[alias] = null;
      failed.add(alias);
    }
  }
  return {for (final host in hosts) host.alias: routes[host.alias]};
}

/// The name each hop of a `ProxyJump` [value] gives, as [jumpRoutes] looks
/// it up: empty for `none`, null when the engine cannot read [value].
List<String>? proxyJumpHosts(String value) => switch (_parseProxyJump(value)) {
  null => null,
  final hops => [for (final hop in hops) hop.host],
};

typedef _Hop = ({String name, String? user, String host, int? port});

/// Whether ssh refuses to reach [host] on [port] as [user] through the
/// [jump] before it (`ssh.c`: "jumphost loop"): the jump's host as
/// written is [host], its port, else 22, is [port], and its user, else
/// [user], is [user]. ssh writes an address it dials in canonical form,
/// so addresses compare by value. A jump with its own user, to a host
/// whose user is the local account's, which the import does not know,
/// counts as a loop.
bool _isJumpLoop(_Hop jump, String host, int port, String? user) {
  if ((jump.port ?? kSshDefaultPort) != port) return false;
  if (jump.user != null && user != null && jump.user != user) return false;
  if (jump.host == host) return true;

  final (written, dialed) = (
    InternetAddress.tryParse(jump.host),
    InternetAddress.tryParse(host),
  );
  if (written == null || dialed == null) return false;

  final (a, b) = (written.rawAddress, dialed.rawAddress);
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

/// The hops a `ProxyJump` [value] names, first hop first: empty for
/// `none`, null when ssh would reject it or the engine cannot read it.
List<_Hop>? _parseProxyJump(String value) {
  // ssh compares the whole value with `none`, then drops a `#` comment and
  // trailing whitespace before it splits the hops.
  if (value.toLowerCase() == 'none') return const [];

  final hash = value.indexOf('#');
  // It cuts the hops it hands the nested ssh with `-J` from the value as
  // written, at its last comma, so a comma in the comment carries the
  // comment into the command /bin/sh runs.
  if (hash >= 0 && value.contains(',', hash)) return null;
  final text = (hash < 0 ? value : value.substring(0, hash)).trimRight();
  if (text.contains('%')) return null;

  final names = text.split(',');
  final hops = <_Hop>[];
  for (final (index, name) in names.indexed) {
    // ssh hands the hops before the last to the nested ssh with `-J`, as
    // written, and only the last one's user and host as parsed.
    if (index < names.length - 1 && !_isShellWord(name)) return null;

    final hop = name.startsWith('ssh://')
        ? _parseSshUri(name.substring('ssh://'.length))
        : _parseUserHostPort(name);
    if (hop == null ||
        !_isShellWord(hop.host) ||
        hop.host.startsWith('-') ||
        !_isShellWord(hop.user ?? '') ||
        (hop.user?.startsWith('-') ?? false)) {
      return null;
    }
    hops.add((name: name, user: hop.user, host: hop.host, port: hop.port));
  }
  return hops;
}

/// Whether [text] holds no whitespace, control character or
/// [_shellCharacters], so the shell reads it as written.
bool _isShellWord(String text) => !text.codeUnits.any(
  (c) => c <= 0x20 || c == 0x7f || _shellCharacters.codeUnits.contains(c),
);

/// `[user@]host[:port]` as ssh's `parse_user_host_port()` reads it: the
/// user ends at the last `@`, and a host in brackets may hold colons.
({String? user, String host, int? port})? _parseUserHostPort(String text) {
  String? user;
  var rest = text;
  final at = text.lastIndexOf('@');
  if (at >= 0) {
    if (at == 0) return null;
    user = text.substring(0, at);
    rest = text.substring(at + 1);
  }

  final split = _splitHost(rest);
  if (split == null || split.host.isEmpty || split.delimiter == '/') {
    return null;
  }
  if (split.rest.isEmpty) return (user: user, host: split.host, port: null);

  final port = _port(split.rest);
  return port == null ? null : (user: user, host: split.host, port: port);
}

/// An ssh URI after `ssh://`, as ssh's `parse_ssh_uri()` reads it: the
/// user ends at the first `@` and drops `;` parameters, the host must be a
/// domain name or IPv4 address, and no path may follow. The value holds no
/// `%` by now, so decoding the user only turns `+` into a space.
({String? user, String host, int? port})? _parseSshUri(String text) {
  String? user;
  var rest = text;
  final at = text.indexOf('@');
  if (at >= 0) {
    final info = text.substring(0, at).split(';').first;
    if (info.isEmpty) return null;
    user = info.replaceAll('+', ' ');
    rest = text.substring(at + 1);
  }

  final split = _splitHost(rest);
  if (split == null ||
      !_domain.hasMatch(split.host) ||
      split.host.contains('..')) {
    return null;
  }

  var path = split.rest;
  int? port;
  if (split.delimiter == ':' && path.isNotEmpty) {
    final slash = path.indexOf('/');
    port = _port(slash < 0 ? path : path.substring(0, slash));
    if (port == null) return null;
    path = slash < 0 ? '' : path.substring(slash + 1);
  }
  if (path.isNotEmpty) return null;

  // ssh drops one trailing dot from the host.
  final host = split.host.endsWith('.')
      ? split.host.substring(0, split.host.length - 1)
      : split.host;
  return (user: user, host: host, port: port);
}

/// ssh's `hpdelim2()` and `cleanhostname()`: the host at the start of
/// [text], without brackets, the `:` or `/` after it (null at the end)
/// and what follows; null when a bracket is not closed or another
/// character follows it.
({String host, String? delimiter, String rest})? _splitHost(String text) {
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

/// A decimal port in the TCP range 1 to 65535, or null.
int? _port(String text) {
  if (!_decimal.hasMatch(text)) return null;

  final port = int.tryParse(text);
  return port == null || port < 1 || port > 65535 ? null : port;
}
