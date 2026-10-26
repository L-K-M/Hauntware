/// The parser for the package check's output (03 §7.8, PKG-01 to PKG-03):
/// the pending updates one package manager reports from its cached
/// metadata, which of them fix security issues, and whether the host
/// wants a reboot.
library;

import 'package:meta/meta.dart';

/// The package managers the check reads, in the order it looks for them.
enum PackageManager { apt, dnf, zypper, pacman, apk }

/// One pending update.
@immutable
final class PackageUpdate {
  const PackageUpdate({
    required this.name,
    required this.available,
    this.current,
    this.security = false,
  });

  final String name;

  /// The installed version, where the manager says it.
  final String? current;

  /// The version the update installs.
  final String available;

  /// Whether the update comes from a security source or advisory.
  final bool security;
}

/// Whether the host asks for a reboot.
enum RebootState {
  required,
  notRequired,

  /// Nothing on the host says either way.
  unknown,
}

/// Why a check listed no updates.
enum PackageCheckFailure {
  /// No package manager the check knows was found.
  noManager,

  /// The manager has no cached metadata to read, and the check never
  /// downloads it (PKG-05 refreshes it in admin mode).
  noCache,

  /// The manager failed; [PackageCheck.detail] says how.
  failed,
}

/// What one package check found.
@immutable
final class PackageCheck {
  PackageCheck({
    required this.manager,
    Iterable<PackageUpdate> updates = const [],
    this.securityCount,
    this.cachedAt,
    this.reboot = RebootState.unknown,
    Iterable<String> rebootPackages = const [],
    this.failure,
    this.detail,
  }) : updates = List.unmodifiable(updates),
       rebootPackages = List.unmodifiable(rebootPackages);

  /// The manager read, or null when none was found.
  final PackageManager? manager;

  final List<PackageUpdate> updates;

  /// How many updates fix security issues, or for zypper how many
  /// security patches are needed; null when the manager cannot say.
  final int? securityCount;

  /// When the manager's metadata was last refreshed, where it shows.
  final DateTime? cachedAt;

  final RebootState reboot;

  /// The packages that asked for the reboot (Debian and Ubuntu).
  final List<String> rebootPackages;

  final PackageCheckFailure? failure;

  /// The manager's own words for a [PackageCheckFailure.failed] check,
  /// cut short.
  final String? detail;
}

/// The most updates one check keeps [E]; a host past it is far behind
/// anyway, and the count still shows the rest as missing.
const kPackageUpdatesKept = 1000;

/// The most of a manager's error text a failed check keeps.
const _detailLimit = 300;

/// A section header: `== <key>` with an optional value.
final _header = RegExp(r'^== (\w+)(?: (.*))?$');

/// [raw], the check script's output (`HostCommands.packageCheck`).
PackageCheck parsePackageCheck(String raw) {
  final values = <String, String>{};
  final bodies = <String, List<String>>{};
  final codes = <String, int>{};
  String? section;
  for (final line in raw.split('\n')) {
    final match = _header.firstMatch(line);
    if (match == null) {
      if (section != null) bodies[section]!.add(line);
      continue;
    }
    final key = match.group(1)!;
    final value = match.group(2)?.trim() ?? '';
    if (key == 'rc') {
      if (section != null) codes[section] = int.tryParse(value) ?? -1;
      section = null;
      continue;
    }
    values[key] = value;
    section = key;
    bodies[key] = [];
  }

  final (reboot, rebootPackages) = _reboot(values['reboot'], bodies['reboot']);
  final cached = int.tryParse(values['cache'] ?? '');
  final cachedAt = cached == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(cached * 1000, isUtc: true);
  final manager = PackageManager.values.asNameMap()[values['manager']];
  if (manager == null) {
    return PackageCheck(
      manager: null,
      cachedAt: cachedAt,
      reboot: reboot,
      rebootPackages: rebootPackages,
      failure: PackageCheckFailure.noManager,
    );
  }

  PackageCheck failed(PackageCheckFailure failure, [List<String>? text]) {
    final words = (text ?? const []).join('\n').trim();
    return PackageCheck(
      manager: manager,
      cachedAt: cachedAt,
      reboot: reboot,
      rebootPackages: rebootPackages,
      failure: failure,
      detail: words.isEmpty
          ? null
          : words.substring(0, words.length.clamp(0, _detailLimit)),
    );
  }

  final body = bodies['updates'] ?? const [];
  final code = codes['updates'];
  if (code == null) return failed(PackageCheckFailure.failed, body);
  if (_noCache(manager, body)) return failed(PackageCheckFailure.noCache);
  if (!_succeeded(manager, code, body)) {
    return failed(PackageCheckFailure.failed, body);
  }

  var updates = switch (manager) {
    PackageManager.apt => _apt(body),
    PackageManager.dnf => _dnf(body),
    PackageManager.zypper => _zypperUpdates(body),
    PackageManager.pacman => _pacman(body),
    PackageManager.apk => _apk(body),
  };
  int? securityCount;
  switch (manager) {
    case PackageManager.apt:
      securityCount = updates.where((u) => u.security).length;
    case PackageManager.dnf:
      if (codes['security'] == 0) {
        updates = _dnfSecurity(updates, bodies['security'] ?? const []);
        securityCount = updates.where((u) => u.security).length;
      }
    case PackageManager.zypper:
      if (codes['security'] == 0) {
        securityCount = _zypperSecurityPatches(bodies['security']!);
      }
    case PackageManager.pacman || PackageManager.apk:
      break;
  }

  return PackageCheck(
    manager: manager,
    updates: updates.take(kPackageUpdatesKept),
    securityCount: securityCount,
    cachedAt: cachedAt,
    reboot: reboot,
    rebootPackages: rebootPackages,
  );
}

(RebootState, List<String>) _reboot(String? value, List<String>? body) {
  final packages = [
    for (final line in body ?? const <String>[])
      if (line.trim().isNotEmpty) line.trim(),
  ];
  return switch (value) {
    'required' => (RebootState.required, packages.toSet().toList()),
    'no' => (RebootState.notRequired, const []),
    _ => (RebootState.unknown, const []),
  };
}

/// dnf 4's "Cache-only enabled but no cache for 'fedora'" and dnf 5's
/// "Cache-only enabled but no cache for repository"; the other managers
/// read an empty or stale cache without complaint.
bool _noCache(PackageManager manager, List<String> body) =>
    manager == PackageManager.dnf &&
    body.any((line) => line.contains('Cache-only enabled but no cache'));

bool _succeeded(PackageManager manager, int code, List<String> body) =>
    switch (manager) {
      // `check-update` exits 100 when updates are pending.
      PackageManager.dnf => code == 0 || code == 100,
      // `pacman -Qu` exits 1 when nothing is out of date, with no output.
      PackageManager.pacman =>
        code == 0 || (code == 1 && body.every((l) => l.trim().isEmpty)),
      _ => code == 0,
    };

/// `Inst <name> [<current>] (<available> <origin> [<arch>])`; a package
/// new to the host has no current version.
final _aptInst = RegExp(r'^Inst (\S+) (?:\[([^\]]+)\] )?\((\S+) ([^\[)]*)');

List<PackageUpdate> _apt(List<String> body) => [
  for (final line in body)
    if (_aptInst.firstMatch(line) case final match?)
      PackageUpdate(
        name: match.group(1)!,
        current: match.group(2),
        available: match.group(3)!,
        // Debian's `Debian-Security:12/stable-security`, Ubuntu's
        // `Ubuntu:24.04/noble-security`.
        security: match.group(4)!.toLowerCase().contains('security'),
      ),
];

/// `<name>.<arch>  <version>  <repository>`.
final _dnfRow = RegExp(r'^(\S+)\.([A-Za-z0-9_]+)\s+(\S+)\s+(\S+)\s*$');

List<PackageUpdate> _dnf(List<String> body) {
  final updates = <PackageUpdate>[];
  for (final line in body) {
    // dnf 4 lists replaced packages after this line; they repeat updates.
    if (line.startsWith('Obsoleting')) break;
    final match = _dnfRow.firstMatch(line);
    if (match == null) continue;
    updates.add(
      PackageUpdate(name: match.group(1)!, available: match.group(3)!),
    );
  }
  return updates;
}

/// Marks the [updates] a security advisory in [body] names. dnf 4's
/// `updateinfo list --security` and dnf 5's `advisory list --security`
/// both print each package as `<name>-<version>-<release>.<arch>`, so a
/// token naming an update's package followed by its version marks it.
List<PackageUpdate> _dnfSecurity(
  List<PackageUpdate> updates,
  List<String> body,
) {
  final tokens = {for (final line in body) ...line.split(RegExp(r'\s+'))}
    ..remove('');
  return [
    for (final update in updates)
      PackageUpdate(
        name: update.name,
        current: update.current,
        available: update.available,
        security: tokens.any(
          (token) =>
              token.startsWith('${update.name}-') &&
              token.length > update.name.length + 1 &&
              _versionStart.hasMatch(token[update.name.length + 1]),
        ),
      ),
  ];
}

/// The first character of a version, or of an epoch.
final _versionStart = RegExp(r'[0-9]');

/// zypper's table rows: cells split on `|`, the header naming the
/// columns.
List<Map<String, String>> _zypperTable(List<String> body) {
  List<String>? columns;
  final rows = <Map<String, String>>[];
  for (final line in body) {
    if (!line.contains('|')) continue;
    final cells = [for (final cell in line.split('|')) cell.trim()];
    if (columns == null) {
      columns = cells;
      continue;
    }
    if (cells.every((cell) => RegExp(r'^[-+]*$').hasMatch(cell))) continue;
    rows.add({
      for (var i = 0; i < cells.length && i < columns.length; i++)
        columns[i]: cells[i],
    });
  }
  return rows;
}

List<PackageUpdate> _zypperUpdates(List<String> body) => [
  for (final row in _zypperTable(body))
    if (row['Name'] case final name? when name.isNotEmpty)
      PackageUpdate(
        name: name,
        current: row['Current Version'],
        available: row['Available Version'] ?? '',
      ),
];

/// The security patches zypper still needs; it lists patches, not the
/// packages they update, so only the count is known.
int _zypperSecurityPatches(List<String> body) => _zypperTable(
  body,
).where((row) => (row['Status'] ?? 'needed') == 'needed').length;

/// `<name> <current> -> <available>`.
final _pacmanRow = RegExp(r'^(\S+) (\S+) -> (\S+)');

List<PackageUpdate> _pacman(List<String> body) => [
  for (final line in body)
    if (_pacmanRow.firstMatch(line) case final match?)
      PackageUpdate(
        name: match.group(1)!,
        current: match.group(2),
        available: match.group(3)!,
      ),
];

/// `<name>-<version>-r<n>  < <available>`.
final _apkRow = RegExp(r'^(\S+)-(\d[^-]*-r\d+)\s+<\s+(\S+)');

List<PackageUpdate> _apk(List<String> body) => [
  for (final line in body)
    if (_apkRow.firstMatch(line) case final match?)
      PackageUpdate(
        name: match.group(1)!,
        current: match.group(2),
        available: match.group(3)!,
      ),
];
