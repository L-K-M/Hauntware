/// The one status dot a server row composes into its mark.
///
/// The sibling contract (Poltergeist's plan, 10 §5 and §10) gives both apps
/// the same dot for the same truth, so a server that shows in Séance's rail
/// and in Poltergeist's SERVERS reads identically in each:
///
/// - connected: solid green
/// - connecting: solid amber
/// - failed: solid red
/// - blocked (the host key no longer matches the pinned one): a red dot
///   crossed by a bar, the kit's no-entry sign, as Poltergeist draws it
/// - reachable (the probe answered, nothing is connected): a hollow green
///   ring
/// - unknown, or idle with no probe answer: no dot
///
/// Séance's probe also reports hosts it could not reach, which the contract
/// leaves open. They draw a hollow red ring: hollow because it is the same
/// weaker, observed kind of fact as "reachable", red because a solid red dot
/// already means a session failed.
///
/// The vocabulary itself, the rules and the paint map, lives in
/// Planchette's `ghost_servers` since 2026-10-13
/// (docs/design/ghost-servers-part1.md, PR 3); [ServerDot] is Séance's
/// name for its glyphs, and the functions here delegate to it through
/// `ghost_servers_adapter.dart`.
library;

import 'package:flutter/material.dart';
import 'package:ghost_servers/ghost_servers.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import 'ghost_servers_adapter.dart';
import 'sidebar/sidebar_kit.dart';

enum ServerDot {
  none(GhostServerGlyph.none),
  connected(GhostServerGlyph.connected),
  connecting(GhostServerGlyph.connecting),
  failed(GhostServerGlyph.failed),
  blocked(GhostServerGlyph.blocked),
  reachable(GhostServerGlyph.reachable),
  unreachable(GhostServerGlyph.unreachable);

  const ServerDot(this._glyph);

  final GhostServerGlyph _glyph;

  /// What the dot says, folded into the row's tooltip and spoken label
  /// (the row's visuals are excluded from semantics). Null for no dot.
  String? get description => seanceServerStatusStrings.labelOf(_glyph);

  /// What to do about the state, where the state alone does not say it:
  /// folded into the tooltip and label after [description].
  String? get detail => seanceServerStatusStrings.detailOf(_glyph);

  /// Live session truth is solid; a probe's observation is a ring; a
  /// refusal the user has to act on is the no-entry sign.
  SidebarDotStyle get style => _glyph.style;

  /// The colour to paint, or null for no dot.
  Color? color(BuildContext context) => switch (_glyph.tone) {
    final tone? => seanceStatusColors(context).colorOf(tone),
    null => null,
  };
}

/// The dot for a server whose terminal sessions aggregate to [session]
/// (null when it has none) and whose last probe said [probe]; a failed
/// session that [hostKeyBlocked] reads as blocked rather than failed.
///
/// A live session outranks the probe: a connected server is connected even
/// if the last probe timed out. A session that ended cleanly is idle, and
/// the probe speaks again. This is the shared rail rule.
ServerDot serverDotFor({
  required TerminalStatus? session,
  required ProbeStatus probe,
  bool hostKeyBlocked = false,
}) {
  final indicator = ghostServerIndicator(
    seanceServerStatusStrings,
    GhostIndicatorRule.rail,
    session: ghostSessionOf(session, hostKeyBlocked: hostKeyBlocked),
    probe: ghostProbeOf(probe),
  );
  return switch (indicator.glyph) {
    GhostServerGlyph.connected => ServerDot.connected,
    GhostServerGlyph.connecting => ServerDot.connecting,
    GhostServerGlyph.failed => ServerDot.failed,
    GhostServerGlyph.blocked => ServerDot.blocked,
    GhostServerGlyph.reachable => ServerDot.reachable,
    GhostServerGlyph.unreachable => ServerDot.unreachable,
    // Séance always has a probe answer, so the rail rule never comes back
    // idle here; an unknown answer is no dot, like no truth at all.
    GhostServerGlyph.none ||
    GhostServerGlyph.idle ||
    GhostServerGlyph.reachabilityUnknown => ServerDot.none,
  };
}

/// Aggregate a server's terminal tabs into the one state its row shows: any
/// connecting wins, else any connected, else any error, else disconnected.
/// Null when the server has no terminal tab at all.
TerminalStatus? aggregateSessionStatus(Iterable<TerminalSession> tabs) =>
    terminalStatusOf(
      ghostAggregateSession([
        for (final tab in tabs) ghostSessionOf(tab.status),
      ]),
    );
