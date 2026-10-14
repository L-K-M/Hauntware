import 'dart:io' show InternetAddress;

import 'package:seance_core/seance_core.dart'
    show ImportedHost, SshConfigImporter, SshConfigLine;

import '../engine/protocol.dart' show kSshDefaultPort;

/// The TCP port range; a stored `Port` outside it names no reachable
/// endpoint.
const int _minimumPort = 1;
const int _maximumPort = 65535;

/// The service names a `Port` may give instead of a number, with their
/// TCP ports from the IANA registry. ssh resolves any name through
/// `getservbyname(3)`, which Dart cannot call portably; Séance's
/// `SshConfigImporter` knows these three, and so does the import.
const Map<String, int> _servicePorts = {'ssh': 22, 'http': 80, 'https': 443};

/// A base-10 integer with an optional sign, as `strtonum()` reads it.
final RegExp _decimal = RegExp(r'^[+-]?[0-9]+$');

/// What ssh's `is_addr_fast()` takes for an address without parsing it.
final RegExp _digitsAndDots = RegExp(r'^[0-9.]*$');

/// The `IdentityFile` that names no key file. ssh skips it when it loads
/// keys (`ssh.c`, `load_public_identity_files()`).
const String _noIdentityFile = 'none';

/// `ProxyCommand none` is a direct connection (`option_clear_or_none()`).
const String _noProxyCommand = 'none';

/// The `CanonicalizeHostname` values that leave canonicalization off.
const Set<String> _canonicalizationOff = {'no', 'false'};

/// The longest subpattern `match_pattern_list()` reads; a longer one makes
/// the whole list match nothing.
const int _maximumSubpatternLength = 1023;

/// The directives the engine maps, and `Include`. ssh reads every other
/// one too, but none of them changes where or as whom the engine dials.
enum _Keyword {
  hostName,
  port,
  user,
  identityFile,
  proxyJump,
  proxyCommand,
  canonicalizeHostname,
  include,
}

const Map<String, _Keyword> _keywords = {
  'hostname': _Keyword.hostName,
  'port': _Keyword.port,
  'user': _Keyword.user,
  'identityfile': _Keyword.identityFile,
  'proxyjump': _Keyword.proxyJump,
  'proxycommand': _Keyword.proxyCommand,
  'canonicalizehostname': _Keyword.canonicalizeHostname,
  'include': _Keyword.include,
};

/// Why [SshConfigSettings.resolve] gives no settings for a name.
enum UnresolvedReason {
  /// A block that applies holds a line ssh rejects: a `Port` the import
  /// cannot read (see [SshConfigSettings]), a `HostName`, `User`,
  /// `IdentityFile`, `ProxyJump`, `ProxyCommand` or
  /// `CanonicalizeHostname` with no value, or with more than one where
  /// ssh takes one, one of those lines or the `Host` line with a quote
  /// left open, or a `Host` line with an empty pattern.
  rejectedLine,

  /// The `HostName` holds a token other than `%h` or `%%`, or ends in
  /// `%`; ssh exits on it.
  hostNameToken,

  /// The first `IdentityFile` ssh would load holds a `%` token or a
  /// `${VAR}`, which ssh fills in from the connection and the
  /// environment.
  identityFileToken,

  /// The route is a `ProxyCommand` other than `none`, which the engine
  /// cannot run.
  proxyCommand,

  /// A `Match` block that may apply could set a value first: one of its
  /// criteria cannot be evaluated here, or ssh would reject it.
  mayApply,

  /// An `Include` applies: the file it names, which the engine never
  /// opens, could set any value first.
  include,

  /// ssh would read the config a second time, against the canonical host
  /// name, and that pass could set a value the first left unset.
  secondPass,
}

/// What [SshConfigSettings.resolve] found for a name.
sealed class SshConfigResolution {
  const SshConfigResolution();
}

/// The settings ssh would use, as an [ImportedHost] whose alias is the
/// name. Its `HostName` is the one ssh dials: `%h` expanded, and
/// lowercased unless it is an address. Its `ProxyJump` is the value ssh
/// would read, as written (`none`, in any case, for a direct connection),
/// or null when no `ProxyJump` applies or the route is `ProxyCommand
/// none`; both of those are direct too.
final class ResolvedSshSettings extends SshConfigResolution {
  const ResolvedSshSettings(this.host);

  final ImportedHost host;
}

/// No settings: ssh would use ones the engine cannot know or follow.
final class UnresolvedSshSettings extends SshConfigResolution {
  const UnresolvedSshSettings(this.reason);

  final UnresolvedReason reason;
}

/// An OpenSSH client config, read so that it answers, for any name you
/// could give ssh, the settings ssh would use for it (03 §10.1).
///
/// What ssh does (`readconf.c`), and so what this does: it reads the file
/// from the top, and every block that applies to the name sets each
/// setting it names unless an earlier line already set it, so the first
/// value read wins, in one block as across blocks. Lines before the first
/// `Host` or `Match` apply to every name. A `Host` block applies when one
/// of its patterns matches the name and no negated one does (`*` and `?`
/// are wildcards, matched case-sensitively, as `match_pattern()` does).
/// Whichever of `ProxyJump` and `ProxyCommand` ssh reads first is the
/// route. `IdentityFile` adds a key file each time; ssh tries them in
/// order, and the engine signs in with the first one that is not `none`.
///
/// A `Match` block applies when all its criteria hold. `all`, `host`
/// (the `HostName` read so far, `%h` expanded) and `originalhost` (the
/// name) are evaluated as ssh does; `canonical` and `final` hold only on
/// a second pass. `exec`, `user`, `localuser`, `localnetwork` and
/// `tagged` depend on the device or the connection, so a block with one
/// of them, and no criterion that fails, may apply: if it would set a
/// value still unset, the name is unresolved. So is a malformed `Match`,
/// on which ssh rejects the whole config.
///
/// `Include` is not followed. A file it names could set any value, so an
/// `Include` in a block that applies leaves the name unresolved. An
/// included file could also hold a `Match final`, so a config with an
/// `Include` or a `Match final` anywhere makes ssh read it a second time,
/// against the canonical name; a name whose `Port`, `User`,
/// `IdentityFile` or route is still unset after the first pass is then
/// unresolved, since that pass could set it. `CanonicalizeHostname` other
/// than `no` canonicalizes through DNS before that pass, so it leaves the
/// name unresolved.
///
/// ssh rejects the whole config over some lines wherever they stand: a
/// `Port` it cannot read, a directive with no value or more values than
/// it takes, a quote left open, or an empty `Host` pattern. A `Port` here
/// is a decimal 1 to 65535 or one of the service names `ssh`, `http` and
/// `https`, as Séance's `SshConfigImporter` reads it (ssh resolves other
/// names too). Such a line leaves unresolved only the names its block
/// applies to; lines in other blocks, and directives the engine does not
/// map, are not checked.
/// Nor is the system-wide `/etc/ssh/ssh_config`, which ssh reads after
/// this file and which can set what this file leaves unset, read at all.
final class SshConfigSettings {
  SshConfigSettings._(this.aliases, this._always, this._byName, this._rereads);

  /// Reads [text].
  factory SshConfigSettings.parse(String text) {
    final aliases = <String>{};
    final blocks = <_Block>[_Top()];
    var rereads = false;

    for (final raw in text.split('\n')) {
      final line = SshConfigLine.tryParse(raw);
      if (line == null) continue;

      final rest = _rest(raw);
      switch (line.keyword) {
        case 'host':
          blocks.add(
            _HostBlock(
              blocks.length,
              line.arguments,
              rejected: _hasOpenQuote(rest) || line.arguments.contains(''),
            ),
          );
          aliases.addAll(SshConfigImporter.hostAliases(line.arguments));
        case 'match':
          final block = _MatchBlock.parse(
            blocks.length,
            line.arguments,
            openQuote: _hasOpenQuote(rest),
          );
          rereads |= block.wantsSecondPass;
          blocks.add(block);
        default:
          final keyword = _keywords[line.keyword];
          if (keyword == null) continue;

          rereads |= keyword == _Keyword.include;
          blocks.last.lines.add((
            keyword: keyword,
            arguments: line.arguments,
            rest: rest,
            openQuote: _hasOpenQuote(rest),
          ));
      }
    }

    // Only blocks with lines the engine reads can change a setting, and a
    // Host line ssh rejects leaves out the names it applies to. A Host
    // block whose patterns hold no wildcard can only match those names, so
    // a name considers those blocks and the rest, which keeps resolving
    // every alias of a large config fast.
    final always = <_Block>[];
    final byName = <String, List<_Block>>{};
    for (final block in blocks) {
      final rejected = block is _HostBlock && block.rejected;
      if (block.lines.isEmpty && !rejected) continue;

      switch (block) {
        case _HostBlock(:final names?):
          for (final name in names) {
            (byName[name] ??= []).add(block);
          }
        case _HostBlock(wildcard: false):
          break;
        default:
          always.add(block);
      }
    }
    return SshConfigSettings._(
      List.unmodifiable(aliases),
      always,
      byName,
      rereads,
    );
  }

  /// The names `Host` lines give, in the order they first appear: each
  /// pattern without a wildcard or negation, unless a negated pattern on
  /// its line matches it (Séance's `SshConfigImporter.hostAliases`).
  final List<String> aliases;

  /// The blocks every name considers, in file order.
  final List<_Block> _always;

  /// For each name, the `Host` blocks only it and other literal names
  /// match, in file order.
  final Map<String, List<_Block>> _byName;

  /// Whether ssh may read the config a second time.
  final bool _rereads;

  /// The settings ssh would use for [name], the host name you give it.
  SshConfigResolution resolve(String name) {
    final reading = _Reading(name);
    final own = _byName[name] ?? const <_Block>[];
    var next = 0;
    var nextOwn = 0;
    while (next < _always.length || nextOwn < own.length) {
      final takeOwn =
          next == _always.length ||
          (nextOwn < own.length && own[nextOwn].order < _always[next].order);
      final block = takeOwn ? own[nextOwn++] : _always[next++];

      final applies = block.applies(name, reading);
      if (applies == _Applies.no) continue;
      if (block case _HostBlock(rejected: true)) {
        return const UnresolvedSshSettings(UnresolvedReason.rejectedLine);
      }

      for (final line in block.lines) {
        final reason = reading.read(line, mayApply: applies == _Applies.maybe);
        if (reason != null) return UnresolvedSshSettings(reason);
      }
    }
    return reading.finish(secondPass: _rereads);
  }
}

/// Whether a block applies to a name.
enum _Applies { yes, no, maybe }

/// One line the engine reads: its directive, its arguments as ssh splits
/// them, the rest of the line as written, which ssh hands `ProxyJump` and
/// `ProxyCommand` whole, and whether a quote in it is left open.
typedef _Line = ({
  _Keyword keyword,
  List<String> arguments,
  String rest,
  bool openQuote,
});

sealed class _Block {
  _Block(this.order);

  /// The block's place in the file.
  final int order;

  final List<_Line> lines = [];

  _Applies applies(String name, _Reading reading);
}

/// The lines before the first `Host` or `Match`: they apply to every name.
final class _Top extends _Block {
  _Top() : super(0);

  @override
  _Applies applies(String name, _Reading reading) => _Applies.yes;
}

final class _HostBlock extends _Block {
  _HostBlock(super.order, List<String> patterns, {required this.rejected})
    : _patterns = [
        for (final pattern in patterns)
          if (pattern.isNotEmpty)
            pattern.startsWith('!')
                ? (negated: true, glob: _Glob(pattern.substring(1)))
                : (negated: false, glob: _Glob(pattern)),
      ] {
    final positive = [
      for (final (:negated, :glob) in _patterns)
        if (!negated) glob.pattern,
    ];
    wildcard = positive.any((p) => p.contains('*') || p.contains('?'));
    names = positive.isEmpty || wildcard ? null : positive.toSet();
  }

  final List<({bool negated, _Glob glob})> _patterns;

  /// Whether ssh rejects the `Host` line, and so the whole config: a quote
  /// is left open, or a pattern is empty.
  final bool rejected;

  /// Whether a pattern that is not negated holds a wildcard.
  late final bool wildcard;

  /// The only names the block can apply to, when no pattern that is not
  /// negated holds a wildcard; null otherwise, and for a block without
  /// such a pattern, which applies to nothing.
  late final Set<String>? names;

  /// `readconf.c`'s `oHost`: a matching negated pattern ends the line and
  /// turns the block off.
  @override
  _Applies applies(String name, _Reading reading) {
    var active = false;
    for (final (:negated, :glob) in _patterns) {
      if (!glob.matches(name)) continue;
      if (negated) return _Applies.no;
      active = true;
    }
    return active ? _Applies.yes : _Applies.no;
  }
}

/// A `Match` criterion, as `match_cfg_line()` reads it.
enum _Criterion { all, secondPass, host, originalHost, unknown }

final class _MatchBlock extends _Block {
  _MatchBlock._(
    super.order,
    this._criteria, {
    required this.malformed,
    required this.wantsSecondPass,
  });

  /// `match_cfg_line()`'s reading of a `Match` line's [arguments]; ssh
  /// rejects one with an [openQuote] before it reads them.
  factory _MatchBlock.parse(
    int order,
    List<String> arguments, {
    required bool openQuote,
  }) {
    final criteria = <({_Criterion kind, bool negated, _HostList? list})>[];
    var wantsSecondPass = false;
    var attributes = 0;
    var index = 0;

    _MatchBlock done({bool malformed = false}) => _MatchBlock._(
      order,
      criteria,
      malformed: malformed || openQuote,
      wantsSecondPass: wantsSecondPass,
    );

    while (index < arguments.length) {
      var attribute = arguments[index++];
      if (attribute.startsWith('#')) break;

      final negated = attribute.startsWith('!');
      if (negated) attribute = attribute.substring(1);
      final lowered = _asciiLower(attribute);

      // `all` stands alone and ends the line.
      if (lowered == 'all') {
        final next = index < arguments.length ? arguments[index] : '';
        if (attributes > 1 || (next.isNotEmpty && !next.startsWith('#'))) {
          return done(malformed: true);
        }
        criteria.add((kind: _Criterion.all, negated: negated, list: null));
        return done();
      }

      attributes++;
      if (lowered == 'canonical' || lowered == 'final') {
        wantsSecondPass |= lowered == 'final';
        criteria.add((
          kind: _Criterion.secondPass,
          negated: negated,
          list: null,
        ));
        continue;
      }

      final patterns = index < arguments.length ? arguments[index++] : '';
      if (patterns.isEmpty || patterns.startsWith('#')) {
        return done(malformed: true);
      }
      final kind = switch (lowered) {
        'host' => _Criterion.host,
        'originalhost' => _Criterion.originalHost,
        'user' ||
        'localuser' ||
        'localnetwork' ||
        'tagged' ||
        'exec' => _Criterion.unknown,
        _ => null,
      };
      if (kind == null) return done(malformed: true);
      criteria.add((
        kind: kind,
        negated: negated,
        list: _HostList.parse(patterns),
      ));
    }
    return done(malformed: attributes == 0);
  }

  final List<({_Criterion kind, bool negated, _HostList? list})> _criteria;

  /// Whether ssh rejects the line, and so the whole config.
  final bool malformed;

  /// Whether the line holds `final`, which makes ssh read the config a
  /// second time, for every name.
  final bool wantsSecondPass;

  @override
  _Applies applies(String name, _Reading reading) {
    if (malformed) return _Applies.maybe;

    var unknown = false;
    for (final (:kind, :negated, :list) in _criteria) {
      final bool? holds = switch (kind) {
        _Criterion.all => true,
        // This is the first pass.
        _Criterion.secondPass => false,
        _Criterion.host => switch (reading.matchHost) {
          null => null,
          final host => list!.match(host) == 1,
        },
        _Criterion.originalHost => list!.match(name) == 1,
        _Criterion.unknown => null,
      };
      if (holds == null) {
        unknown = true;
      } else if (holds == negated) {
        return _Applies.no;
      }
    }
    return unknown ? _Applies.maybe : _Applies.yes;
  }
}

/// The settings read so far for one name; null is unset.
final class _Reading {
  _Reading(this.name);

  final String name;
  String? hostName;
  int? port;
  String? user;
  String? identityFile;
  ({bool command, String value})? route;
  String? canonicalization;

  /// The host a `Match host` compares: the `HostName` read so far with
  /// `%h` expanded, else the name; null when ssh would exit expanding it.
  String? get matchHost => switch (hostName) {
    null => name,
    final value => _expandHostName(value, name),
  };

  /// Applies [line] from a block that applies, or may apply; the reason
  /// the name is unresolved, or null.
  UnresolvedReason? read(_Line line, {required bool mayApply}) {
    // ssh reads a value only while it is unset; a block that may apply
    // could set it first.
    UnresolvedReason? first(bool unset, void Function() set) {
      if (!unset) return null;
      if (mayApply) return UnresolvedReason.mayApply;

      set();
      return null;
    }

    final single = line.arguments.length == 1 && line.arguments.first != ''
        ? line.arguments.first
        : null;
    if (line.openQuote) return UnresolvedReason.rejectedLine;
    if (line.keyword == _Keyword.include) return UnresolvedReason.include;
    if (switch (line.keyword) {
      _Keyword.port => single == null || _parsePort(single) == null,
      _Keyword.proxyJump || _Keyword.proxyCommand => line.rest.isEmpty,
      _ => single == null,
    }) {
      return UnresolvedReason.rejectedLine;
    }

    return switch (line.keyword) {
      _Keyword.hostName => first(hostName == null, () => hostName = single),
      _Keyword.port => first(port == null, () => port = _parsePort(single!)),
      _Keyword.user => first(user == null, () => user = single),
      // ssh skips `none` when it loads keys, so the next file is first.
      _Keyword.identityFile => first(
        identityFile == null && !_isNoIdentityFile(single!),
        () => identityFile = single,
      ),
      _Keyword.proxyJump || _Keyword.proxyCommand => first(
        route == null,
        () => route = (
          command: line.keyword == _Keyword.proxyCommand,
          value: line.rest,
        ),
      ),
      _Keyword.canonicalizeHostname => first(
        canonicalization == null,
        () => canonicalization = single,
      ),
      _Keyword.include => UnresolvedReason.include,
    };
  }

  /// The settings, once every block has been read.
  SshConfigResolution finish({required bool secondPass}) {
    if (canonicalization case final value?
        when !_canonicalizationOff.contains(_asciiLower(value))) {
      return const UnresolvedSshSettings(UnresolvedReason.secondPass);
    }
    final route = this.route;
    if (secondPass &&
        (port == null ||
            user == null ||
            identityFile == null ||
            route == null)) {
      return const UnresolvedSshSettings(UnresolvedReason.secondPass);
    }
    if (route != null &&
        route.command &&
        _asciiLower(route.value) != _noProxyCommand) {
      return const UnresolvedSshSettings(UnresolvedReason.proxyCommand);
    }
    final host = matchHost;
    if (host == null) {
      return const UnresolvedSshSettings(UnresolvedReason.hostNameToken);
    }
    final key = identityFile;
    if (key != null && !isImportedIdentityFile(key)) {
      return const UnresolvedSshSettings(UnresolvedReason.identityFileToken);
    }

    return ResolvedSshSettings(
      ImportedHost(
        alias: name,
        // ssh lowercases the host it dials unless it is an address.
        hostName: _isAddress(host) ? host : _asciiLower(host),
        port: port ?? kSshDefaultPort,
        user: user,
        identityFile: key,
        proxyJump: route == null || route.command ? null : route.value,
      ),
    );
  }
}

/// Whether [port] is in the TCP port range, so it can name an endpoint.
bool isTcpPort(int port) => port >= _minimumPort && port <= _maximumPort;

/// Whether the import keeps [path] as a host's `IdentityFile`: not empty,
/// not `none` in any case (which means no key file), and holding neither
/// a `%` token nor a `${VAR}`, which ssh would expand.
bool isImportedIdentityFile(String path) =>
    path.isNotEmpty &&
    !_isNoIdentityFile(path) &&
    !path.contains('%') &&
    !path.contains(r'${');

bool _isNoIdentityFile(String path) => _asciiLower(path) == _noIdentityFile;

/// The port ssh's `a2port()` reads from [value], or null where ssh
/// reports "Bad port" or [value] names a service not in [_servicePorts].
int? _parsePort(String value) {
  if (!_decimal.hasMatch(value)) return _servicePorts[value];

  // null when the digits overflow an int, which is out of range too.
  final port = int.tryParse(value);
  return port == null || !isTcpPort(port) ? null : port;
}

/// The rest of a config [line] after its keyword and the spaces, tabs and
/// `=` that follow it, as ssh hands it to `ProxyJump` and `ProxyCommand`.
String _rest(String line) {
  const separators = ' \t=';
  final text = line.trim();
  var index = 0;
  while (index < text.length && !separators.contains(text[index])) {
    index++;
  }
  while (index < text.length && separators.contains(text[index])) {
    index++;
  }
  return text.substring(index);
}

/// Whether `argv_split()` finds a quote in [text], the arguments of a
/// config line, left open at its end ("invalid quotes"). A `#` that starts
/// an argument ends the line; a backslash escapes a quote, a backslash,
/// and outside quotes a space.
bool _hasOpenQuote(String text) {
  var index = 0;
  while (index < text.length) {
    final character = text[index];
    if (character == ' ' || character == '\t') {
      index++;
      continue;
    }
    if (character == '#') return false;

    String? quote;
    for (; index < text.length; index++) {
      final c = text[index];
      final next = index + 1 < text.length ? text[index + 1] : '';
      if (c == r'\') {
        final escapes =
            next == '"' ||
            next == "'" ||
            next == r'\' ||
            (quote == null && next == ' ');
        if (escapes) index++;
      } else if (quote == null && (c == ' ' || c == '\t')) {
        break;
      } else if (quote == null && (c == '"' || c == "'")) {
        quote = c;
      } else if (c == quote) {
        quote = null;
      }
    }
    if (quote != null) return true;
  }
  return false;
}

/// ssh's expansion of a `HostName` [value] for [name] (`ssh.c` calls
/// `percent_expand()` with `h` alone): `%h` is the name and `%%` is `%`.
/// Null for any other token or a trailing `%`, on which ssh exits.
String? _expandHostName(String value, String name) {
  if (!value.contains('%')) return value;

  final expanded = StringBuffer();
  for (var index = 0; index < value.length; index++) {
    final character = value[index];
    if (character != '%') {
      expanded.write(character);
      continue;
    }

    index++;
    if (index == value.length) return null;
    switch (value[index]) {
      case 'h':
        expanded.write(name);
      case '%':
        expanded.write('%');
      default:
        return null;
    }
  }
  return expanded.toString();
}

/// ssh's `is_addr()`: a `%`, a `:` or nothing but digits and dots, or
/// a name that parses as an IP address.
bool _isAddress(String host) =>
    host.contains('%') ||
    host.contains(':') ||
    _digitsAndDots.hasMatch(host) ||
    InternetAddress.tryParse(host) != null;

/// ASCII lowercase, as ssh's `lowercase()` and `tolower()` in the C locale.
String _asciiLower(String text) {
  final codes = text.codeUnits;
  if (!codes.any((c) => c >= 0x41 && c <= 0x5a)) return text;

  return String.fromCharCodes([
    for (final c in codes) c >= 0x41 && c <= 0x5a ? c + 0x20 : c,
  ]);
}

const int _star = 0x2a;
const int _question = 0x3f;
const int _bang = 0x21;
const int _comma = 0x2c;

/// ssh's `match_pattern()`: `*` matches any run of characters, `?` any
/// one, and every other character itself.
bool _matchPattern(String text, String pattern, [int t = 0, int p = 0]) {
  while (true) {
    if (p == pattern.length) return t == text.length;

    final character = pattern.codeUnitAt(p);
    if (character == _star) {
      while (p < pattern.length && pattern.codeUnitAt(p) == _star) {
        p++;
      }
      if (p == pattern.length) return true;

      final next = pattern.codeUnitAt(p);
      for (; t < text.length; t++) {
        if ((next == _question || text.codeUnitAt(t) == next) &&
            _matchPattern(text, pattern, t, p)) {
          return true;
        }
      }
      return false;
    }

    if (t == text.length) return false;
    if (character != _question && character != text.codeUnitAt(t)) {
      return false;
    }
    t++;
    p++;
  }
}

/// A `match_pattern()` pattern, read once. A pattern whose only wildcard
/// is `*` matches when its literal pieces appear in order, the first at
/// the start and the last at the end; any other goes through
/// [_matchPattern].
final class _Glob {
  _Glob(this.pattern)
    : _pieces = pattern.contains('?') ? null : pattern.split('*');

  final String pattern;

  /// The pieces between the `*`s, or null when the pattern holds a `?`.
  final List<String>? _pieces;

  bool matches(String text) {
    final pieces = _pieces;
    if (pieces == null) return _matchPattern(text, pattern);
    if (pieces.length == 1) return text == pattern;

    final (first, last) = (pieces.first, pieces.last);
    if (text.length < first.length + last.length ||
        !text.startsWith(first) ||
        !text.endsWith(last)) {
      return false;
    }
    var from = first.length;
    final end = text.length - last.length;
    for (var index = 1; index < pieces.length - 1; index++) {
      final piece = pieces[index];
      if (piece.isEmpty) continue;

      final at = text.indexOf(piece, from);
      if (at < 0 || at + piece.length > end) return false;
      from = at + piece.length;
    }
    return true;
  }
}

/// A `Match` criterion's comma-separated list of patterns, each possibly
/// negated, read once and lowercased, as `match_pattern_list()` reads it
/// for `match_hostname()`. A subpattern of 1023 characters or more makes
/// the list match nothing where ssh reaches it, so it is kept as null.
final class _HostList {
  _HostList._(this._entries);

  factory _HostList.parse(String list) {
    final entries = <({bool negated, _Glob glob})?>[];
    var index = 0;
    while (index < list.length) {
      final negated = list.codeUnitAt(index) == _bang;
      if (negated) index++;

      var end = index;
      while (end < list.length && list.codeUnitAt(end) != _comma) {
        end++;
      }
      entries.add(
        end - index >= _maximumSubpatternLength
            ? null
            : (
                negated: negated,
                glob: _Glob(_asciiLower(list.substring(index, end))),
              ),
      );
      index = end < list.length ? end + 1 : end;
    }
    return _HostList._(entries);
  }

  final List<({bool negated, _Glob glob})?> _entries;

  /// ssh's `match_hostname()` for [host], lowercased: 1 for a match, -1
  /// when a negated pattern matches, else 0.
  int match(String host) {
    final text = _asciiLower(host);
    var positive = false;
    for (final entry in _entries) {
      if (entry == null) return 0;
      if (!entry.glob.matches(text)) continue;
      if (entry.negated) return -1;
      positive = true;
    }
    return positive ? 1 : 0;
  }
}
