import 'package:seance_core/seance_core.dart' show ImportedHost;

import '../engine/protocol.dart' show kSshDefaultPort;
import 'ssh_config_settings.dart'
    show looksLikeSshAddress, parseSshPort, sshCanonicalHost;

/// Prefixes a [JumpHop.id]. Import ids are `ssh-config:<alias>` and synced
/// ids bare UUIDs, so a hop id collides with neither.
const String _hopIdPrefix = 'ssh-config-hop:';

/// The most hops a route may have: Séance's connector refuses a longer one
/// (`_maxJumpHosts` in seance_core's `ssh_session.dart`), so the engine
/// never imports a route it could not dial.
const int _maxJumpHops = 16;

/// A decimal TCP port, as the engine reads one in a `ProxyJump`.
final RegExp _decimal = RegExp(r'^[0-9]+$');

/// What ssh's `valid_domain()` accepts as an ssh URI's host, besides two
/// dots in a row: a letter or digit, then letters, digits, `.`, `-` and
/// `_`.
final RegExp _domain = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$');

/// A `%` that `urldecode()` cannot decode: one not followed by two hex
/// digits.
final RegExp _undecodablePercent = RegExp('%(?![0-9A-Fa-f]{2})');

/// U+FFFD, which the app's UTF-8 decoding of the config puts in place of
/// bytes that are not UTF-8. A hop's host holding one is a name the
/// import leaves out; its user, which ssh signs in as, is refused here.
const String _replacement = '\u{FFFD}';

/// What `isspace()` finds in the C locale.
const String _cWhitespace = ' \t\n\v\f\r';

/// The characters, besides whitespace and control characters, that ssh's
/// `valid_hostname()` rejects, and the glob characters, which it does not:
/// the shell that runs the hops reads them all, and globs a word holding
/// `*`, `?` or `[` into the names of files where ssh runs.
const String _shellCharacters = '\'`"\$\\;&<>|(){}*?[]';

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
/// - has a hop whose user or host holds whitespace, a quote, a glob
///   character or another character the shell reads, or starts with
///   `-` or `~`, or a hop before the last that holds such a character
///   or starts with `~` as written: ssh runs the route as a
///   `ProxyCommand` through `/bin/sh`, putting the last hop's user and
///   host in it and the hops before as written, unquoted, so the shell
///   globs such a word into file names or expands it to a home
///   directory, or the nested ssh rejects such a host name or reads it
///   as an option;
/// - has a `#` comment holding a comma: ssh hands the hops before the
///   last on from the value as written, up to its last comma, so the
///   comment reaches the shell;
/// - has `none`, in any case, as the first of several hops: a nested ssh
///   then gets `-J none`, which means no jump, and dials the next hop
///   directly, without that hop's own route;
/// - has a hop whose host in brackets starts with `ssh://`: ssh puts the
///   host in the command without them, and the nested ssh reads it as
///   an ssh URI;
/// - contains `%`, which ssh expands as a token (ssh_config(5), TOKENS);
/// - has a hop whose user holds U+FFFD, in place of bytes that are not
///   UTF-8, which ssh would sign in with;
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
///   still reach them. That is conservative, not what ssh does;
/// - names a host or hop record that keeps its first pass, a key of
///   [loopingPasses], where ssh would take its final pass: that pass
///   loops where ssh dials the name as itself, but not as this hop (see
///   [LoopingPass]).
///
/// The work is linear in the hosts: following a route stops past 16 hops,
/// and each null route reaches the hosts that name it once.
Map<String, List<JumpHop>?> jumpRoutes(
  List<ImportedHost> hosts, {
  List<ImportedHost> hops = const [],
  Set<String> leftOut = const {},
  Map<String, LoopingPass> loopingPasses = const {},
}) {
  final router = _Router(
    [...hosts, ...hops],
    leftOut,
    _LoopTest.mayLoop,
    loopingPasses,
  );

  // A hop record's own last hop is checked where a route reaches it as a
  // first hop, with that route's user and port.
  final routes = {
    for (final hop in hops) hop.alias: router.follow(hop).route,
    for (final host in hosts) host.alias: router.followToEnd(host).route,
  };
  final parsed = router.parsed;

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

/// The names among [hosts] and [hops] whose route ssh certainly refuses
/// or never completes, with each name's settings as given: following
/// first hops leads back to a name already on the way, or a hop as
/// written is the host or hop it leads to, ssh's "jumphost loop" (see
/// [_isJumpLoop]), here only where the user and the host ssh dials are
/// known. A name's own route ends at the name itself, on its own port
/// and as its own user. Routes through a name in [leftOut] count only
/// when they loop before it.
///
/// The import reads the config as if `/etc/ssh/ssh_config` asked for the
/// final pass, and keeps a name's first pass where that pass gives one of
/// these routes (03 §10.1), each as a [LoopingPass] keyed by the name.
Map<String, LoopingPass> loopingRoutes(
  List<ImportedHost> hosts, {
  List<ImportedHost> hops = const [],
  Set<String> leftOut = const {},
}) {
  final named = [...hosts, ...hops];
  final router = _Router(named, leftOut, _LoopTest.mustLoop);
  final looping = <String, LoopingPass>{};
  for (final host in named) {
    final followed = router.follow(host);
    final pass = followed.loops
        ? LoopingPass._(host, null)
        : switch (followed.route?.lastOrNull) {
            null => null,
            final last => LoopingPass._(host, last._written),
          };
    if (pass != null &&
        pass._loopsAs(host.port ?? kSshDefaultPort, host.user)) {
      looping[host.alias] = pass;
    }
  }
  return looping;
}

/// A final pass that gives a name a route ssh refuses where ssh dials the
/// name as itself, so the name keeps its first pass ([loopingRoutes]).
///
/// ssh reaches a hop with a nested ssh that may dial the name on another
/// port or as another user, and that takes the final pass wherever it
/// does not loop. As a later hop, the nested ssh gets the hops before it
/// with `-J`, which overrides the route of either pass, so the first pass
/// holds only where both give the same `HostName`, `Port`, `User` and
/// `IdentityFile`, the hop's own port and user first. As a first hop, its
/// route applies, so the first pass holds only where the route still
/// loops on the hop's own port, else the final pass's, and as its own
/// user, else the final pass's.
final class LoopingPass {
  const LoopingPass._(this.settings, this._lastHop);

  /// The settings the final pass gives.
  final ImportedHost settings;

  /// The route's last hop where only its jumphost loop to the name makes
  /// the route one ssh refuses; null where the route loops before that,
  /// on whatever port and as whatever user ssh dials the name.
  final _Hop? _lastHop;

  /// Whether the route certainly loops where ssh dials the name on [port]
  /// as [user].
  bool _loopsAs(int port, String? user) => switch (_lastHop) {
    null => true,
    final last => _isJumpLoop(
      last,
      settings.effectiveHost,
      port,
      user,
      _LoopTest.mustLoop,
    ),
  };

  /// Whether ssh takes the first pass, [first], for the name as hop
  /// [index] of a route that gives it its own [user] and [port].
  bool _firstPassHolds(ImportedHost first, int index, String? user, int? port) {
    if (index == 0) {
      return _loopsAs(
        port ?? settings.port ?? kSshDefaultPort,
        user ?? settings.user,
      );
    }
    return first.hostName == settings.hostName &&
        (port ?? first.port) == (port ?? settings.port) &&
        (user ?? first.user) == (user ?? settings.user) &&
        first.identityFile == settings.identityFile;
  }
}

/// Which jumps [_isJumpLoop] counts.
enum _LoopTest {
  /// Every jump that may be a loop: where the user or the host ssh dials
  /// is unknown, one that could match. [jumpRoutes] leaves such routes
  /// out.
  mayLoop,

  /// Only jumps that are certainly loops.
  mustLoop,
}

/// A route, or null with whether it failed because it loops.
typedef _Followed = ({List<JumpHop>? route, bool loops});

/// Follows routes through a set of named hosts and hop records.
final class _Router {
  _Router(
    List<ImportedHost> named,
    this._leftOut,
    this._test, [
    this._loopingPasses = const {},
  ]) : _byAlias = {for (final host in named) host.alias: host},
       parsed = {
         for (final host in named)
           host.alias: switch (host.proxyJump) {
             null => const <_Hop>[],
             final value => _parseProxyJump(value),
           },
       };

  final Set<String> _leftOut;
  final _LoopTest _test;

  /// The final pass of each name that keeps its first pass.
  final Map<String, LoopingPass> _loopingPasses;

  final Map<String, ImportedHost> _byAlias;

  /// Each name's hops, null where the engine cannot read its `ProxyJump`.
  final Map<String, List<_Hop>?> parsed;

  /// The route of [host] with [host] as its end: its last hop must not
  /// be a jumphost loop to [host] on its own port and as its own user.
  _Followed followToEnd(ImportedHost host) {
    final followed = follow(host);
    final route = followed.route;
    if (route == null || route.isEmpty) return followed;

    final loops = _isJumpLoop(
      route.last._written,
      host.effectiveHost,
      host.port ?? kSshDefaultPort,
      host.user,
      _test,
    );
    return loops ? (route: null, loops: true) : followed;
  }

  /// The route of [host] in at most [limit] hops. [visiting] holds the
  /// hosts whose first hop led here, to catch a loop.
  _Followed follow(
    ImportedHost host, [
    Set<String>? visiting,
    int limit = _maxJumpHops,
  ]) {
    const unfollowable = (route: null, loops: false);
    const looping = (route: null, loops: true);
    visiting ??= {host.alias};

    final own = parsed[host.alias];
    if (own == null || own.length > limit) return unfollowable;

    final route = <JumpHop>[];
    for (final (index, (:name, :user, host: hopHost, :port)) in own.indexed) {
      if (_leftOut.contains(hopHost)) return unfollowable;

      final alias = _byAlias[hopHost];
      final finalPass = alias == null ? null : _loopingPasses[alias.alias];
      if (finalPass != null &&
          !finalPass._firstPassHolds(alias!, index, user, port)) {
        return unfollowable;
      }
      if (index == 0 && alias != null) {
        if (!visiting.add(alias.alias)) return looping;

        // ssh reaches the first hop through its own ProxyJump, so that
        // route comes first and leaves room for this host's hops.
        final upstream = follow(alias, visiting, limit - own.length);
        if (upstream.route == null) return upstream;
        route.addAll(upstream.route!);
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
          _isJumpLoop(previous._written, hop.host, hop.port, hop.user, _test)) {
        return looping;
      }
      route.add(hop);
    }
    return (route: List.unmodifiable(route), loops: false);
  }
}

/// Whether ssh's `parse_jump()` accepts a `ProxyJump` [value], the rest
/// of its line after the keyword and the whitespace and `=` that follow.
/// ssh checks every `ProxyJump` line so, in a block that applies or not,
/// and rejects the whole config over one it does not accept ("Invalid
/// ProxyJump"). As for `Port`, a service name other than `ssh`, `http`
/// and `https`, which ssh may resolve, counts as a port it rejects.
///
/// This is ssh's syntax alone; [jumpRoutes] follows fewer routes.
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
  final split = _splitHost(rest);
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

  final split = _splitHost(at < 0 ? text : text.substring(at + 1));
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

/// The name each hop of a `ProxyJump` [value] gives, as [jumpRoutes] looks
/// it up: empty for `none`, null when the engine cannot read [value].
List<String>? proxyJumpHosts(String value) => switch (_parseProxyJump(value)) {
  null => null,
  final hops => [for (final hop in hops) hop.host],
};

typedef _Hop = ({String name, String? user, String host, int? port});

/// Whether ssh refuses to reach [host] on [port] as [user] through the
/// [jump] before it (`ssh.c`: "jumphost loop"): the jump's host as
/// written is the host ssh dials for [host] ([sshCanonicalHost]: an
/// address as `getnameinfo()` writes it), its port, else 22, is [port],
/// and its user, else [user], is [user]. Where that host cannot be known,
/// any jump to an address counts. A jump with its own user, to a host
/// whose user is the local account's, which the import does not know,
/// counts as a loop. With [test] [_LoopTest.mustLoop], neither unknown
/// counts.
bool _isJumpLoop(
  _Hop jump,
  String host,
  int port,
  String? user,
  _LoopTest test,
) {
  final mayLoop = test == _LoopTest.mayLoop;
  if ((jump.port ?? kSshDefaultPort) != port) return false;
  if (jump.user != null && jump.user != user && (user != null || !mayLoop)) {
    return false;
  }

  return switch (sshCanonicalHost(host)) {
    final dialed? => jump.host == dialed,
    null => mayLoop && looksLikeSshAddress(jump.host),
  };
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
  final text = _rtrim(hash < 0 ? value : value.substring(0, hash));
  if (text.contains('%')) return null;

  final names = text.split(',');
  // The nested ssh that gets `-J none` takes it for no jump, so the hop
  // after none is dialed directly, without its own route.
  if (names.length > 1 && names.first.toLowerCase() == 'none') return null;

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
        // The nested ssh reads it, brackets dropped, as an ssh URI.
        hop.host.startsWith('ssh://') ||
        !_isShellWord(hop.user ?? '') ||
        (hop.user?.startsWith('-') ?? false) ||
        (hop.user?.contains(_replacement) ?? false)) {
      return null;
    }
    hops.add((name: name, user: hop.user, host: hop.host, port: hop.port));
  }
  return hops;
}

/// [text] without the C locale's `isspace()` characters at its end, so
/// U+00A0 and other Unicode whitespace stay part of the last hop, as in
/// `parse_jump()`. Its `rtrim()` also ends the value at such a character
/// inside it; one left there makes the import refuse the hop.
String _rtrim(String text) {
  var end = text.length;
  while (end > 0 && _cWhitespace.contains(text[end - 1])) {
    end--;
  }
  return text.substring(0, end);
}

/// Whether [text] holds no whitespace, control character or
/// [_shellCharacters], and does not start with `~`, which the shell reads
/// as a home directory, so the shell reads it as written.
bool _isShellWord(String text) =>
    !text.startsWith('~') &&
    !text.codeUnits.any(
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
