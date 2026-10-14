import 'dart:convert' show utf8;
import 'dart:io' show InternetAddress;

import 'package:seance_core/seance_core.dart'
    show ImportedHost, SshConfigImporter;

import '../engine/protocol.dart' show kSshDefaultPort;
import 'jump_routes.dart' show sshAcceptsProxyJump;

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

/// Every `CanonicalizeHostname` value ssh reads, in any case
/// (`multistate_canonicalizehostname`).
const Set<String> _canonicalizationValues = {
  'yes',
  'no',
  'true',
  'false',
  'always',
};

/// The longest subpattern `match_pattern_list()` reads, in bytes; a longer
/// one makes the whole list match nothing.
const int _maximumSubpatternLength = 1023;

/// U+FFFD, which the app's UTF-8 decoding of the config puts in place of
/// bytes that are not UTF-8.
const String _replacement = '\u{FFFD}';

/// A UTF-8 byte-order mark. Dart's decoder drops one at the start of the
/// file, so the app puts it back for the engine to see.
const String _byteOrderMark = '\u{FEFF}';

/// `readconf.c`'s `WHITESPACE`, which `strdelim()` skips around a keyword.
const String _whitespace = ' \t\r\n';

/// What `process_config_line_depth()` strips from the end of a line.
const String _lineEnd = ' \t\r\n\f';

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
  // Obsolete, but `readconf.c` still reads it as `IdentityFile`.
  'identityfile2': _Keyword.identityFile,
  'proxyjump': _Keyword.proxyJump,
  'proxycommand': _Keyword.proxyCommand,
  'canonicalizehostname': _Keyword.canonicalizeHostname,
  'include': _Keyword.include,
};

/// Why [SshConfigSettings.resolve] gives no settings for a name.
enum UnresolvedReason {
  /// ssh rejects the whole config: the file starts with a byte-order
  /// mark, a `ProxyJump` or `CanonicalizeHostname` line anywhere is one
  /// ssh rejects, or a block that applies holds a line ssh rejects: a
  /// `Port` the import cannot read (see [SshConfigSettings]), a
  /// `HostName`, `User`,
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

  /// ssh may read the config a second time, its final pass, and the
  /// outcome depends on what the engine cannot see: an `Include` names a
  /// file that could ask for that pass and set any value there, and the
  /// `Port`, `User`, `IdentityFile` or route is still unset; without an
  /// `Include` or a `Match final` here, only `/etc/ssh/ssh_config` can ask
  /// for the pass, and it would set one of those (see
  /// [UnresolvedSshSettings.passes]); or `CanonicalizeHostname` is other
  /// than `no`, so ssh canonicalizes the host through DNS before that
  /// pass.
  secondPass,

  /// The name holds U+FFFD, which the app's decoding puts in place of
  /// bytes that are not UTF-8: ssh compares the bytes themselves, which
  /// the import cannot know, and distinct names can decode alike.
  undecodedName,

  /// The `HostName`, `User` or first `IdentityFile` ssh would use holds
  /// U+FFFD: ssh dials and signs in with the bytes themselves, which the
  /// import cannot know.
  undecodedValue,
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
  const UnresolvedSshSettings(this.reason, {this.passes});

  final UnresolvedReason reason;

  /// For a [UnresolvedReason.secondPass] that only `/etc/ssh/ssh_config`
  /// can ask for: the settings without that pass and with it, each as
  /// [ResolvedSshSettings.host] gives them. Null when either pass gives
  /// none. Where the final pass gives a route ssh refuses, that pass is
  /// not the one ssh takes, so the import keeps the first pass's settings
  /// (03 §10.1).
  final ({ImportedHost firstPass, ImportedHost finalPass})? passes;
}

/// An OpenSSH client config, read so that it answers, for any name you
/// could give ssh, the settings ssh would use for it (03 §10.1).
///
/// What ssh does (`readconf.c`), and so what this does: it reads the file
/// from the top, and every block that applies to the name sets each setting
/// it names unless an earlier line already set it, so the first value read
/// wins, in one block as across blocks. Lines before the first `Host` or
/// `Match` apply to every name. A `Host` block applies when one of its
/// patterns matches the name and no negated one does (`*` and `?` are
/// wildcards, matched case-sensitively on UTF-8 bytes, as `match_pattern()`
/// does). The app decodes the file with U+FFFD for bytes that are not
/// UTF-8, so a name holding one is unresolved, as is one whose `HostName`,
/// `User` or first `IdentityFile` holds one, and a wildcard pattern
/// holding one may match any name. Whichever of `ProxyJump` and
/// `ProxyCommand` ssh reads first is the route. `IdentityFile` adds a key
/// file each time; ssh tries them in order, and the engine signs in with
/// the first one that is not `none`.
///
/// A `Match` block applies when all its criteria hold. `all`, `host` (the
/// `HostName` read so far, `%h` expanded) and `originalhost` (the name) are
/// evaluated as ssh does; `canonical` and `final` hold only on the final
/// pass (below). `exec`, `user`, `localuser`, `localnetwork` and `tagged`
/// depend on the device or the connection, so a block with one of them, and
/// no criterion that fails, may apply: if it would set a value still unset,
/// the name is unresolved. So is a malformed `Match`, on which ssh rejects
/// the whole config.
///
/// A `Match final` anywhere, in this file or in one it includes, makes ssh
/// read its config a second time, the final pass (`ssh.c`). `HostName` is
/// fixed by then, and `Host` and `Match host` match the host ssh dials: the
/// `HostName` lowercased, or an address as `getnameinfo()` writes it unless
/// only its case differs. `final` and `canonical` hold, and every block
/// that applies sets what is still unset. `/etc/ssh/ssh_config` can ask for
/// that pass too, as Fedora's and RHEL's `Match final all` does, so it may
/// happen for any config. So the import reads this file a second time for
/// every name: with a `Match final` here, what that pass sets applies;
/// without one, a name whose `Port`, `User`, first `IdentityFile` or route
/// that pass would set is unresolved, since the outcome depends on a file
/// the engine cannot see; [UnresolvedSshSettings.passes] then holds both
/// passes' settings, for the import to keep the first where ssh would
/// refuse the final pass's route. Where the host ssh dials cannot be
/// known (an address with a scope, whose form depends on the device's
/// interfaces, or one the system resolver may read where Dart does not),
/// a block with a pattern other than `*` may apply on that pass.
///
/// `Include` is not followed. A file it names could set any value, so an
/// `Include` in a block that applies leaves the name unresolved. An
/// included file could also hold a `Match final` and set any value on the
/// final pass, so in a config with an `Include` anywhere a name whose
/// `Port`, `User`, `IdentityFile` or route is still unset after the first
/// pass is unresolved. `CanonicalizeHostname` other than `no` canonicalizes
/// through DNS before the final pass, so it leaves the name unresolved.
///
/// Lines split as `readconf.c` splits them ([_ConfigLine]): only space,
/// tab, CR, LF and form feed are stripped from a line's end, and only
/// space and tab separate arguments, so other whitespace, such as U+00A0,
/// is part of a value.
/// ssh reads a byte-order mark at the top of the file as part of the first
/// keyword and rejects the whole config, so every name is unresolved.
///
/// ssh rejects the whole config over some lines wherever they stand: a
/// `Port` it cannot read, a directive with no value or more values than it
/// takes, a quote left open, or an empty `Host` pattern. A `Port` here is a
/// decimal 1 to 65535 or one of the service names `ssh`, `http` and
/// `https`, as Séance's `SshConfigImporter` reads it (ssh resolves other
/// names too). Such a line leaves unresolved only the names its block
/// applies to; lines in other blocks, and directives the engine does not
/// map, are not checked. The exceptions are `ProxyJump`, whose syntax
/// ssh's `parse_jump()` checks in every block ([sshAcceptsProxyJump]),
/// and `CanonicalizeHostname`, whose value ssh checks in every block: one
/// ssh rejects leaves every name unresolved, wherever it stands. Nor is
/// the system-wide `/etc/ssh/ssh_config`, which ssh reads after this file
/// and which can set what this file leaves unset, read at all.
final class SshConfigSettings {
  SshConfigSettings._(
    this.aliases,
    this._read,
    this._index,
    this._includes,
    this._wantsFinalPass,
    this._rejected,
  );

  /// Reads [text].
  factory SshConfigSettings.parse(String text) {
    final aliases = <String>{};
    final blocks = <_Block>[_Top()];
    var includes = false;
    var wantsFinalPass = false;

    // The names still count as hosts, all of them left out.
    var rejected = text.startsWith(_byteOrderMark);
    final lines = (rejected ? text.substring(1) : text).split('\n');

    for (final raw in lines) {
      final line = _ConfigLine.parse(raw);
      if (line == null) continue;

      switch (line.keyword) {
        case 'host':
          blocks.add(
            _HostBlock(
              blocks.length,
              line.arguments,
              rejected: line.openQuote || line.arguments.contains(''),
            ),
          );
          aliases.addAll(SshConfigImporter.hostAliases(line.arguments));
        case 'match':
          final block = _MatchBlock.parse(
            blocks.length,
            line.arguments,
            openQuote: line.openQuote,
          );
          wantsFinalPass |= block.wantsFinalPass;
          blocks.add(block);
        default:
          final keyword = _keywords[line.keyword];
          if (keyword == null) continue;

          // ssh checks these in every block, whether it applies or not.
          rejected |= switch (keyword) {
            _Keyword.proxyJump =>
              line.openQuote || !sshAcceptsProxyJump(line.command),
            _Keyword.canonicalizeHostname =>
              line.openQuote ||
                  line.arguments.length != 1 ||
                  !_canonicalizationValues.contains(
                    _asciiLower(line.arguments.single),
                  ),
            _ => false,
          };
          includes |= keyword == _Keyword.include;
          blocks.last.lines.add((
            keyword: keyword,
            arguments: line.arguments,
            rest: line.command,
            openQuote: line.openQuote,
          ));
      }
    }

    // Only blocks with lines the engine reads can change a setting, and a
    // Host line ssh rejects leaves out the names it applies to.
    final read = <_Block>[];
    final index = _BlockIndex();
    for (final block in blocks) {
      final rejected = block is _HostBlock && block.rejected;
      if (block.lines.isEmpty && !rejected) continue;

      read.add(block);
      index.add(block);
    }
    return SshConfigSettings._(
      List.unmodifiable(aliases),
      read,
      index,
      includes,
      wantsFinalPass,
      rejected,
    );
  }

  /// The names `Host` lines give, in the order they first appear: each
  /// pattern without a wildcard or negation, unless a negated pattern on
  /// its line matches it (Séance's `SshConfigImporter.hostAliases`).
  final List<String> aliases;

  /// Every block that can change a setting or leave a name out, in file
  /// order.
  final List<_Block> _read;

  /// The blocks in [_read] that a known host may apply to.
  final _BlockIndex _index;

  /// Whether a line includes another file.
  final bool _includes;

  /// Whether a `Match final` makes ssh read the config a final time.
  final bool _wantsFinalPass;

  /// Whether ssh rejects the whole config, whatever name it is given: it
  /// starts with a byte-order mark, or holds a `ProxyJump` or
  /// `CanonicalizeHostname` line ssh rejects.
  final bool _rejected;

  /// The settings ssh would use for [name], the host name you give it.
  SshConfigResolution resolve(String name) {
    if (_rejected) {
      return const UnresolvedSshSettings(UnresolvedReason.rejectedLine);
    }
    if (name.contains(_replacement)) {
      return const UnresolvedSshSettings(UnresolvedReason.undecodedName);
    }

    final reading = _Reading(name);
    if (_readPass(reading, name) case final reason?) {
      return UnresolvedSshSettings(reason);
    }
    if (reading.canonicalization case final value?
        when !_canonicalizationOff.contains(_asciiLower(value))) {
      return const UnresolvedSshSettings(UnresolvedReason.secondPass);
    }
    final host = reading.matchHost;
    if (host == null) {
      return const UnresolvedSshSettings(UnresolvedReason.hostNameToken);
    }
    // The name holds none, so the `HostName` does.
    if (host.contains(_replacement)) {
      return const UnresolvedSshSettings(UnresolvedReason.undecodedValue);
    }

    if (_includes) {
      // An included file could ask for the final pass and set anything
      // then, so only a name that fixes all of them is known.
      final (:port, :user, :identityFile, :route) = reading.dialing;
      if (port == null ||
          user == null ||
          identityFile == null ||
          route == null) {
        return const UnresolvedSshSettings(UnresolvedReason.secondPass);
      }
      return reading.finish(host, reading.dialing);
    }

    final firstPass = reading.dialing;
    reading.startFinalPass(sshCanonicalHost(host));
    if (_readPass(reading, reading.finalHost) case final reason?) {
      return UnresolvedSshSettings(reason);
    }
    if (_wantsFinalPass || reading.dialing == firstPass) {
      return reading.finish(host, reading.dialing);
    }

    // Without a `Match final` here, only /etc/ssh/ssh_config can ask for
    // the pass, so the outcome must not depend on it.
    return switch ((
      reading.finish(host, firstPass),
      reading.finish(host, reading.dialing),
    )) {
      (
        ResolvedSshSettings(host: final early),
        ResolvedSshSettings(host: final late),
      ) =>
        UnresolvedSshSettings(
          UnresolvedReason.secondPass,
          passes: (firstPass: early, finalPass: late),
        ),
      _ => const UnresolvedSshSettings(UnresolvedReason.secondPass),
    };
  }

  /// Reads the blocks that apply into [reading], on its pass, with `Host`
  /// patterns matching [host] (null when it cannot be known); the reason
  /// the name is unresolved, or null.
  UnresolvedReason? _readPass(_Reading reading, String? host) {
    final target = host == null ? null : _utf8Bytes(host);
    for (final block in target == null ? _read : _index.blocks(target)) {
      final applies = block.applies(target, reading);
      if (applies == _Applies.no) continue;
      if (block case _HostBlock(rejected: true)) {
        return UnresolvedReason.rejectedLine;
      }

      for (final line in block.lines) {
        final reason = reading.read(line, mayApply: applies == _Applies.maybe);
        if (reason != null) return reason;
      }
    }
    return null;
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

/// The values the engine dials with, beside the `HostName`.
typedef _Dialing = ({
  int? port,
  String? user,
  String? identityFile,
  ({bool command, String value})? route,
});

sealed class _Block {
  _Block(this.order);

  /// The block's place in the file.
  final int order;

  final List<_Line> lines = [];

  /// Whether the block applies on [reading]'s pass; `Host` patterns match
  /// [target], as [_utf8Bytes] gives it, or may match when it is null.
  _Applies applies(String? target, _Reading reading);
}

/// The lines before the first `Host` or `Match`: they apply to every name.
final class _Top extends _Block {
  _Top() : super(0);

  @override
  _Applies applies(String? target, _Reading reading) => _Applies.yes;
}

final class _HostBlock extends _Block {
  _HostBlock(super.order, List<String> patterns, {required this.rejected})
    : _patterns = [
        for (final pattern in patterns)
          if (pattern.isNotEmpty)
            pattern.startsWith('!')
                ? (negated: true, glob: _Glob(pattern.substring(1)))
                : (negated: false, glob: _Glob(pattern)),
      ];

  final List<({bool negated, _Glob glob})> _patterns;

  /// Whether ssh rejects the `Host` line, and so the whole config: a quote
  /// is left open, or a pattern is empty.
  final bool rejected;

  /// The patterns that are not negated, one of which must match.
  Iterable<_Glob> get positive => [
    for (final (:negated, :glob) in _patterns)
      if (!negated) glob,
  ];

  /// `readconf.c`'s `oHost`: a matching negated pattern ends the line and
  /// turns the block off. A pattern that is [_Glob.undecided] may match.
  /// An unknown target is an address in a form the import cannot tell
  /// ([sshCanonicalHost]): `*` matches it, a pattern without wildcards only if
  /// it looks like an address, and any other may.
  @override
  _Applies applies(String? target, _Reading reading) {
    var active = false;
    var mayActivate = false;
    var mayDeactivate = false;
    for (final (:negated, :glob) in _patterns) {
      final bool? matches = glob.undecided
          ? null
          : target != null
          ? glob.matches(target)
          : glob.matchesAll
          ? true
          : glob.literal && !looksLikeSshAddress(glob.pattern)
          ? false
          : null;
      if (matches == null) {
        mayActivate |= !negated;
        mayDeactivate |= negated;
        continue;
      }
      if (!matches) continue;
      if (negated) return _Applies.no;
      active = true;
    }
    if (active) return mayDeactivate ? _Applies.maybe : _Applies.yes;
    return mayActivate ? _Applies.maybe : _Applies.no;
  }
}

/// The blocks a known host may apply to, found without trying every block,
/// which keeps resolving every alias and hop of a large config fast. A
/// `Host` pattern without wildcards matches only itself, and one with a
/// wildcard only a host that starts with the bytes before its first
/// wildcard, or ends with those after its last, so a `Host` block is found
/// through those. Every other block (the lines before the first `Host` or
/// `Match`, `Match` blocks, and `Host` blocks with a pattern such as `*` or
/// `*a*` that fixes neither) is tried for every host.
final class _BlockIndex {
  final List<_Block> _always = [];
  final Map<String, List<_Block>> _exact = {};
  final Map<String, List<_Block>> _byStart = {};
  final Map<String, List<_Block>> _byEnd = {};

  /// The lengths of the keys in [_byStart] and [_byEnd].
  final Set<int> _startLengths = {};
  final Set<int> _endLengths = {};

  /// Adds [block], the next in file order.
  void add(_Block block) {
    if (block is! _HostBlock) {
      _always.add(block);
      return;
    }

    final exact = <String>{};
    final starts = <String>{};
    final ends = <String>{};
    for (final glob in block.positive) {
      if (glob.undecided) {
        _always.add(block);
        return;
      }

      final bytes = glob._bytes;
      final first = bytes.indexOf(_wildcards);
      if (first < 0) {
        exact.add(bytes);
      } else if (first > 0) {
        starts.add(bytes.substring(0, first));
      } else if (bytes.lastIndexOf(_wildcards) case final last
          when last < bytes.length - 1) {
        ends.add(bytes.substring(last + 1));
      } else {
        _always.add(block);
        return;
      }
    }
    for (final key in exact) {
      (_exact[key] ??= []).add(block);
    }
    for (final key in starts) {
      (_byStart[key] ??= []).add(block);
      _startLengths.add(key.length);
    }
    for (final key in ends) {
      (_byEnd[key] ??= []).add(block);
      _endLengths.add(key.length);
    }
  }

  /// The blocks that may apply to [target], as [_utf8Bytes] gives it, in
  /// file order.
  List<_Block> blocks(String target) {
    final found = <_Block>[
      ...?_exact[target],
      for (final length in _startLengths)
        if (length <= target.length) ...?_byStart[target.substring(0, length)],
      for (final length in _endLengths)
        if (length <= target.length)
          ...?_byEnd[target.substring(target.length - length)],
    ];
    if (found.isEmpty) return _always;

    // A block is in [_always] or found through its patterns, maybe more
    // than one of them.
    found.sort((a, b) => a.order.compareTo(b.order));
    final merged = <_Block>[];
    var next = 0;
    var nextFound = 0;
    while (next < _always.length || nextFound < found.length) {
      final takeFound =
          next == _always.length ||
          (nextFound < found.length &&
              found[nextFound].order < _always[next].order);
      final block = takeFound ? found[nextFound++] : _always[next++];
      if (!identical(merged.lastOrNull, block)) merged.add(block);
    }
    return merged;
  }
}

/// A `match_pattern()` wildcard.
final RegExp _wildcards = RegExp(r'[*?]');

/// A `Match` criterion, as `match_cfg_line()` reads it.
enum _Criterion { all, finalPass, host, originalHost, unknown }

final class _MatchBlock extends _Block {
  _MatchBlock._(
    super.order,
    this._criteria, {
    required this.malformed,
    required this.wantsFinalPass,
  });

  /// `match_cfg_line()`'s reading of a `Match` line's [arguments]; ssh
  /// rejects one with an [openQuote] before it reads them.
  factory _MatchBlock.parse(
    int order,
    List<String> arguments, {
    required bool openQuote,
  }) {
    final criteria = <({_Criterion kind, bool negated, _HostList? list})>[];
    var wantsFinalPass = false;
    var attributes = 0;
    var index = 0;

    _MatchBlock done({bool malformed = false}) => _MatchBlock._(
      order,
      criteria,
      malformed: malformed || openQuote,
      wantsFinalPass: wantsFinalPass,
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
        wantsFinalPass |= lowered == 'final';
        criteria.add((
          kind: _Criterion.finalPass,
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
  /// final time, for every name.
  final bool wantsFinalPass;

  @override
  _Applies applies(String? target, _Reading reading) {
    if (malformed) return _Applies.maybe;

    var unknown = false;
    for (final (:kind, :negated, :list) in _criteria) {
      final bool? holds = switch (kind) {
        _Criterion.all => true,
        _Criterion.finalPass => reading.finalPass,
        _Criterion.host => switch (reading.matchHost) {
          null => null,
          final host => list!.matches(host),
        },
        _Criterion.originalHost => list!.matches(reading.name),
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

  /// Whether this is ssh's final pass, on which `HostName` and
  /// `CanonicalizeHostname` no longer matter.
  bool finalPass = false;

  /// On the final pass, the host ssh matches `Host` and `Match host`
  /// against ([sshCanonicalHost]); null when it cannot be known.
  String? finalHost;

  /// Starts the final pass, matching [host].
  void startFinalPass(String? host) {
    finalPass = true;
    finalHost = host;
  }

  /// The host a `Match host` compares: on the first pass the `HostName`
  /// read so far with `%h` expanded, else the name, and null when ssh
  /// would exit expanding it; on the final pass [finalHost].
  String? get matchHost => finalPass
      ? finalHost
      : switch (hostName) {
          null => name,
          final value => _expandHostName(value, name),
        };

  /// The values the engine dials with, which the final pass must not
  /// change unless the file asks for it.
  _Dialing get dialing =>
      (port: port, user: user, identityFile: identityFile, route: route);

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
      _Keyword.port => single == null || parseSshPort(single) == null,
      _Keyword.proxyJump || _Keyword.proxyCommand => line.rest.isEmpty,
      _ => single == null,
    }) {
      return UnresolvedReason.rejectedLine;
    }

    return switch (line.keyword) {
      _Keyword.hostName => first(
        hostName == null && !finalPass,
        () => hostName = single,
      ),
      _Keyword.port => first(port == null, () => port = parseSshPort(single!)),
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
        canonicalization == null && !finalPass,
        () => canonicalization = single,
      ),
      _Keyword.include => UnresolvedReason.include,
    };
  }

  /// The settings, once every block has been read, for [host], the
  /// `HostName` with `%h` expanded, dialing with [values].
  SshConfigResolution finish(String host, _Dialing values) {
    final (:port, :user, identityFile: key, :route) = values;
    if (route != null &&
        route.command &&
        _asciiLower(route.value) != _noProxyCommand) {
      return const UnresolvedSshSettings(UnresolvedReason.proxyCommand);
    }
    if (key != null && !isImportedIdentityFile(key)) {
      return const UnresolvedSshSettings(UnresolvedReason.identityFileToken);
    }
    if ((user?.contains(_replacement) ?? false) ||
        (key?.contains(_replacement) ?? false)) {
      return const UnresolvedSshSettings(UnresolvedReason.undecodedValue);
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

/// The port ssh's `a2port()` reads from [value], above 0, or null where
/// ssh reports "Bad port" or [value] names a service not in
/// [_servicePorts], for a `Port` or a port in a `ProxyJump`.
int? parseSshPort(String value) {
  if (!_decimal.hasMatch(value)) return _servicePorts[value];

  // null when the digits overflow an int, which is out of range too.
  final port = int.tryParse(value);
  return port == null || !isTcpPort(port) ? null : port;
}

/// One config line as `readconf.c`'s `process_config_line_depth()`
/// splits it. A NUL ends the line, as it ends a C string, and only
/// [_lineEnd] is stripped from its end. `strdelim()` ends the keyword at
/// [_whitespace], `=` or a quote, which it drops; one `=` and the
/// whitespace around it may follow. `argv_split()` then splits the rest
/// at spaces and tabs alone: a quote keeps them in an argument and is
/// dropped, a backslash escapes a quote, a backslash and, outside quotes,
/// a space, and a `#` where an argument would start ends the line.
final class _ConfigLine {
  _ConfigLine._(this.keyword, String rest)
    : command = _skip(rest, '$_whitespace='),
      _split = _argvSplit(rest);

  /// Splits [raw]; null for a line ssh skips: blank, a comment, or a
  /// keyword with a quote left open.
  static _ConfigLine? parse(String raw) {
    final nul = raw.indexOf('\u0000');
    var line = nul < 0 ? raw : raw.substring(0, nul);

    // The first character stays, as in ssh.
    var end = line.length;
    while (end > 1 && _lineEnd.contains(line[end - 1])) {
      end--;
    }
    line = line.substring(0, end);

    var (keyword, rest) = _strdelim(line);
    if (keyword == null) return null;
    if (keyword.isEmpty) (keyword, rest) = _strdelim(rest);
    if (keyword == null || keyword.isEmpty || keyword.startsWith('#')) {
      return null;
    }
    return _ConfigLine._(_asciiLower(keyword), _skip(rest ?? '', _whitespace));
  }

  /// The keyword, ASCII-lowercased, as `lowercase()` does.
  final String keyword;

  /// The value ssh hands `ProxyJump` and `ProxyCommand`: the rest of the
  /// line after the whitespace and `=` that start it.
  final String command;

  final ({List<String> arguments, bool openQuote}) _split;

  /// The arguments, unquoted and unescaped; empty when the line has none.
  List<String> get arguments => _split.arguments;

  /// Whether a quote is left open, on which ssh rejects the line and the
  /// whole config ("invalid quotes").
  bool get openQuote => _split.openQuote;

  /// `strdelim()` on [text]: the token at its start, or null with a quote
  /// left open, and the text after the token and the delimiters that end
  /// it, or null when nothing ends it.
  static (String?, String?) _strdelim(String? text) {
    if (text == null) return (null, null);

    var at = 0;
    while (at < text.length && !'$_whitespace"='.contains(text[at])) {
      at++;
    }
    if (at == text.length) return (text, null);

    if (text[at] == '"') {
      final unquoted = text.substring(0, at) + text.substring(at + 1);
      final close = unquoted.indexOf('"', at);
      if (close < 0) return (null, null);
      return (
        unquoted.substring(0, close),
        _skip(unquoted.substring(close + 1), _whitespace),
      );
    }

    var rest = _skip(text.substring(at + 1), _whitespace);
    // Only one `=` may separate.
    if (text[at] != '=' && rest.startsWith('=')) {
      rest = _skip(rest.substring(1), _whitespace);
    }
    return (text.substring(0, at), rest);
  }

  /// [text] without the [characters] that start it.
  static String _skip(String text, String characters) {
    var at = 0;
    while (at < text.length && characters.contains(text[at])) {
      at++;
    }
    return text.substring(at);
  }

  /// `argv_split()` on [text], ending at a comment.
  static ({List<String> arguments, bool openQuote}) _argvSplit(String text) {
    final arguments = <String>[];
    var index = 0;
    while (index < text.length) {
      final character = text[index];
      if (character == ' ' || character == '\t') {
        index++;
        continue;
      }
      if (character == '#') break;

      final argument = StringBuffer();
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
          argument.write(escapes ? next : c);
        } else if (quote == null && (c == ' ' || c == '\t')) {
          break;
        } else if (quote == null && (c == '"' || c == "'")) {
          quote = c;
        } else if (c == quote) {
          quote = null;
        } else {
          argument.write(c);
        }
      }
      arguments.add(argument.toString());
      if (quote != null) return (arguments: arguments, openQuote: true);
    }
    return (arguments: arguments, openQuote: false);
  }
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

/// The host ssh dials once it has read the config, and matches `Host` and
/// `Match host` against on its final pass (`ssh.c`), for [host], the
/// `HostName` with `%h` expanded: lowercased unless it is an address, and
/// an address as `getnameinfo()` writes it, unless only its case differs. Null when the import cannot know it: for
/// an address with a scope, whose form depends on the device's
/// interfaces, one Dart does not parse though the system resolver may
/// (`10.1`), or a host holding U+FFFD.
String? sshCanonicalHost(String host) {
  if (host.contains(_replacement)) return null;
  if (!_isAddress(host)) return _asciiLower(host);
  if (host.contains('%')) return null;

  final address = InternetAddress.tryParse(host);
  if (address == null) return null;
  final written = InternetAddress.fromRawAddress(address.rawAddress).address;
  return _asciiLower(written) == _asciiLower(host) ? host : written;
}

/// ssh's `is_addr()`: [looksLikeSshAddress], or a name that parses as an IP
/// address.
bool _isAddress(String host) =>
    looksLikeSshAddress(host) || InternetAddress.tryParse(host) != null;

/// ssh's `is_addr_fast()`: a `%`, a `:` or nothing but digits and dots.
/// Every form ssh may give an address on its final pass looks like this.
bool looksLikeSshAddress(String host) =>
    host.contains('%') || host.contains(':') || _digitsAndDots.hasMatch(host);

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

/// [text] as its UTF-8 bytes, one character for each byte: ssh compares
/// bytes, so a `?` matches one byte. ASCII is its own bytes.
String _utf8Bytes(String text) {
  for (final unit in text.codeUnits) {
    if (unit >= 0x80) return String.fromCharCodes(utf8.encode(text));
  }
  return text;
}

/// ssh's `match_pattern()` on [text] and [pattern] as [_utf8Bytes] gives
/// them: `*` matches any run of bytes, `?` any one, and every other byte
/// itself.
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
  _Glob(this.pattern) : _bytes = _utf8Bytes(pattern) {
    _pieces = _bytes.contains('?') ? null : _bytes.split('*');
    undecided = pattern.contains(_replacement) && (_pieces?.length ?? 2) > 1;
  }

  /// The pattern as written.
  final String pattern;

  /// [pattern] as [_utf8Bytes] gives it.
  final String _bytes;

  /// The pieces between the `*`s, or null when the pattern holds a `?`.
  late final List<String>? _pieces;

  /// Whether the pattern is nothing but `*`, which matches any text.
  bool get matchesAll => _pieces?.every((piece) => piece.isEmpty) ?? false;

  /// Whether the pattern holds no wildcard, so it matches only itself.
  bool get literal => _pieces?.length == 1;

  /// Whether the pattern holds a wildcard and U+FFFD, so what it matches
  /// depends on bytes the import cannot know. Without a wildcard it
  /// matches no name it resolves: bytes that are not UTF-8 never equal a
  /// name that is, and a name holding U+FFFD is not resolved.
  late final bool undecided;

  /// Whether the pattern matches [text], given as [_utf8Bytes] gives it.
  bool matches(String text) {
    final pieces = _pieces;
    if (pieces == null) return _matchPattern(text, _bytes);
    if (pieces.length == 1) return text == _bytes;

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
/// for `match_hostname()`. A subpattern of 1023 bytes or more makes the
/// list match nothing where ssh reaches it, so it is kept as null.
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
      final pattern = _asciiLower(list.substring(index, end));
      entries.add(
        _utf8Bytes(pattern).length >= _maximumSubpatternLength
            ? null
            : (negated: negated, glob: _Glob(pattern)),
      );
      index = end < list.length ? end + 1 : end;
    }
    return _HostList._(entries);
  }

  final List<({bool negated, _Glob glob})?> _entries;

  /// Whether ssh's `match_hostname()` for [host], lowercased, is a match:
  /// a pattern matches and no negated one does. Null when a pattern that
  /// is [_Glob.undecided] could change that.
  bool? matches(String host) {
    final text = _utf8Bytes(_asciiLower(host));
    var positive = false;
    var mayMatch = false;
    var mayFail = false;
    for (final entry in _entries) {
      if (entry == null) return false;
      if (entry.glob.undecided) {
        mayMatch |= !entry.negated;
        mayFail |= entry.negated;
        continue;
      }
      if (!entry.glob.matches(text)) continue;
      if (entry.negated) return false;
      positive = true;
    }
    if (positive) return mayFail ? null : true;
    return mayMatch ? null : false;
  }
}
