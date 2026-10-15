/// Parsers for the `identity` slow-collector payload (03 §6.4):
/// /etc/os-release, `uname -s -r -m`, and `hostnamectl --json=short` with
/// fallback to os-release when the JSON flag does not exist (systemd
/// below 249) or the tool is absent.
library;

import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../hws/program.dart' show kTimeoutAbsentMarker;
import 'models.dart' show splitBlocks;
import 'parse_result.dart';

/// Parsed /etc/os-release (os-release(5)), keys verbatim.
@immutable
final class OsRelease {
  OsRelease(Map<String, String> fields) : fields = Map.unmodifiable(fields);

  /// `KEY` to unquoted value (missing keys stay absent).
  final Map<String, String> fields;

  String? get id => fields['ID'];
  String? get idLike => fields['ID_LIKE'];
  String? get versionId => fields['VERSION_ID'];
  String? get prettyName => fields['PRETTY_NAME'];
  String? get name => fields['NAME'];
  String? get versionCodename => fields['VERSION_CODENAME'];

  Map<String, Object?> toJson() => {'fields': fields};
}

/// Parses /etc/os-release `KEY=value` lines: optional quotes removed,
/// backslash escapes resolved for the characters os-release(5) allows
/// (`"`, `'`, `\`, `` ` ``, `$`), comments and malformed lines tolerated.
OsRelease parseOsReleaseLines(List<String> lines, List<String> warnings) {
  final fields = <String, String>{};
  for (final line in lines) {
    final t = line.trimRight();
    if (t.isEmpty || t.startsWith('#')) continue;
    final eq = t.indexOf('=');
    if (eq <= 0) {
      warnings.add('os-release: malformed line');
      continue;
    }
    fields[t.substring(0, eq)] = _unquoteOsRelease(t.substring(eq + 1));
  }
  return OsRelease(fields);
}

String _unquoteOsRelease(String raw) {
  var v = raw.trim();
  if (v.length >= 2) {
    final q = v[0];
    if ((q == '"' || q == "'") && v.endsWith(q)) {
      v = v.substring(1, v.length - 1);
    }
  }
  if (!v.contains(r'\')) return v;
  final b = StringBuffer();
  for (var i = 0; i < v.length; i++) {
    final c = v[i];
    if (c == r'\' && i + 1 < v.length) {
      final n = v[i + 1];
      if (n == '"' || n == "'" || n == r'\' || n == r'$' || n == '`') {
        b.write(n);
        i++;
        continue;
      }
    }
    b.write(c);
  }
  return b.toString();
}

/// The `identity` section parsed (03 §6.4).
@immutable
final class IdentitySnapshot {
  IdentitySnapshot({
    this.osRelease,
    this.kernelName,
    this.kernelRelease,
    this.kernelArch,
    Map<String, Object?>? hostnamectl,
    this.timeoutAbsent = false,
  }) : hostnamectl = Map.unmodifiable(hostnamectl ?? {});

  /// /etc/os-release fields (empty map when the file was absent).
  final OsRelease? osRelease;

  /// `uname -s -r -m`, split.
  final String? kernelName, kernelRelease, kernelArch;

  /// The decoded `hostnamectl --json=short` object; empty when the tool or
  /// flag was absent, which is normal below systemd 249.
  final Map<String, Object?> hostnamectl;

  /// True when the payload ran without a `timeout` guard (03 §6.3).
  final bool timeoutAbsent;

  /// Kernel name: hostnamectl wins, then uname.
  String? get effectiveKernelName => _text('KernelName') ?? kernelName;

  /// Kernel release: hostnamectl wins, then uname.
  String? get effectiveKernelRelease => _text('KernelRelease') ?? kernelRelease;

  /// OS pretty name: hostnamectl wins, then os-release (03 §6.1).
  String? get effectiveOsPrettyName =>
      _text('OperatingSystemPrettyName') ?? osRelease?.prettyName;

  /// Architecture: hostnamectl wins, then uname -m.
  String? get effectiveArch => _text('Architecture') ?? kernelArch;

  /// Static hostname, only present through hostnamectl JSON.
  String? get hostname => _text('Hostname');

  /// The hostnamectl field [key] when it is a string. The object is the
  /// host's JSON, unchecked by the parser, so a field of another type
  /// reads as absent rather than throwing (03 §6.5).
  String? _text(String key) => switch (hostnamectl[key]) {
    final String text => text,
    _ => null,
  };

  Map<String, Object?> toJson() => {
    'osRelease': osRelease?.toJson(),
    'kernelName': kernelName,
    'kernelRelease': kernelRelease,
    'kernelArch': kernelArch,
    'hostnamectl': hostnamectl,
    'timeoutAbsent': timeoutAbsent,
  };
}

/// Parses an `identity` section payload; never throws (03 §6.5).
ParseResult<IdentitySnapshot> parseIdentity(String raw, ParseContext ctx) {
  final warnings = <String>[];
  final split = splitBlocks(raw, kTimeoutAbsentMarker);
  if (split.timeoutAbsent) {
    warnings.add('identity ran without a timeout guard');
  }
  if (split.preambleLines > 0) {
    warnings.add('${split.preambleLines} preamble line(s) ignored');
  }

  OsRelease? osRelease;
  final osrLines = split.blocks['os-release'];
  if (osrLines != null && osrLines.isNotEmpty) {
    osRelease = parseOsReleaseLines(osrLines, warnings);
  } else {
    warnings.add('identity: os-release block absent or empty');
  }

  String? kernelName, kernelRelease, kernelArch;
  final unameLines = split.blocks['uname'];
  final uname = unameLines
      ?.where((l) => l.trim().isNotEmpty)
      .firstOrNull
      ?.trim();
  if (uname == null) {
    warnings.add('identity: uname block absent or empty');
  } else {
    final parts = uname.split(RegExp(r'\s+'));
    if (parts.length >= 3) {
      kernelName = parts[0];
      kernelRelease = parts[1];
      kernelArch = parts[2];
    } else {
      warnings.add('identity: malformed uname line "$uname"');
    }
  }

  Map<String, Object?> hostnamectl = const {};
  final hcLines = split.blocks['hostnamectl'];
  final hc = hcLines?.where((l) => l.trim().isNotEmpty).firstOrNull?.trim();
  if (hc != null) {
    try {
      final decoded = jsonDecode(hc);
      if (decoded is Map) {
        hostnamectl = decoded.map((k, v) => MapEntry('$k', v));
      } else {
        warnings.add('identity: hostnamectl block is not an object');
      }
    } on FormatException {
      // systemd <249 has no --json flag and prints a usage error; the
      // parser falls back to os-release (03 §6.4).
      warnings.add(
        'identity: hostnamectl block is not JSON, using '
        'os-release fallback',
      );
    }
  }

  return ParseResult(
    IdentitySnapshot(
      osRelease: osRelease,
      kernelName: kernelName,
      kernelRelease: kernelRelease,
      kernelArch: kernelArch,
      hostnamectl: hostnamectl,
      timeoutAbsent: split.timeoutAbsent,
    ),
    warnings,
  );
}
