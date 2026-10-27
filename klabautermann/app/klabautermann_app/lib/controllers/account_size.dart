import 'package:flutter/foundation.dart';

/// One row of the account size view (SYN-09): how many live records of an
/// id prefix the sync account holds and how many bytes their sealed blobs
/// take.
@immutable
final class AccountSizeRow {
  const AccountSizeRow({
    required this.prefix,
    required this.records,
    required this.bytes,
  });

  final String prefix;
  final int records;
  final int bytes;

  @override
  bool operator ==(Object other) =>
      other is AccountSizeRow &&
      other.prefix == prefix &&
      other.records == records &&
      other.bytes == bytes;

  @override
  int get hashCode => Object.hash(prefix, records, bytes);
}

/// The sync account's size as this device last pulled it (SYN-09): what
/// Klabautermann's own records take of their budget (03 §4.8), and every
/// prefix's records, the largest first. Kept apart from the engine's
/// types so the desktop settings window can show it.
@immutable
final class AccountSize {
  AccountSize({
    required this.prefixBytes,
    required this.budgetBytes,
    required this.warnBytes,
    required List<AccountSizeRow> rows,
  }) : rows = List.unmodifiable(
         [...rows]..sort((a, b) {
           final bySize = b.bytes.compareTo(a.bytes);
           return bySize != 0 ? bySize : a.prefix.compareTo(b.prefix);
         }),
       );

  /// The sealed blobs of Klabautermann's own records.
  final int prefixBytes;

  /// Their budget, and the share of it from which the view warns.
  final int budgetBytes, warnBytes;

  final List<AccountSizeRow> rows;

  bool get warns => prefixBytes >= warnBytes;
  bool get full => prefixBytes >= budgetBytes;

  @override
  bool operator ==(Object other) =>
      other is AccountSize &&
      other.prefixBytes == prefixBytes &&
      other.budgetBytes == budgetBytes &&
      other.warnBytes == warnBytes &&
      listEquals(other.rows, rows);

  @override
  int get hashCode =>
      Object.hash(prefixBytes, budgetBytes, warnBytes, Object.hashAll(rows));
}
