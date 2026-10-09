/// Which remote file names an OS "open" would run as a program, shared by
/// Séance and Poltergeist so the two apps refuse the same launches.
/// Poltergeist moved it here from its preview kinds (plan 06 §5.3); see
/// finding P1-03 in `docs/reviews/deep-review-2026-09-26.md`.
library;

/// The Windows-executable extensions: Script-Host and control-panel
/// spellings that double-click-execute, plus the types whose default verb
/// runs code anyway — shortcuts (`lnk`, `url`), installers (`msi`,
/// `application`), registry merges, compiled help, MMC consoles,
/// troubleshooter packs, `jar` under an installed Java runtime, and
/// `py`/`pyw`/`pyz`/`pyzw`, which python.org's installer associates with
/// its `py` launcher. App packages (`appx`, `msix` and their bundles) and
/// their `appinstaller` referrals open in App Installer, which installs
/// and launches them like `msi`; ClickOnce runs an `appref-ms` the way it
/// runs an `application`, the Office customization installer installs a
/// `vsto` add-in, and a provisioning package (`ppkg`) can run its commands
/// as SYSTEM once accepted. [isExecutableLaunchName] reads it for Windows
/// hosts.
const windowsExecutableExtensions = <String>{
  'bat',
  'cmd',
  'com',
  'scr',
  'ps1',
  'js',
  'jse',
  'vbs',
  'vbe',
  'wsf',
  'wsh',
  'hta',
  'exe',
  'pif',
  'scf',
  'cpl',
  'msp',
  'mst',
  'msi',
  'lnk',
  'url',
  'reg',
  'chm',
  'msc',
  'jar',
  'vb',
  'ws',
  'wsc',
  'sct',
  'application',
  'diagcab',
  'py',
  'pyw',
  'pyz',
  'pyzw',
  'appx',
  'appxbundle',
  'msix',
  'msixbundle',
  'appinstaller',
  'appref-ms',
  'vsto',
  'ppkg',
};

/// The desktop hosts [isExecutableLaunchName] knows. What an OS "open"
/// does with a file is decided by the host's association table, not by
/// the file, so the same name can be a document on one host and a
/// program on another.
enum LaunchHost { macos, linux, windows }

/// macOS launch types that run rather than open: Terminal runs
/// `command`/`tool` scripts and a `terminal` or legacy `term` file's
/// CommandString;
/// `fileloc`/`inetloc`/`webloc` open their target, which can be a
/// program or an app's URL scheme; `app`/`workflow` are code bundles;
/// Jar Launcher runs `jar`; Installer runs `pkg`/`mpkg` scripts. Opening a
/// preference pane, screen saver (`saver`, `slidesaver`) or Automator
/// `action` offers to install it, and the stock panel then loads its code.
const _macosExecutableExtensions = <String>{
  'app',
  'command',
  'tool',
  'terminal',
  'workflow',
  'fileloc',
  'inetloc',
  'webloc',
  'jar',
  'pkg',
  'mpkg',
  'term',
  'prefpane',
  'saver',
  'slidesaver',
  'action',
};

/// Linux launch types that run without an execute bit: file managers
/// behind `xdg-open` launch `desktop` entries, the Java runtime's
/// handler runs `jar`, and `appimage` is listed as defense in depth.
/// GNOME Software and Discover install a `deb` or `rpm` on open and, once
/// the user authenticates, run its maintainer scripts as root, like `msi`.
/// Everything else that executes needs the execute bit, which managed
/// checkouts never carry.
const _linuxExecutableExtensions = <String>{
  'desktop',
  'jar',
  'appimage',
  'deb',
  'rpm',
};

/// Whether handing [name] to [host]'s default handler would run it as a
/// program instead of opening it as a document: the "never executed"
/// rule for remote files at the open boundary. [name] may be a bare name, a
/// POSIX path, or a Windows path; only the last component counts, and
/// within it only the LAST extension (`invoice.pdf.exe` is an `exe`),
/// matched case-insensitively after trailing dots and spaces are
/// stripped the way Win32 resolves names (`x.hta.` launches as
/// `x.hta`). The strip applies on every host, where it can only err
/// toward refusing.
///
/// A leading dot names an extension: Explorer runs a file called `.js`
/// through Script Host, so no dotfile rule applies here.
bool isExecutableLaunchName(String name, {required LaunchHost host}) {
  final extension = _launchExtension(name);
  if (extension == null) return false;
  return switch (host) {
    LaunchHost.windows => windowsExecutableExtensions.contains(extension),
    LaunchHost.macos => _macosExecutableExtensions.contains(extension),
    LaunchHost.linux => _linuxExecutableExtensions.contains(extension),
  };
}

String? _launchExtension(String name) {
  final base = name
      .substring(name.lastIndexOf(_pathSeparator) + 1)
      .replaceFirst(_trailingDotsAndSpaces, '');
  final dot = base.lastIndexOf('.');
  if (dot < 0) return null;
  return base.substring(dot + 1).toLowerCase();
}

final RegExp _pathSeparator = RegExp(r'[/\\]');
final RegExp _trailingDotsAndSpaces = RegExp(r'[. ]+$');
