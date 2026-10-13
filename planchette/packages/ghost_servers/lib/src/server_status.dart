/// The status-dot vocabulary: the one indicator a server row composes from
/// live session truth and the reachability probe, shared by Séance's rail
/// and Poltergeist's SERVERS so the same truth reads the same way in both.
///
/// Neither app's truth types cross this boundary. Séance's
/// `TerminalStatus`, Poltergeist's `ServerStatus` and the cores'
/// `ProbeStatus` live outside the permitted dependencies, so each app maps
/// its truth onto [GhostSessionState] and [GhostProbeState] in its adapter
/// and resolves through [ghostServerIndicator]. Wording comes in through
/// [GhostServerStatusStrings], colours through [GhostStatusColors].
///
/// The precedence is not one rule (docs/design/ghost-servers-part1.md
/// §1.2): the rail lets live truth outrank the probe, the list keeps the
/// probe wherever live truth does not contradict it, and the tab
/// aggregation ranks an attempt in flight above an open session. Each is a
/// named rule here and every surface keeps the rule it used before the
/// move.
library;

import 'package:flutter/widgets.dart';
import 'package:ghost_ui/ghost_ui.dart' show SidebarDotStyle, SidebarStatusDot;

/// A server's live session truth, reduced to what an indicator tells apart.
enum GhostSessionState {
  /// No session at all.
  none,

  /// An attempt is running: a first connect or a recovery.
  connecting,

  /// An authenticated session is open.
  connected,

  /// A session ended without a failure to explain (closed, cancelled, idle
  /// teardown).
  idle,

  /// A session ended on a failure the state explains.
  failed,

  /// The host key no longer matches the pinned one: every attempt fails
  /// until the user reviews it.
  blocked,
}

/// The reachability probe's last answer. A surface with no probe at all
/// passes null instead, which the rules treat differently from [unknown].
enum GhostProbeState {
  /// The probe could not tell: a timeout or a host reachable only through
  /// a jump host or VPN. Not the same as [offline].
  unknown,

  /// The host answered.
  online,

  /// The host refused.
  offline,
}

/// Which precedence a surface resolves with.
enum GhostIndicatorRule {
  /// Poltergeist's pane tabs, which pass no probe: the probe's own answer
  /// stays wherever live truth does not contradict it. Server rows in
  /// both apps resolve with [rail].
  list,

  /// Séance's rail and Poltergeist's sidebar rail: any live truth beyond
  /// idle outranks the probe.
  rail,
}

/// The colour family a glyph paints in; the host's palette supplies the
/// colour ([GhostStatusColors]).
enum GhostStatusTone { online, connecting, offline }

/// What a resolved indicator shows.
enum GhostServerGlyph {
  /// Neither truth: nothing to show.
  none,

  /// An attempt is running.
  connecting,

  /// A session is open.
  connected,

  /// A session ended cleanly and no probe speaks for the host.
  idle,

  /// A session failed.
  failed,

  /// The host key changed: a refusal the user has to act on.
  blocked,

  /// The probe reached a host nothing is connected to.
  reachable,

  /// The probe was refused.
  unreachable,

  /// The probe could not tell. Painted like [none], but it has words of
  /// its own where the host's strings give it some.
  reachabilityUnknown;

  /// Live session truth is solid, a probe's observation is a ring, and a
  /// refusal to act on is the no-entry sign. Glyphs without a dot keep the
  /// solid default.
  SidebarDotStyle get style => switch (this) {
    reachable || unreachable => SidebarDotStyle.ring,
    blocked => SidebarDotStyle.blocked,
    _ => SidebarDotStyle.solid,
  };

  /// The colour family to paint, or null for no dot: idle and an unknown
  /// probe answer paint nothing, like no truth at all.
  GhostStatusTone? get tone => switch (this) {
    connected || reachable => GhostStatusTone.online,
    connecting => GhostStatusTone.connecting,
    failed || blocked || unreachable => GhostStatusTone.offline,
    none || idle || reachabilityUnknown => null,
  };
}

/// The words a status indicator speaks, as one bag. The defaults are
/// Séance's, so Séance passes nothing; a host with localized copy passes
/// its own. The nullable members are states a host may have no word for
/// (Séance has none for idle or an unknown probe answer); the indicator
/// then carries no label.
final class GhostServerStatusStrings {
  const GhostServerStatusStrings({
    this.connected = 'Connected',
    this.connecting = 'Connecting',
    this.failed = 'Connection failed',
    this.blocked = 'Connection blocked',
    this.notConnected,
    this.probeOnline = 'Host reachable',
    this.probeOffline = 'Host unreachable',
    this.probeUnknown,
    this.blockedDetail =
        'The host key changed. Review it at the next connection attempt.',
    this.hiddenConnected = 'Connected server hidden',
    this.hiddenConnecting = 'Connecting server hidden',
  });

  /// [GhostServerGlyph.connected].
  final String connected;

  /// [GhostServerGlyph.connecting]. A host that words a recovery attempt
  /// differently from a first connect passes the word for the attempt at
  /// hand.
  final String connecting;

  /// [GhostServerGlyph.failed].
  final String failed;

  /// [GhostServerGlyph.blocked].
  final String blocked;

  /// [GhostServerGlyph.idle]. Séance has none.
  final String? notConnected;

  /// [GhostServerGlyph.reachable].
  final String probeOnline;

  /// [GhostServerGlyph.unreachable].
  final String probeOffline;

  /// [GhostServerGlyph.reachabilityUnknown]. Séance has none.
  final String? probeUnknown;

  /// What to do about a block, where the state alone does not say it.
  final String? blockedDetail;

  /// A section header's words for a connected server it keeps out of view.
  final String hiddenConnected;

  /// A section header's words for a connecting server it keeps out of
  /// view.
  final String hiddenConnecting;

  /// The word for [glyph], or null where this bag has none.
  String? labelOf(GhostServerGlyph glyph) => switch (glyph) {
    GhostServerGlyph.none => null,
    GhostServerGlyph.connecting => connecting,
    GhostServerGlyph.connected => connected,
    GhostServerGlyph.idle => notConnected,
    GhostServerGlyph.failed => failed,
    GhostServerGlyph.blocked => blocked,
    GhostServerGlyph.reachable => probeOnline,
    GhostServerGlyph.unreachable => probeOffline,
    GhostServerGlyph.reachabilityUnknown => probeUnknown,
  };

  /// What to do about [glyph], or null where the state says it all.
  String? detailOf(GhostServerGlyph glyph) =>
      glyph == GhostServerGlyph.blocked ? blockedDetail : null;
}

/// One server's resolved indicator: what it shows and the words for it.
/// Tooltip, semantics and list copy read this same value, so a state is
/// never announced with words its dot contradicts.
@immutable
final class GhostServerIndicator {
  const GhostServerIndicator({required this.glyph, this.label, this.detail});

  final GhostServerGlyph glyph;

  /// The state in words; null where the host has none for it.
  final String? label;

  /// What to do about the state, after [label]; null for most states.
  final String? detail;

  SidebarDotStyle get style => glyph.style;

  /// Null when no dot is painted.
  GhostStatusTone? get tone => glyph.tone;
}

/// Resolves the one indicator a server shows under [rule] from its live
/// [session] and its [probe] (null where the surface has no probe at all).
GhostServerIndicator ghostServerIndicator(
  GhostServerStatusStrings strings,
  GhostIndicatorRule rule, {
  required GhostSessionState session,
  required GhostProbeState? probe,
}) {
  final glyph = switch (rule) {
    GhostIndicatorRule.list => _listGlyph(session, probe),
    GhostIndicatorRule.rail => _railGlyph(session, probe),
  };
  return GhostServerIndicator(
    glyph: glyph,
    label: strings.labelOf(glyph),
    detail: strings.detailOf(glyph),
  );
}

/// The rail tells "connected" (a disc) apart from "reachable" (a ring), so
/// any live truth beyond idle outranks the probe: an open or in-flight
/// session never reads as merely reachable, and a connected server is
/// connected even if the last probe timed out. With no session, or one
/// that ended cleanly, the probe speaks, as in the list rule.
GhostServerGlyph _railGlyph(
  GhostSessionState session,
  GhostProbeState? probe,
) => switch (session) {
  GhostSessionState.none ||
  GhostSessionState.idle => _listGlyph(session, probe),
  _ => _sessionGlyph(session),
};

/// The probe's tri-state answer stays the row's indicator wherever live
/// truth does not contradict it. Adverse truth (a block, a failure) always
/// replaces it: a probe only reports that host:port answered a TCP
/// connect, so a "reachable" ring beside a refused connection contradicts
/// the connection. An open session replaces any answer but online, since
/// it proves reachability. An attempt in flight or an idle session never
/// replaces it: an attempt does not contradict the last answer (if the
/// host is down it fails into [GhostServerGlyph.failed]). With no probe at
/// all, the session speaks.
GhostServerGlyph _listGlyph(GhostSessionState session, GhostProbeState? probe) {
  final outranksProbe = switch (session) {
    GhostSessionState.blocked || GhostSessionState.failed => true,
    GhostSessionState.connected => probe != GhostProbeState.online,
    _ => false,
  };
  if (outranksProbe) return _sessionGlyph(session);

  return switch (probe) {
    GhostProbeState.online => GhostServerGlyph.reachable,
    GhostProbeState.offline => GhostServerGlyph.unreachable,
    GhostProbeState.unknown => GhostServerGlyph.reachabilityUnknown,
    null => _sessionGlyph(session),
  };
}

GhostServerGlyph _sessionGlyph(GhostSessionState session) => switch (session) {
  GhostSessionState.none => GhostServerGlyph.none,
  GhostSessionState.connecting => GhostServerGlyph.connecting,
  GhostSessionState.connected => GhostServerGlyph.connected,
  GhostSessionState.idle => GhostServerGlyph.idle,
  GhostSessionState.failed => GhostServerGlyph.failed,
  GhostSessionState.blocked => GhostServerGlyph.blocked,
};

/// The order [ghostAggregateSession] ranks a server's sessions in. A block
/// ranks above a plain failure because it is the more specific refusal,
/// the one the user has to act on.
const _aggregateRank = [
  GhostSessionState.connecting,
  GhostSessionState.connected,
  GhostSessionState.blocked,
  GhostSessionState.failed,
  GhostSessionState.idle,
];

/// Aggregates a server's sessions (its terminal tabs, say) into the one
/// state its row shows: any connecting wins, else any connected, else any
/// blocked, else any failed, else idle. [GhostSessionState.none] when
/// there are none.
GhostSessionState ghostAggregateSession(Iterable<GhostSessionState> states) {
  final present = states.toSet();
  for (final state in _aggregateRank) {
    if (present.contains(state)) return state;
  }
  return GhostSessionState.none;
}

/// What a section header shows for the servers it keeps out of view
/// (folded away, or hidden by a filter), so "what am I connected to" never
/// needs an unfold: connected while one of them is, else connecting while
/// one is, else null, as nothing there is live. A failure is left to its
/// row: folding is a choice not to look, and what must not vanish with it
/// is a connection still open.
GhostServerIndicator? ghostHiddenLiveIndicator(
  GhostServerStatusStrings strings,
  Iterable<GhostSessionState> live,
) {
  var connecting = false;
  for (final state in live) {
    switch (state) {
      case GhostSessionState.connected:
        return GhostServerIndicator(
          glyph: GhostServerGlyph.connected,
          label: strings.hiddenConnected,
        );
      case GhostSessionState.connecting:
        connecting = true;
      case _:
        break;
    }
  }
  if (!connecting) return null;

  return GhostServerIndicator(
    glyph: GhostServerGlyph.connecting,
    label: strings.hiddenConnecting,
  );
}

/// The host palette's status colours, one per [GhostStatusTone]; each app's
/// adapter maps its own theme onto them.
@immutable
final class GhostStatusColors {
  const GhostStatusColors({
    required this.online,
    required this.connecting,
    required this.offline,
  });

  final Color online;
  final Color connecting;
  final Color offline;

  Color colorOf(GhostStatusTone tone) => switch (tone) {
    GhostStatusTone.online => online,
    GhostStatusTone.connecting => connecting,
    GhostStatusTone.offline => offline,
  };
}

/// The sidebar dot [indicator] paints in [colors], or null for none.
SidebarStatusDot? ghostStatusDot(
  GhostServerIndicator indicator,
  GhostStatusColors colors,
) => switch (indicator.tone) {
  final tone? => SidebarStatusDot(colors.colorOf(tone), style: indicator.style),
  null => null,
};
