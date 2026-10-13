import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_servers/ghost_servers.dart';
import 'package:ghost_ui/ghost_ui.dart' show SidebarDotStyle, SidebarStatusDot;

/// A host bag with a word for every state, so a test can tell which member
/// a resolution read.
const _worded = GhostServerStatusStrings(
  connected: 'connected',
  connecting: 'connecting',
  failed: 'failed',
  blocked: 'blocked',
  notConnected: 'idle',
  probeOnline: 'online',
  probeOffline: 'offline',
  probeUnknown: 'unknown',
  blockedDetail: 'review the key',
  hiddenConnected: 'connected hidden',
  hiddenConnecting: 'connecting hidden',
);

/// Every probe answer, plus no probe at all.
const _probes = <GhostProbeState?>[null, ...GhostProbeState.values];

const _colors = GhostStatusColors(
  online: Color(0xFF00AA00),
  connecting: Color(0xFFFFAA00),
  offline: Color(0xFFAA0000),
);

GhostServerGlyph _glyph(
  GhostIndicatorRule rule, {
  GhostSessionState session = GhostSessionState.none,
  GhostProbeState? probe,
}) => ghostServerIndicator(_worded, rule, session: session, probe: probe).glyph;

void main() {
  group('the rail rule', () {
    GhostServerGlyph rail({
      GhostSessionState session = GhostSessionState.none,
      GhostProbeState? probe,
    }) => _glyph(GhostIndicatorRule.rail, session: session, probe: probe);

    test('a live session outranks whatever the probe said', () {
      for (final probe in _probes) {
        final reason = '$probe';
        expect(
          rail(session: GhostSessionState.connected, probe: probe),
          GhostServerGlyph.connected,
          reason: reason,
        );
        expect(
          rail(session: GhostSessionState.connecting, probe: probe),
          GhostServerGlyph.connecting,
          reason: reason,
        );
        expect(
          rail(session: GhostSessionState.failed, probe: probe),
          GhostServerGlyph.failed,
          reason: reason,
        );
        expect(
          rail(session: GhostSessionState.blocked, probe: probe),
          GhostServerGlyph.blocked,
          reason: reason,
        );
      }
    });

    test('no session, or one that ended cleanly, defers to the probe', () {
      for (final session in [GhostSessionState.none, GhostSessionState.idle]) {
        final reason = '$session';
        expect(
          rail(session: session, probe: GhostProbeState.online),
          GhostServerGlyph.reachable,
          reason: reason,
        );
        expect(
          rail(session: session, probe: GhostProbeState.offline),
          GhostServerGlyph.unreachable,
          reason: reason,
        );
        expect(
          rail(session: session, probe: GhostProbeState.unknown),
          GhostServerGlyph.reachabilityUnknown,
          reason: reason,
        );
      }
    });

    test('with no probe at all, an idle session is idle and none is none', () {
      expect(rail(session: GhostSessionState.idle), GhostServerGlyph.idle);
      expect(rail(), GhostServerGlyph.none);
    });
  });

  // Moved from Poltergeist's server_state_indicator_test.dart, restated
  // over the neutral states; its ARB and paint cases stay in the app.
  group('the list rule', () {
    GhostServerGlyph list({
      GhostSessionState session = GhostSessionState.none,
      GhostProbeState? probe,
    }) => _glyph(GhostIndicatorRule.list, session: session, probe: probe);

    test('no truth paints nothing', () {
      final indicator = ghostServerIndicator(
        _worded,
        GhostIndicatorRule.list,
        session: GhostSessionState.none,
        probe: null,
      );

      expect(indicator.glyph, GhostServerGlyph.none);
      expect(indicator.label, isNull);
    });

    test('probe truth alone renders the tri-state answer', () {
      for (final (probe, glyph) in [
        (GhostProbeState.online, GhostServerGlyph.reachable),
        (GhostProbeState.offline, GhostServerGlyph.unreachable),
        (GhostProbeState.unknown, GhostServerGlyph.reachabilityUnknown),
      ]) {
        expect(list(probe: probe), glyph, reason: '$probe');
      }
    });

    test('a block outranks a reachable probe', () {
      // The audit finding: a green "reachable" dot rendered next to a
      // blocked panel. Live truth outranks probes (02 §4).
      expect(
        list(session: GhostSessionState.blocked, probe: GhostProbeState.online),
        GhostServerGlyph.blocked,
      );
    });

    test('a failure the state explains outranks a reachable probe', () {
      expect(
        list(session: GhostSessionState.failed, probe: GhostProbeState.online),
        GhostServerGlyph.failed,
      );
    });

    test('a connected server outranks an offline probe', () {
      // The reverse contradiction of the audit finding: authenticated
      // transports prove reachability, so a stale offline result cannot
      // paint beside a session the user is actively using (02 §4).
      expect(
        list(
          session: GhostSessionState.connected,
          probe: GhostProbeState.offline,
        ),
        GhostServerGlyph.connected,
      );
    });

    test('a connected server outranks an unknown probe', () {
      // "Unknown" reachability beside an authenticated transport is the
      // same contradiction: the transport proves reachability, so the
      // glyph answers instead of the grey dot.
      expect(
        list(
          session: GhostSessionState.connected,
          probe: GhostProbeState.unknown,
        ),
        GhostServerGlyph.connected,
      );
    });

    test('a truth that does not contradict leaves the probe answer', () {
      // 02 §4 gives the favorite row its tri-state probe dot, and 07 §3.3
      // requires it to render in the interim list: a healthy or pending
      // connection does not contradict a reachability result.
      expect(
        list(
          session: GhostSessionState.connected,
          probe: GhostProbeState.online,
        ),
        GhostServerGlyph.reachable,
      );
      expect(
        list(
          session: GhostSessionState.connecting,
          probe: GhostProbeState.offline,
        ),
        GhostServerGlyph.unreachable,
      );
      expect(
        list(session: GhostSessionState.idle, probe: GhostProbeState.unknown),
        GhostServerGlyph.reachabilityUnknown,
      );
    });

    test('connection truth renders when no probe result exists', () {
      expect(
        list(session: GhostSessionState.connected),
        GhostServerGlyph.connected,
      );
      expect(
        list(session: GhostSessionState.connecting),
        GhostServerGlyph.connecting,
      );
      expect(list(session: GhostSessionState.idle), GhostServerGlyph.idle);
    });
  });

  group('words', () {
    test('each glyph reads its own member of the bag', () {
      expect(
        {
          for (final glyph in GhostServerGlyph.values)
            glyph: _worded.labelOf(glyph),
        },
        {
          GhostServerGlyph.none: null,
          GhostServerGlyph.connecting: 'connecting',
          GhostServerGlyph.connected: 'connected',
          GhostServerGlyph.idle: 'idle',
          GhostServerGlyph.failed: 'failed',
          GhostServerGlyph.blocked: 'blocked',
          GhostServerGlyph.reachable: 'online',
          GhostServerGlyph.unreachable: 'offline',
          GhostServerGlyph.reachabilityUnknown: 'unknown',
        },
      );
    });

    test('only a block carries a detail', () {
      for (final glyph in GhostServerGlyph.values) {
        expect(
          _worded.detailOf(glyph),
          glyph == GhostServerGlyph.blocked ? 'review the key' : isNull,
          reason: '$glyph',
        );
      }
    });

    test('a resolved indicator carries its glyph\'s words', () {
      final indicator = ghostServerIndicator(
        _worded,
        GhostIndicatorRule.rail,
        session: GhostSessionState.blocked,
        probe: GhostProbeState.online,
      );

      expect(indicator.label, 'blocked');
      expect(indicator.detail, 'review the key');
    });

    test('the defaults are Séance\'s words, with none for idle or unknown', () {
      const strings = GhostServerStatusStrings();
      expect(
        {
          for (final glyph in GhostServerGlyph.values)
            glyph: strings.labelOf(glyph),
        },
        {
          GhostServerGlyph.none: null,
          GhostServerGlyph.connecting: 'Connecting',
          GhostServerGlyph.connected: 'Connected',
          GhostServerGlyph.idle: null,
          GhostServerGlyph.failed: 'Connection failed',
          GhostServerGlyph.blocked: 'Connection blocked',
          GhostServerGlyph.reachable: 'Host reachable',
          GhostServerGlyph.unreachable: 'Host unreachable',
          GhostServerGlyph.reachabilityUnknown: null,
        },
      );
      expect(
        strings.detailOf(GhostServerGlyph.blocked),
        'The host key changed. Review it at the next connection attempt.',
      );
      expect(strings.hiddenConnected, 'Connected server hidden');
      expect(strings.hiddenConnecting, 'Connecting server hidden');
    });
  });

  group('paint', () {
    test('sessions are solid, probe answers a ring, a block the no-entry '
        'sign', () {
      expect(
        {for (final glyph in GhostServerGlyph.values) glyph: glyph.style},
        {
          GhostServerGlyph.none: SidebarDotStyle.solid,
          GhostServerGlyph.connecting: SidebarDotStyle.solid,
          GhostServerGlyph.connected: SidebarDotStyle.solid,
          GhostServerGlyph.idle: SidebarDotStyle.solid,
          GhostServerGlyph.failed: SidebarDotStyle.solid,
          GhostServerGlyph.blocked: SidebarDotStyle.blocked,
          GhostServerGlyph.reachable: SidebarDotStyle.ring,
          GhostServerGlyph.unreachable: SidebarDotStyle.ring,
          GhostServerGlyph.reachabilityUnknown: SidebarDotStyle.solid,
        },
      );
    });

    test('green, amber and red; idle and unknown paint nothing', () {
      expect(
        {for (final glyph in GhostServerGlyph.values) glyph: glyph.tone},
        {
          GhostServerGlyph.none: null,
          GhostServerGlyph.connecting: GhostStatusTone.connecting,
          GhostServerGlyph.connected: GhostStatusTone.online,
          GhostServerGlyph.idle: null,
          GhostServerGlyph.failed: GhostStatusTone.offline,
          GhostServerGlyph.blocked: GhostStatusTone.offline,
          GhostServerGlyph.reachable: GhostStatusTone.online,
          GhostServerGlyph.unreachable: GhostStatusTone.offline,
          GhostServerGlyph.reachabilityUnknown: null,
        },
      );
    });

    test('the dot takes the host\'s colour for its tone and its style', () {
      SidebarStatusDot? dot(GhostServerGlyph glyph) =>
          ghostStatusDot(GhostServerIndicator(glyph: glyph), _colors);

      expect(dot(GhostServerGlyph.connected), SidebarStatusDot(_colors.online));
      expect(
        dot(GhostServerGlyph.connecting),
        SidebarStatusDot(_colors.connecting),
      );
      expect(dot(GhostServerGlyph.failed), SidebarStatusDot(_colors.offline));
      expect(
        dot(GhostServerGlyph.blocked),
        SidebarStatusDot(_colors.offline, style: SidebarDotStyle.blocked),
      );
      expect(
        dot(GhostServerGlyph.reachable),
        SidebarStatusDot(_colors.online, style: SidebarDotStyle.ring),
      );
      expect(
        dot(GhostServerGlyph.unreachable),
        SidebarStatusDot(_colors.offline, style: SidebarDotStyle.ring),
      );
      expect(dot(GhostServerGlyph.none), isNull);
      expect(dot(GhostServerGlyph.idle), isNull);
      expect(dot(GhostServerGlyph.reachabilityUnknown), isNull);
    });
  });

  group('ghostAggregateSession', () {
    test('no sessions is no session at all', () {
      expect(ghostAggregateSession(const []), GhostSessionState.none);
    });

    test('connecting, then connected, blocked, failed, else idle', () {
      expect(
        ghostAggregateSession([
          GhostSessionState.failed,
          GhostSessionState.connected,
          GhostSessionState.connecting,
        ]),
        GhostSessionState.connecting,
      );
      expect(
        ghostAggregateSession([
          GhostSessionState.idle,
          GhostSessionState.blocked,
          GhostSessionState.connected,
        ]),
        GhostSessionState.connected,
      );
      expect(
        ghostAggregateSession([
          GhostSessionState.failed,
          GhostSessionState.blocked,
          GhostSessionState.idle,
        ]),
        GhostSessionState.blocked,
      );
      expect(
        ghostAggregateSession([
          GhostSessionState.idle,
          GhostSessionState.failed,
        ]),
        GhostSessionState.failed,
      );
      expect(
        ghostAggregateSession([GhostSessionState.idle]),
        GhostSessionState.idle,
      );
    });
  });

  group('ghostHiddenLiveIndicator', () {
    test('a connection up outranks one being attempted', () {
      final indicator = ghostHiddenLiveIndicator(_worded, [
        GhostSessionState.connecting,
        GhostSessionState.connected,
      ]);

      expect(indicator?.glyph, GhostServerGlyph.connected);
      expect(indicator?.label, 'connected hidden');
    });

    test('an attempt alone reads as connecting', () {
      final indicator = ghostHiddenLiveIndicator(_worded, [
        GhostSessionState.failed,
        GhostSessionState.connecting,
      ]);

      expect(indicator?.glyph, GhostServerGlyph.connecting);
      expect(indicator?.label, 'connecting hidden');
    });

    test('nothing live is no indicator, failures included', () {
      expect(
        ghostHiddenLiveIndicator(_worded, [
          GhostSessionState.none,
          GhostSessionState.idle,
          GhostSessionState.failed,
          GhostSessionState.blocked,
        ]),
        isNull,
      );
      expect(ghostHiddenLiveIndicator(_worded, const []), isNull);
    });
  });
}
