// The detached runner's rows on every recorded host (03 §7.17, M4 X3):
// each platform fixture's probe, as the capture recorded it, through
// selectDetachedRunner for the work that needs no root with admin mode
// off and on, and for the work that needs root. The systemd hosts include
// the oldest the platform table supports (RHEL 8, systemd 239), and each
// must take the `--collect` the systemd rows pass. A new fixture must say
// here which rows it takes.
import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/operations/detached_runner.dart';
import 'package:klabautermann_host/klabautermann_host.dart' show DetachedRunner;
import 'package:test/test.dart';

/// The first systemd whose `systemd-run` takes `--collect` (systemd 236
/// NEWS), which every systemd row passes.
const _collectSince = 236;

/// The hosts with a running system manager, and the rows they take: for
/// work that needs no root with admin mode off, the same with admin mode
/// on, and work that needs root. Every other fixture has no running
/// manager (a container, Alpine's OpenRC), whatever systemctl it ships,
/// and takes the `setsid` rows.
const _systemdHosts =
    <String, (DetachedRunner off, DetachedRunner on, DetachedRunner root)>{
      // Linger off: setsid without admin mode, the system manager with it.
      'debian-12': (
        DetachedRunner.loginSetsid,
        DetachedRunner.loginSystemdUid,
        DetachedRunner.rootSystemd,
      ),
      'debian-12-lxc': (
        DetachedRunner.loginSetsid,
        DetachedRunner.loginSystemdUid,
        DetachedRunner.rootSystemd,
      ),
      'rhel-8': (
        DetachedRunner.loginSetsid,
        DetachedRunner.loginSystemdUid,
        DetachedRunner.rootSystemd,
      ),
      'ubuntu-2404-runner-dash': (
        DetachedRunner.loginSetsid,
        DetachedRunner.loginSystemdUid,
        DetachedRunner.rootSystemd,
      ),
      // Root signs in: `--uid` would run a root unit, so its own work
      // stays on setsid even in admin mode.
      'debian-12-lxc-lxcfs': (
        DetachedRunner.loginSetsid,
        DetachedRunner.loginSetsid,
        DetachedRunner.rootSystemd,
      ),
      // Linger on, with the user manager's runtime directory.
      'ubuntu-2404': (
        DetachedRunner.loginSystemdUser,
        DetachedRunner.loginSystemdUid,
        DetachedRunner.rootSystemd,
      ),
    };

/// The host package's fixtures, from the package or the workspace root.
String _fixturesRoot() {
  for (final path in const [
    '../klabautermann_host/test/fixtures',
    'packages/klabautermann_host/test/fixtures',
  ]) {
    if (Directory(path).existsSync()) return path;
  }
  throw StateError('klabautermann_host fixtures not found');
}

/// Each platform's recorded profile, by fixture name.
Map<String, HostProfile> _profiles() {
  final profiles = <String, HostProfile>{};
  for (final entry in Directory(_fixturesRoot()).listSync()) {
    final golden = File('${entry.path}/probe.golden.json');
    if (!golden.existsSync()) continue;
    final json = jsonDecode(golden.readAsStringSync()) as Map<String, Object?>;
    profiles[entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty)] =
        HostProfile.fromJson(json['result']! as Map<String, Object?>);
  }
  return profiles;
}

DetachedRunner? _row(
  HostProfile profile,
  RequiredLevel level, {
  required bool adminMode,
}) => selectDetachedRunner(
  profile: profile,
  level: level,
  adminMode: adminMode,
).runner;

void main() {
  final profiles = _profiles();

  test('the recorded hosts with a running system manager are the ones '
      'listed', () {
    expect(profiles, isNotEmpty);
    expect({
      for (final MapEntry(key: name, value: profile) in profiles.entries)
        if (profile.systemdDir == true) name,
    }, _systemdHosts.keys.toSet());
  });

  for (final MapEntry(key: name, value: profile) in profiles.entries) {
    test('$name takes the runner rows of its recorded probe', () {
      final (off, on, root) =
          _systemdHosts[name] ??
          (
            DetachedRunner.loginSetsid,
            DetachedRunner.loginSetsid,
            DetachedRunner.rootSetsid,
          );
      expect(_row(profile, RequiredLevel.login, adminMode: false), off);
      expect(_row(profile, RequiredLevel.login, adminMode: true), on);
      expect(_row(profile, RequiredLevel.admin, adminMode: true), root);
      expect(_row(profile, RequiredLevel.admin, adminMode: false), isNull);

      if (profile.systemdDir == true) {
        expect(
          profile.systemdVersion,
          greaterThanOrEqualTo(_collectSince),
          reason: 'its systemd-run must take --collect',
        );
      }
    });
  }
}
