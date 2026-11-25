/// Why [UserCrontabs] read no crontab.
enum UserCrontabsFailure {
  /// The server has no ready link.
  noLink,

  /// Admin mode is off for the server.
  adminRequired,

  /// Elevation refused, so nothing ran.
  elevationRefused,

  /// Neither spool directory exists (`kCrontabSpools`).
  noSpool,

  /// The spool exists but cannot be listed.
  spoolDenied,

  /// The listing did not read as a spool.
  unreadable,

  /// The link failed while reading.
  transport,
}

/// Why a [ReadDiskUsage] read nothing.
enum DiskUsageReportFailure {
  /// The server has no ready link.
  noLink,

  /// An elevated read while admin mode is off for the server.
  adminRequired,

  /// Elevation refused, so nothing ran.
  elevationRefused,

  /// The path is not absolute and normalized.
  invalidPath,

  /// The folder is not there.
  notFound,

  /// The login user may not read the folder.
  denied,

  /// `du` is not installed, or printed something else.
  unreadable,

  /// The link failed, or the read ran past its time.
  transport,
}

/// Why a [ReadTimerDetail] read nothing.
enum TimerDetailFailure {
  /// The server has no ready link.
  noLink,

  /// The unit name is not a timer's.
  invalidUnit,

  /// systemctl is not installed.
  missing,

  /// systemctl failed, as when the manager could not be reached.
  unreadable,

  /// The link failed, or a read ran past its time.
  transport,
}

/// Why a [ReadAccounts] read nothing.
enum AccountsReportFailure {
  /// The server has no ready link.
  noLink,

  /// The read printed nothing the parser recognised.
  unreadable,

  /// The link failed while reading.
  transport,
}

/// Why a [ReadSmart] read nothing.
enum SmartReportFailure {
  /// The server has no ready link.
  noLink,

  /// Admin mode is off for the server.
  adminRequired,

  /// Elevation refused, so nothing ran.
  elevationRefused,

  /// smartmontools is not installed.
  missing,

  /// `smartctl --scan-open` did not answer with its JSON, as smartctl
  /// before 7.0 does.
  unreadable,

  /// The link failed while reading.
  transport,
}

/// Why a [ReadRestarts] read nothing.
enum RestartReportFailure {
  /// The server has no ready link.
  noLink,

  /// Admin mode is off for the server.
  adminRequired,

  /// Elevation refused, so nothing ran.
  elevationRefused,

  /// None of needrestart, needs-restarting and zypper is installed.
  missing,

  /// The link failed while reading.
  transport,
}

/// Why a [ReadFirewall] read nothing.
enum FirewallReportFailure {
  /// The server has no ready link.
  noLink,

  /// Admin mode is off for the server.
  adminRequired,

  /// Elevation refused, so nothing ran.
  elevationRefused,

  /// The read printed something else.
  unreadable,

  /// The link failed while reading.
  transport,
}

/// Why a [ReadSshdPosture] read nothing.
enum SshdPostureFailure {
  /// The server has no ready link.
  noLink,

  /// Admin mode is off for the server.
  adminRequired,

  /// Elevation refused, so nothing ran.
  elevationRefused,

  /// No sshd binary was found.
  missing,

  /// `sshd -T` refused, as for a broken configuration; the report's
  /// detail carries its error.
  refused,

  /// The read printed something else.
  unreadable,

  /// The link failed while reading.
  transport,
}

/// Why a [ReadPackages] checked nothing.
enum PackagesReportFailure {
  /// The server has no ready link.
  noLink,

  /// The link failed while checking.
  transport,
}
