// How a per-server file is named (03 §4.10, D59): the capability cache,
// the audit log and, later, history all name their files this way.
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;

import 'imported_fleet.dart' show importIdPrefix;

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{12}$',
);

/// The file name, without its extension, of [serverId]'s per-server
/// files, or null when the id names none. A synced id is a UUID, written
/// in lowercase. An import id, `ssh-config:<alias>`, becomes
/// `ssh-config-` and the lowercase hex SHA-256 of the alias's UTF-8
/// bytes: an alias may hold path separators or `:`, or differ from
/// another only in case, and the hash keeps the name short, safe on every
/// file system and unequal to any UUID.
String? serverFileStem(String serverId) {
  if (_uuid.hasMatch(serverId)) return serverId.toLowerCase();
  if (!serverId.startsWith(importIdPrefix)) return null;

  final alias = serverId.substring(importIdPrefix.length);
  if (alias.isEmpty) return null;
  return 'ssh-config-${sha256.convert(utf8.encode(alias))}';
}
