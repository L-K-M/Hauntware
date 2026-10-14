// Shared helpers for the access-rule tests: the platform fixture probes
// and a synthetic profile whose probe areas all answered.
import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart';

/// The four tier A fixture platforms (03 §6.5).
const fixturePlatforms = ['debian-12', 'ubuntu-2404', 'rhel-8', 'alpine-322'];

/// Parses `test/fixtures/<platform>/probe.sections` into a profile. The
/// fixtures predate the probe's `dmesg` and `tail` entries, so both stay
/// unknown there.
HostProfile fixtureProfile(String platform) {
  final root = Directory('test/fixtures').existsSync()
      ? 'test/fixtures'
      : 'packages/klabautermann_host/test/fixtures';
  final text = File('$root/$platform/probe.sections').readAsStringSync();
  return parseProbe(probeSections(text), ParseContext.standard).value;
}

/// Reads the `### <area> <status>` fixture format into probe sections.
List<ProbeSection> probeSections(String text) {
  final out = <ProbeSection>[];
  for (final chunk in text.split('### ').skip(1)) {
    final newline = chunk.indexOf('\n');
    final header = chunk.substring(0, newline).trim().split(' ');
    final payload = chunk.substring(newline + 1);
    out.add(
      ProbeSection(
        header[0],
        SectionStatus.values.byName(header[1]),
        payload.endsWith('\n')
            ? payload.substring(0, payload.length - 1)
            : payload,
      ),
    );
  }
  return out;
}

/// A login on a systemd host whose probe areas all answered, except
/// those in [denied]; each other argument overrides one fact.
HostProfile host({
  int? uid = 1000,
  String? user = 'ops',
  List<String> groups = const ['ops'],
  String? distroId = 'debian',
  SudoKind? sudoKind = SudoKind.sudo,
  bool? sudoNonInteractive = false,
  bool? doasPresent = false,
  bool? doasNonInteractive,
  Map<String, String?> tools = const {
    'journalctl': '/usr/bin/journalctl',
    'crontab': '/usr/bin/crontab',
    'docker': null,
    'podman': null,
    'dmesg': '/usr/bin/dmesg',
    'tail': '/usr/bin/tail',
  },
  List<EngineSocket> sockets = const [],
  bool? systemdDir = true,
  int? systemdVersion = 252,
  Set<String> denied = const {},
}) => HostProfile(
  uid: uid,
  user: user,
  groups: groups,
  distroId: distroId,
  sudoKind: sudoKind,
  sudoNonInteractive: sudoNonInteractive,
  doasPresent: doasPresent,
  doasNonInteractive: doasNonInteractive,
  tools: tools,
  engineSockets: sockets,
  systemdDir: systemdDir,
  systemdVersion: systemdVersion,
  areaStatuses: {
    for (final area in 'distro init identity elev tools sockets'.split(' '))
      area: denied.contains(area) ? SectionStatus.denied : SectionStatus.ok,
  },
);

/// One engine socket candidate as the probe reports it.
EngineSocket socket(String path, {bool exists = true, bool writable = false}) =>
    EngineSocket(path: path, exists: exists, writable: writable);
