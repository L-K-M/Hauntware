import 'package:seance_protocol/seance_protocol.dart';

import 'ssh_config_settings.dart';

/// One host name from a `Host` line of an OpenSSH `config` file, with the
/// settings of its block.
class ImportedHost {
  final String alias;
  final String? hostName;
  final int? port;
  final String? user;
  final String? identityFile;
  final String? proxyJump;

  const ImportedHost({
    required this.alias,
    this.hostName,
    this.port,
    this.user,
    this.identityFile,
    this.proxyJump,
  });

  /// Effective hostname to connect to (falls back to the alias, as ssh does).
  String get effectiveHost => hostName ?? alias;

  /// Build a Séance [ServerConfig] from this entry. An `IdentityFile` becomes a
  /// "reference, don't store" private-key config; otherwise use ssh-agent,
  /// matching OpenSSH's default key discovery.
  ServerConfig toServerConfig({required String id, required int now}) {
    final hasKey = identityFile != null && identityFile!.trim().isNotEmpty;
    return ServerConfig(
      id: id,
      label: alias,
      host: effectiveHost,
      port: port ?? 22,
      username: user ?? '',
      authMethod: hasKey ? AuthMethod.privateKey : AuthMethod.agent,
      identityFilePath: hasKey ? identityFile : null,
      createdAt: now,
      updatedAt: now,
    );
  }
}

/// Why [SshConfigImporter] left a host out.
enum SkippedHostReason {
  /// The importer refuses the block's `Port`: one ssh rejects, or a service
  /// name other than `ssh`, `http` or `https` (see [SshConfigImporter]).
  invalidPort,
}

/// A host [SshConfigImporter] left out because its block is invalid.
class SkippedHost {
  /// The block's other settings, to show what was left out. Its
  /// [ImportedHost.port] is null; never import it.
  final ImportedHost host;

  final SkippedHostReason reason;

  /// The refused argument as written, such as `22a`; empty when the
  /// directive had none.
  final String value;

  /// The 1-based line number of the refused directive.
  final int line;

  const SkippedHost({
    required this.host,
    required this.reason,
    required this.value,
    required this.line,
  });
}

/// What [SshConfigImporter.parse] read from a config.
class SshConfigImport {
  /// Hosts to import, in file order.
  final List<ImportedHost> hosts;

  /// Hosts left out because their block is invalid, in file order.
  final List<SkippedHost> skipped;

  /// Aliases imported with [hosts] whose values are best-effort: ssh's own
  /// result depends on something this importer cannot evaluate, so their
  /// entry is the block-local reading rather than ssh's. Empty when every
  /// imported alias resolved.
  final Set<String> approximate;

  const SshConfigImport({
    required this.hosts,
    required this.skipped,
    this.approximate = const <String>{},
  });
}

/// A read-only importer for `~/.ssh/config`.
///
/// The shared resolver ([SshConfigSettings]) reads the file as ssh does:
/// `Host *` and top-level defaults apply, later matching blocks add what is
/// still unset, known `Match` criteria are evaluated, arguments are split
/// and unquoted as ssh splits them, and `%h`/`%%` expand. Every alias the
/// resolver resolves is imported with those values.
///
/// An alias the resolver leaves unresolved keeps the block-local reading
/// below: no host that reading imports disappears, a repeated alias keeps
/// its entries, and the alias joins [SshConfigImport.approximate]. Such a
/// host may connect differently than ssh would, because an `Include`, a
/// `Match` criterion such as `exec`, a tokenized value or another
/// unreadable construct decides what ssh would do.
///
/// The block-local reading parses `Host`, `HostName`, `Port`, `User`,
/// `IdentityFile` and `ProxyJump`, ignores `Match` and `Include` (an
/// `Include` line is stored as an unused directive), and takes each name a
/// `Host` line gives ([hostAliases]) as its own host with only its block's
/// directives. Wildcard and negated patterns are not names, so a block with
/// only those (e.g. `Host *`) describes defaults rather than a connectable
/// server and contributes no host.
///
/// In that reading, `Port` is read as ssh's `a2port()` reads it: a decimal
/// 1 to 65535, or a service name. ssh resolves names with
/// `getservbyname(3)`, which Dart cannot call portably, so only `ssh`,
/// `http` and `https` are known here. Any other value refuses the block's
/// aliases into [SshConfigImport.skipped], with the value and line. A
/// `Port` outside the imported blocks (before the first `Host`, in a
/// wildcard-only block or in a `Match` block) is not read there.
class SshConfigImporter {
  static const int _minimumPort = 1;
  static const int _maximumPort = 65535;

  /// The service names a `Port` may give instead of a number, with their
  /// TCP ports from the IANA registry.
  static const Map<String, int> _servicePorts = {
    'ssh': 22,
    'http': 80,
    'https': 443,
  };

  /// A base-10 integer with an optional sign, as `strtonum()` reads it.
  static final RegExp _decimal = RegExp(r'^[+-]?[0-9]+$');

  /// Parse the text of an ssh config file into importable hosts, and the
  /// hosts left out because their block is invalid. Aliases the shared
  /// resolver settles import with ssh's own values; every other alias keeps
  /// the block-local outcome, marked in [SshConfigImport.approximate] when
  /// it imports.
  static SshConfigImport parse(String text) {
    final legacy = _parseBlocks(text);
    final settings = SshConfigSettings.parse(text);

    final resolved = <String, ImportedHost>{};
    for (final alias in settings.aliases) {
      if (settings.resolve(alias) case ResolvedSshSettings(host: final host)) {
        resolved[alias] = host;
      }
    }

    final hosts = <ImportedHost>[];
    final approximate = <String>{};
    final imported = <String>{};
    for (final host in legacy.hosts) {
      final exact = resolved[host.alias];
      if (exact == null) {
        hosts.add(host);
        approximate.add(host.alias);
        continue;
      }
      // One entry per alias, at its first appearance.
      if (imported.add(host.alias)) hosts.add(exact);
    }

    // An alias ssh resolves where the block-local reader had nothing to
    // import joins at its first appearance in the file.
    final order = <String, int>{
      for (final (index, alias) in settings.aliases.indexed) alias: index,
    };
    for (final alias in settings.aliases) {
      final host = resolved[alias];
      if (host == null || imported.contains(alias)) continue;
      var at = hosts.length;
      for (var index = 0; index < hosts.length; index++) {
        final position = order[hosts[index].alias];
        if (position != null && position > order[alias]!) {
          at = index;
          break;
        }
      }
      hosts.insert(at, host);
      imported.add(alias);
    }

    final skipped = <SkippedHost>[
      for (final skip in legacy.skipped)
        if (!resolved.containsKey(skip.host.alias)) skip,
    ];
    return SshConfigImport(
      hosts: List.unmodifiable(hosts),
      skipped: List.unmodifiable(skipped),
      approximate: Set.unmodifiable(approximate),
    );
  }

  /// The block-local reading this importer keeps: one [ImportedHost] per
  /// name a `Host` line gives, carrying only its block's directives, and
  /// the [SkippedHost]s of the blocks whose `Port` it refuses.
  static ({List<ImportedHost> hosts, List<SkippedHost> skipped}) _parseBlocks(
    String text,
  ) {
    final blocks = <_Block>[];
    _Block? current;

    for (final (index, raw) in text.split('\n').indexed) {
      final line = SshConfigLine.tryParse(raw);
      if (line == null) continue;

      if (line.keyword == 'host') {
        // A Host line may list several patterns; keep them all for filtering.
        current = _Block(patterns: line.arguments);
        blocks.add(current);
      } else if (line.keyword == 'match') {
        // Match blocks are conditional; ignore their directives for import.
        current = null;
      } else if (current != null && line.keyword == 'port') {
        // ssh checks every Port line, so a bad one is not hidden by a
        // valid one elsewhere in the block.
        final value = line.arguments.firstOrNull ?? '';
        final port = _parsePort(value);
        if (port == null) {
          current.badPort ??= (line: index + 1, value: value);
        } else {
          // ssh keeps the first value it obtains for a setting.
          current.port ??= port;
        }
      } else if (current != null) {
        // ssh reads a directive's first argument and rejects the line when
        // it is missing, empty or followed by more; the importer reads the
        // first one and treats a missing or empty one as absent.
        // The first value ssh obtains for a setting wins, so a later line
        // in the block does not replace it (Klabautermann's import reads
        // the file the same way).
        final value = line.arguments.firstOrNull;
        if (value != null && value.isNotEmpty) {
          current.directives.putIfAbsent(line.keyword, () => value);
        }
      }
    }

    final hosts = <ImportedHost>[];
    final skipped = <SkippedHost>[];
    for (final block in blocks) {
      final d = block.directives;
      final badPort = block.badPort;
      // A block without names (e.g. `Host *`) holds defaults, not a host.
      for (final alias in hostAliases(block.patterns)) {
        final host = ImportedHost(
          alias: alias,
          hostName: _expandHostName(d['hostname'], alias),
          port: badPort == null ? block.port : null,
          user: d['user'],
          identityFile: _identityFile(d['identityfile']),
          proxyJump: d['proxyjump'],
        );
        if (badPort == null) {
          hosts.add(host);
        } else {
          skipped.add(
            SkippedHost(
              host: host,
              reason: SkippedHostReason.invalidPort,
              value: badPort.value,
              line: badPort.line,
            ),
          );
        }
      }
    }
    return (
      hosts: List.unmodifiable(hosts),
      skipped: List.unmodifiable(skipped),
    );
  }

  /// [value] with the tokens ssh expands in `HostName`: `%h`, the name
  /// given to ssh ([alias]), and `%%`, a percent sign. ssh allows no other
  /// token there; one is kept as written.
  static String? _expandHostName(String? value, String alias) =>
      value?.replaceAllMapped(
        RegExp('%([%h])'),
        (match) => match[1] == 'h' ? alias : '%',
      );

  /// The key file an `IdentityFile` [value] names, or null for none:
  /// `IdentityFile none` (any case) tells ssh to use no key file, so the
  /// host signs in through the agent rather than with a file named
  /// "none".
  static String? _identityFile(String? value) {
    if (value == null || value.toLowerCase() == 'none') return null;
    return _expandTilde(value);
  }

  /// The port ssh's `a2port()` reads from [value], or null where ssh
  /// reports "Bad port" or [value] names a service not in [_servicePorts].
  static int? _parsePort(String value) {
    if (!_decimal.hasMatch(value)) return _servicePorts[value];

    // null when the digits overflow an int, which is out of range too.
    final port = int.tryParse(value);
    if (port == null || port < _minimumPort || port > _maximumPort) {
      return null;
    }
    return port;
  }

  /// The names in a `Host` line's [patterns] that you could give ssh to
  /// use the block: each pattern without a wildcard (`*`, `?`) or negation
  /// (`!`), in order and once. A name a negated pattern on the same line
  /// matches is left out, since ssh skips the block for it.
  static List<String> hostAliases(List<String> patterns) {
    final negated = [
      for (final pattern in patterns)
        if (pattern.startsWith('!')) pattern.substring(1),
    ];
    final aliases = <String>[];
    for (final pattern in patterns) {
      if (pattern.isEmpty || _isWildcard(pattern)) continue;
      if (aliases.contains(pattern)) continue;
      if (negated.any((n) => _matchesPattern(pattern, n))) continue;
      aliases.add(pattern);
    }
    return aliases;
  }

  static bool _isWildcard(String pattern) =>
      pattern.contains('*') || pattern.contains('?') || pattern.startsWith('!');

  /// ssh's `match_pattern()`: `*` matches any run of characters, `?` any
  /// one character, and every other character itself, case-sensitively.
  static bool _matchesPattern(String name, String pattern) {
    final regex = StringBuffer('^');
    for (final c in pattern.split('')) {
      regex.write(switch (c) {
        '*' => '.*',
        '?' => '.',
        _ => RegExp.escape(c),
      });
    }
    regex.write(r'$');
    return RegExp(regex.toString(), dotAll: true).hasMatch(name);
  }

  static String? _expandTilde(String? path) {
    if (path == null) return null;
    // Leave ~ in place; the app resolves it against the real home directory,
    // which this pure package must not assume.
    return path;
  }
}

/// One line of an ssh config, split the way OpenSSH's `readconf.c` and
/// `argv_split()` split it:
///
/// - the keyword ends at the first space, tab or `=`, and one `=`, with
///   any whitespace around it, may separate it from the arguments, so
///   `HostName x`, `HostName=x` and `HostName = x` all read `x`;
/// - arguments are separated by spaces and tabs; double or single quotes
///   keep spaces and `#` inside one argument and are removed;
/// - a backslash escapes a quote, a backslash or, outside quotes, a space;
///   any other backslash is kept;
/// - a `#` where an argument would start begins a comment, while one
///   inside an argument (`jump#2`) is part of it.
///
/// ssh rejects a line with an unterminated quote; here the quoted argument
/// runs to the end of the line instead.
class SshConfigLine {
  /// The keyword, lowercased: ssh config keywords are case-insensitive.
  final String keyword;

  /// The arguments, unquoted and unescaped; empty when the line has none.
  final List<String> arguments;

  const SshConfigLine._(this.keyword, this.arguments);

  /// Splits [line]; null for a blank or comment line.
  static SshConfigLine? tryParse(String line) {
    final text = line.trim();
    if (text.isEmpty || text.startsWith('#')) return null;

    var end = 0;
    while (end < text.length && !_isKeywordEnd(text[end])) {
      end++;
    }
    final keyword = text.substring(0, end).toLowerCase();

    // Skip whitespace and at most one `=`, as ssh's strdelim() does.
    var start = end;
    var sawEquals = false;
    while (start < text.length) {
      final c = text[start];
      if (c == '=' && !sawEquals) {
        sawEquals = true;
      } else if (!_isLineWhitespace(c)) {
        break;
      }
      start++;
    }
    return SshConfigLine._(keyword, _splitArguments(text.substring(start)));
  }

  static bool _isKeywordEnd(String c) => c == '=' || _isLineWhitespace(c);

  /// The whitespace ssh's strdelim() skips around a keyword.
  static bool _isLineWhitespace(String c) =>
      c == ' ' || c == '\t' || c == '\r' || c == '\n';

  /// The whitespace argv_split() separates arguments with.
  static bool _isArgumentSeparator(String c) => c == ' ' || c == '\t';

  static List<String> _splitArguments(String text) {
    final arguments = <String>[];
    var i = 0;
    while (i < text.length) {
      if (_isArgumentSeparator(text[i])) {
        i++;
        continue;
      }
      if (text[i] == '#') break;

      final argument = StringBuffer();
      String? quote;
      for (; i < text.length; i++) {
        final c = text[i];
        final next = i + 1 < text.length ? text[i + 1] : null;
        if (c == r'\' && next != null && _isEscapable(next, quote)) {
          argument.write(next);
          i++;
        } else if (quote == null && _isArgumentSeparator(c)) {
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
    }
    return arguments;
  }

  static bool _isEscapable(String c, String? quote) =>
      c == '"' || c == "'" || c == r'\' || (quote == null && c == ' ');
}

class _Block {
  final List<String> patterns;
  final Map<String, String> directives = {};

  /// The first valid `Port`: ssh keeps the first value it obtains, as for
  /// every other directive here.
  int? port;

  /// The first `Port` the importer refuses, which makes the block invalid.
  ({int line, String value})? badPort;

  _Block({required this.patterns});
}
