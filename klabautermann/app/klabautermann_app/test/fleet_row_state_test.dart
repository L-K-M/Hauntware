import 'package:flutter/material.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_servers/ghost_servers.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/fleet_row_state.dart';
import 'package:klabautermann_app/ui/fleet_rows.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

final _t0 = DateTime.utc(2026, 10, 15, 12);

Sample _sample(SampleStream stream, SampleResult result, {DateTime? at}) =>
    Sample(
      serverId: 'srv-1',
      stream: stream,
      seq: 1,
      at: at ?? _t0,
      result: result,
    );

Sample _overview({double? cpu, int? used, int? total, DateTime? at}) => _sample(
  SampleStream.overview,
  OverviewResult(
    cpu: cpu == null ? null : CpuPercentages(const [], cpu),
    memory: MemoryUsage(usedBytes: used, totalBytes: total),
  ),
  at: at,
);

Sample _core({double? cpu, int? used, int? total, DateTime? at}) => _sample(
  SampleStream.core,
  CoreResult(
    cpu: cpu == null ? null : CpuPercentages(const [], cpu),
    memory: MemoryUsage(usedBytes: used, totalBytes: total),
  ),
  at: at,
);

/// An `fs` reading whose root mount is [rootPercent] full, after a full
/// mount the row must not pick.
Sample _fsRoot(int? rootPercent, {DateTime? at, int? used, int? size}) =>
    _sample(
      SampleStream.fs,
      FsResult(
        FsSnapshot([
          const FsMount(
            device: 'tmpfs',
            type: 'tmpfs',
            mountPoint: '/run',
            capacityPercent: 100,
          ),
          FsMount(
            device: '/dev/sda1',
            type: 'ext4',
            mountPoint: '/',
            capacityPercent: rootPercent,
            usedBytes: used,
            sizeBytes: size,
          ),
        ]),
      ),
      at: at,
    );

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  group('the ghost_servers adapter (03 §10.3)', () {
    test('maps every link status onto the shared session states', () {
      final cases = <LinkStatus, GhostSessionState>{
        const LinkIdle(): GhostSessionState.none,
        const LinkConnecting(): GhostSessionState.connecting,
        const LinkAuthenticating(): GhostSessionState.connecting,
        LinkBackoff(_t0): GhostSessionState.connecting,
        const LinkReady(): GhostSessionState.connected,
        const LinkDegraded(LinkDegradedReason.sessionLimitLearned):
            GhostSessionState.connected,
        const LinkNeedsUser(promptId: 'p-1', kind: PromptKind.hostKey):
            GhostSessionState.blocked,
        const LinkBlocked(LinkBlockedReason.hostKeyChanged):
            GhostSessionState.blocked,
        const LinkClosed(LinkClosedReason.closedByOwner):
            GhostSessionState.idle,
        const LinkClosed(
          LinkClosedReason.closedByOwner,
          failure: LinkFailureKind.credentialUnavailable,
        ): GhostSessionState.failed,
        const LinkClosed(
          LinkClosedReason.connectFailed,
          failure: LinkFailureKind.unreachable,
        ): GhostSessionState.failed,
        const LinkClosed(LinkClosedReason.linkLost): GhostSessionState.failed,
        const LinkClosed(LinkClosedReason.pingTimeout):
            GhostSessionState.failed,
      };
      for (final MapEntry(key: status, value: session) in cases.entries) {
        expect(ghostSessionOf(status), session, reason: '$status');
      }
    });

    test('maps the probe answers, and none stays none', () {
      expect(ghostProbeOf(null), isNull);
      expect(ghostProbeOf(ReachabilityStatus.online), GhostProbeState.online);
      expect(ghostProbeOf(ReachabilityStatus.offline), GhostProbeState.offline);
      expect(ghostProbeOf(ReachabilityStatus.unknown), GhostProbeState.unknown);
    });

    GhostServerIndicator resolve(LinkStatus link, ReachabilityStatus? probe) =>
        ghostServerIndicator(
          fleetStatusStrings(l10n, link),
          GhostIndicatorRule.rail,
          session: ghostSessionOf(link),
          probe: ghostProbeOf(probe),
        );

    test('live truth outranks the probe; without it the probe speaks in '
        'FL-04\'s words', () {
      final connected = resolve(
        const LinkDegraded(LinkDegradedReason.sessionLimitLearned),
        ReachabilityStatus.offline,
      );
      expect(connected.glyph, GhostServerGlyph.connected);
      expect(connected.label, 'Connected with limits');

      final backoff = resolve(LinkBackoff(_t0), ReachabilityStatus.online);
      expect(backoff.glyph, GhostServerGlyph.connecting);
      expect(backoff.label, 'Waiting to reconnect');

      expect(
        resolve(const LinkIdle(), ReachabilityStatus.online).label,
        'Online',
      );
      expect(
        resolve(const LinkIdle(), ReachabilityStatus.offline).label,
        'Offline',
      );
      expect(
        resolve(const LinkIdle(), ReachabilityStatus.unknown).label,
        'Reachability unknown',
      );
      expect(
        resolve(const LinkClosed(LinkClosedReason.closedByOwner), null).label,
        'Disconnected',
      );
      final nothing = resolve(const LinkIdle(), null);
      expect(nothing.glyph, GhostServerGlyph.none);
      expect(nothing.label, isNull);
    });

    test('every glyph with a word has an icon (A11Y-01)', () {
      for (final glyph in GhostServerGlyph.values) {
        expect(
          fleetStatusIcon(glyph),
          glyph == GhostServerGlyph.none ? isNull : isNotNull,
          reason: '$glyph',
        );
      }
    });
  });

  group('fleetRowReading (FL-07)', () {
    FleetRowReading? read({
      Sample? overview,
      Sample? core,
      Sample? fs,
      GhostSessionState session = GhostSessionState.connected,
      DateTime? now,
    }) => fleetRowReading(
      overview: overview,
      core: core,
      fs: fs,
      session: session,
      now: now ?? _t0,
    );

    test('needs an overview or core reading: a row without one shows '
        'reachability only', () {
      expect(read(), isNull);
      expect(read(fs: _fsRoot(40)), isNull);
    });

    test('reads CPU, memory and the root file system', () {
      final reading = read(
        core: _core(cpu: 12.5, used: 2, total: 8),
        fs: _fsRoot(41),
      )!;

      expect(reading.cpuPercent, 12.5);
      expect(reading.memoryPercent, 25);
      expect(reading.diskPercent, 41);
      expect(reading.stale, isFalse);
    });

    test('takes the newer of overview and core', () {
      final second = const Duration(seconds: 1);
      final reading = read(
        overview: _overview(cpu: 70, at: _t0.subtract(second)),
        core: _core(cpu: 20, at: _t0),
        now: _t0.add(second * 3),
      )!;
      expect(reading.cpuPercent, 20);
      expect(reading.age, second * 3);

      expect(
        read(
          overview: _overview(cpu: 70, at: _t0),
          core: _core(cpu: 20, at: _t0.subtract(second)),
        )!.cpuPercent,
        70,
      );
    });

    test('an unknown value stays unknown, never zero (03 §10.4)', () {
      final reading = read(
        overview: _overview(used: 5),
        fs: _fsRoot(null, used: 3, size: 4),
      )!;
      expect(reading.cpuPercent, isNull);
      expect(reading.memoryPercent, isNull, reason: 'no total');
      expect(reading.diskPercent, 75, reason: 'used out of size');

      final unavailable = read(
        overview: _sample(
          SampleStream.overview,
          const CollectorUnavailable(CollectorUnavailableReason.timeout),
        ),
      )!;
      expect(unavailable.cpuPercent, isNull);
      expect(unavailable.memoryPercent, isNull);
      expect(unavailable.diskPercent, isNull);
    });

    test('turns stale past twice the stream\'s slowest cadence', () {
      final overview = _overview(cpu: 1);
      expect(
        read(
          overview: overview,
          now: _t0.add(const Duration(seconds: 59)),
        )!.stale,
        isFalse,
      );
      expect(
        read(
          overview: overview,
          now: _t0.add(const Duration(seconds: 60)),
        )!.stale,
        isTrue,
      );
      final core = _core(cpu: 1);
      expect(
        read(core: core, now: _t0.add(const Duration(seconds: 19)))!.stale,
        isFalse,
      );
      expect(
        read(core: core, now: _t0.add(const Duration(seconds: 20)))!.stale,
        isTrue,
      );
    });

    test('a stale fs reading leaves the disk unknown', () {
      final now = _t0.add(const Duration(seconds: 240));
      final reading = read(
        core: _core(cpu: 1, at: now),
        fs: _fsRoot(50),
        now: now,
      )!;
      expect(reading.stale, isFalse);
      expect(reading.diskPercent, isNull);
    });

    test('a link that is down makes the reading stale at once; no status '
        'at all leaves it to the age', () {
      for (final session in GhostSessionState.values) {
        final down = switch (session) {
          GhostSessionState.connected || GhostSessionState.none => false,
          _ => true,
        };
        final reading = read(core: _core(cpu: 1), session: session)!;
        expect(reading.stale, down, reason: '$session');
        expect(reading.linkDown, down, reason: '$session');
      }
    });
  });

  group('fleetServerMatches (FL-05)', () {
    const server = FleetServer(
      id: 'ssh-config:prod-web-01',
      displayName: 'prod-web-01',
      address: 'root@web.eu-west.example',
      searchText: 'prod-web-01 root@web.eu-west.example:22 production',
    );

    test('every term must occur in the engine\'s search text', () {
      expect(fleetServerMatches(server, ''), isTrue);
      expect(fleetServerMatches(server, '   '), isTrue);
      expect(fleetServerMatches(server, 'web eu'), isTrue);
      expect(fleetServerMatches(server, 'EU  Web'), isTrue);
      expect(fleetServerMatches(server, 'production root'), isTrue);
      expect(fleetServerMatches(server, 'web db'), isFalse);
    });

    test('without search text, name and address stand in', () {
      const seeded = FleetServer(
        id: 'srv-2',
        displayName: 'db-1',
        address: '10.0.0.4',
      );
      expect(fleetServerMatches(seeded, 'DB 10.0'), isTrue);
      expect(fleetServerMatches(seeded, 'web'), isFalse);
    });
  });

  test('ages read in the largest whole unit under 60', () {
    String age(Duration duration) => fleetRowAge(l10n, duration);

    expect(age(Duration.zero), '0 s');
    expect(age(const Duration(seconds: 59, milliseconds: 999)), '59 s');
    expect(age(const Duration(minutes: 1)), '1 min');
    expect(age(const Duration(minutes: 59, seconds: 59)), '59 min');
    expect(age(const Duration(hours: 26)), '26 h');
  });
}
