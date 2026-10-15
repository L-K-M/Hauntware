import 'package:klabautermann_host/klabautermann_host.dart' show JournalEntry;

import '../engine/protocol.dart';

/// [entry] as the plain [JournalRecord] a [LogBatch] carries (D52). The
/// engine reads the entry's columns here, once, so the app parses nothing
/// (03 §6.5), and a value the host sent that its column cannot hold reads
/// as unknown: a time beyond [DateTime]'s range, a priority outside the
/// eight syslog severities, a PID that is not positive.
JournalRecord journalRecordFrom(JournalEntry entry) {
  final priority = entry.priority;
  final pid = entry.pid;

  return JournalRecord(
    cursor: entry.cursor,
    at: entry.timestampUtc,
    priority:
        priority != null &&
            priority >= 0 &&
            priority < LogPriority.values.length
        ? LogPriority.values[priority]
        : null,
    unit: entry.unit,
    identifier: entry.identifier,
    pid: pid != null && pid > 0 ? pid : null,
    message: entry.message,
    // Already unmodifiable: JournalEntry copies its fields that way.
    fields: entry.fields,
  );
}
