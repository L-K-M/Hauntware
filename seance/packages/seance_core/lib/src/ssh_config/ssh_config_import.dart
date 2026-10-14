import 'package:seance_protocol/seance_protocol.dart';

/// One `Host` block parsed from an OpenSSH `config` file.
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
  /// The block's `Port` is not a port ssh accepts (see [SshConfigImporter]).
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

  const SshConfigImport({required this.hosts, required this.skipped});
}

/// A read-only importer for `~/.ssh/config`. Parses the common directives
/// (`Host`, `HostName`, `Port`, `User`, `IdentityFile`, `ProxyJump`) and skips
/// everything else. Wildcard-only host patterns (e.g. `Host *`) are dropped,
/// since they describe defaults rather than a connectable server. Lines are
/// split as ssh splits them ([SshConfigLine]): `Key value`, `Key=value` and
/// `Key = value` are equivalent, and quoted arguments are unquoted.
///
/// `Port` is read as ssh's `a2port()` reads it: a decimal 1 to 65535, or a
/// service name. ssh resolves names with `getservbyname(3)`, which Dart
/// cannot call portably, so only `ssh`, `http` and `https` are known here.
/// ssh rejects the whole config over any other `Port`; the importer leaves
/// out only the hosts of that block and reports them in
/// [SshConfigImport.skipped]. A `Port` outside the imported blocks (before
/// the first `Host`, in a wildcard-only block or in a `Match` block) is not
/// read, so it is not checked either.
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
  /// hosts left out because their block is invalid.
  static SshConfigImport parse(String text) {
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
          current.port = port;
        }
      } else if (current != null) {
        // ssh reads a directive's first argument and rejects the line when
        // it is missing, empty or followed by more; the importer reads the
        // first one and treats a missing or empty one as absent.
        final value = line.arguments.firstOrNull;
        if (value != null && value.isNotEmpty) {
          current.directives[line.keyword] = value;
        }
      }
    }

    final hosts = <ImportedHost>[];
    final skipped = <SkippedHost>[];
    for (final block in blocks) {
      final alias = block.patterns.firstWhere(
        (p) => !_isWildcard(p),
        orElse: () => '',
      );
      if (alias.isEmpty) continue; // wildcard-only block: defaults, not a host
      final d = block.directives;
      final badPort = block.badPort;
      final host = ImportedHost(
        alias: alias,
        hostName: d['hostname'],
        port: badPort == null ? block.port : null,
        user: d['user'],
        identityFile: _expandTilde(d['identityfile']),
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
    return SshConfigImport(
      hosts: List.unmodifiable(hosts),
      skipped: List.unmodifiable(skipped),
    );
  }

  /// The port ssh's `a2port()` reads from [value], or null where ssh
  /// reports "Bad port".
  static int? _parsePort(String value) {
    if (!_decimal.hasMatch(value)) return _servicePorts[value];

    // null when the digits overflow an int, which is out of range too.
    final port = int.tryParse(value);
    if (port == null || port < _minimumPort || port > _maximumPort) {
      return null;
    }
    return port;
  }

  static bool _isWildcard(String pattern) =>
      pattern.contains('*') || pattern.contains('?') || pattern.startsWith('!');

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

  /// The last valid `Port`, like every other directive here.
  int? port;

  /// The first `Port` ssh would reject, which makes the block invalid.
  ({int line, String value})? badPort;

  _Block({required this.patterns});
}
