/// How the log viewer marks a line's severity (03 §10.8 level colouring):
/// colour on the line's text plus an icon with a spoken name in its gutter,
/// so colour is never the only cue (A11Y-01). A line with no level, or
/// [info], is drawn in the default text colour with an empty gutter.
enum LogLevel {
  error,
  warning,
  info,
  debug;

  /// The level of a syslog or journal `PRIORITY` (RFC 5424 severity, 0 to
  /// 7), or null for any other value: emerg, alert, crit and err are
  /// [error]; warning is [warning]; notice and info are [info]; debug is
  /// [debug].
  static LogLevel? fromSyslogPriority(int priority) => switch (priority) {
    >= 0 && <= 3 => error,
    4 => warning,
    5 || 6 => info,
    7 => debug,
    _ => null,
  };
}
