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

/// A read-only importer for `~/.ssh/config`. Parses the common directives
/// (`Host`, `HostName`, `Port`, `User`, `IdentityFile`, `ProxyJump`) and skips
/// everything else. Wildcard-only host patterns (e.g. `Host *`) are dropped,
/// since they describe defaults rather than a connectable server. Lines are
/// split as ssh splits them ([SshConfigLine]): `Key value`, `Key=value` and
/// `Key = value` are equivalent, and quoted arguments are unquoted.
class SshConfigImporter {
  /// Parse the text of an ssh config file into importable hosts.
  static List<ImportedHost> parse(String text) {
    final blocks = <_Block>[];
    _Block? current;

    for (final raw in text.split('\n')) {
      final line = SshConfigLine.tryParse(raw);
      if (line == null) continue;

      if (line.keyword == 'host') {
        // A Host line may list several patterns; keep them all for filtering.
        current = _Block(patterns: line.arguments);
        blocks.add(current);
      } else if (line.keyword == 'match') {
        // Match blocks are conditional; ignore their directives for import.
        current = null;
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
    for (final block in blocks) {
      final alias = block.patterns.firstWhere(
        (p) => !_isWildcard(p),
        orElse: () => '',
      );
      if (alias.isEmpty) continue; // wildcard-only block: defaults, not a host
      final d = block.directives;
      hosts.add(ImportedHost(
        alias: alias,
        hostName: d['hostname'],
        port: d['port'] != null ? int.tryParse(d['port']!) : null,
        user: d['user'],
        identityFile: _expandTilde(d['identityfile']),
        proxyJump: d['proxyjump'],
      ));
    }
    return hosts;
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
  _Block({required this.patterns});
}
