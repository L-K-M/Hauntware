import 'package:flutter/material.dart';
import 'package:ghost_servers/ghost_servers.dart'
    show GhostIndicatorRule, GhostServerGlyph, GhostServerIndicator;
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'ghost_servers_adapter.dart';

/// What the one composed server indicator paints (02 §4: exactly one
/// indicator per server — SEA-021).
enum ServerIndicatorGlyph {
  /// Neither truth exists: paint nothing.
  none,

  /// Probe truth only: the caller paints the reachability result itself
  /// (the sidebar's status dot); [ServerStateGlyph] has no probe paint.
  probe,

  /// A connect or recovery attempt is running.
  pending,

  /// Authenticated transports exist.
  connected,

  /// No transport and no failure the state explains.
  idle,

  /// No transport and a failure one-liner.
  failed,

  /// Host-key block (D18): every operation fails until an explicit review.
  blocked,
}

/// One server's resolved indicator: the glyph to paint plus its ARB label.
/// Tooltip, semantics, and list copy all read this same pair, so a state can
/// never be announced with wording its glyph contradicts.
typedef ServerIndicatorAppearance = ({
  ServerIndicatorGlyph glyph,
  String label,
});

/// Resolves the single indicator a server renders.
///
/// [status] is live connection truth (`EngineClient.watchServer`), [probe]
/// reachability truth. Adverse connection truth — a block or a failure the
/// state explains — outranks the probe result: a probe reports only that
/// host:port answered a TCP connect, so a green "reachable" dot beside a
/// blocked panel contradicts the connection it sits next to (02 §4 — "live
/// truth outranks probes"). Where the two truths do not contradict, 02 §4's
/// tri-state probe dot stays the favorite row's indicator, which is what
/// 07 §3.3 requires the interim list to render.
///
/// The shared list rule (`ghost_servers`, `GhostIndicatorRule.list`) since
/// 2026-10-13; this keeps the app's glyph vocabulary and ARB words.
ServerIndicatorAppearance serverIndicatorOf(
  AppLocalizations l10n, {
  ServerStatus? status,
  ProbeStatus? probe,
}) => serverIndicatorAppearance(
  resolveServerIndicator(
    l10n,
    GhostIndicatorRule.list,
    status: status,
    probe: probe,
  ),
);

/// The D32 rail's resolution (10 §5). The rail tells "connected" (a
/// disc) apart from "reachable" (a ring), so any connection truth
/// beyond idle outranks the probe here: a live or in-flight transport
/// must never read as merely reachable, which [serverIndicatorOf]'s
/// tri-state list rule would show for a connected or connecting server
/// whose probe answered. With no connection (or an idle one) the probe
/// speaks, exactly as there.
///
/// The shared rail rule (`ghost_servers`, `GhostIndicatorRule.rail`),
/// Séance's only rule, since 2026-10-13. The sidebar rail resolves it
/// through the adapter itself, to take its words and its dot from one
/// resolution.
ServerIndicatorAppearance railIndicatorOf(
  AppLocalizations l10n, {
  ServerStatus? status,
  ProbeStatus? probe,
}) => serverIndicatorAppearance(
  resolveServerIndicator(
    l10n,
    GhostIndicatorRule.rail,
    status: status,
    probe: probe,
  ),
);

/// A shared indicator in this app's glyph vocabulary: every probe answer
/// is the one [ServerIndicatorGlyph.probe] marker (the caller paints the
/// reachability dot), and a state without words reads as the empty label.
ServerIndicatorAppearance serverIndicatorAppearance(
  GhostServerIndicator indicator,
) => (
  glyph: switch (indicator.glyph) {
    GhostServerGlyph.none => ServerIndicatorGlyph.none,
    GhostServerGlyph.connecting => ServerIndicatorGlyph.pending,
    GhostServerGlyph.connected => ServerIndicatorGlyph.connected,
    GhostServerGlyph.idle => ServerIndicatorGlyph.idle,
    GhostServerGlyph.failed => ServerIndicatorGlyph.failed,
    GhostServerGlyph.blocked => ServerIndicatorGlyph.blocked,
    GhostServerGlyph.reachable ||
    GhostServerGlyph.unreachable ||
    GhostServerGlyph.reachabilityUnknown => ServerIndicatorGlyph.probe,
  },
  label: indicator.label ?? '',
);

/// The composed indicator's paint, without a label: for rows that render the
/// state as text beside it.
class ServerStateGlyph extends StatelessWidget {
  const ServerStateGlyph(this.glyph, {super.key});

  /// The painted dot's diameter.
  static const dotSize = 10.0;

  /// The padded box every glyph is centred in: a 10 px paint alone is not a
  /// practical hover or touch target.
  static const boxSize = 24.0;

  final ServerIndicatorGlyph glyph;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chrome = PoltergeistChrome.of(context);

    // Probe truth has no paint here: a caller that shows reachability
    // paints its own dot for it. Reaching for this glyph with probe truth
    // trips the assert in debug builds; release builds strip asserts and
    // paint nothing, so misuse there is silent.
    assert(
      glyph != ServerIndicatorGlyph.probe,
      'Probe truth must be painted by the caller; '
      'ServerStateGlyph has no probe paint.',
    );

    return SizedBox(
      width: boxSize,
      height: boxSize,
      child: Center(
        child: switch (glyph) {
          ServerIndicatorGlyph.none ||
          ServerIndicatorGlyph.probe => const SizedBox.shrink(),
          ServerIndicatorGlyph.pending => SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: scheme.primary,
            ),
          ),
          // The palette's one "connected" green.
          ServerIndicatorGlyph.connected => _dot(chrome.statusConnected),
          // The theme's status colours, as the rail's dots paint them.
          ServerIndicatorGlyph.idle => _dot(chrome.statusUnknown),
          ServerIndicatorGlyph.failed => _dot(chrome.statusFailed),
          ServerIndicatorGlyph.blocked => Icon(
            Icons.gpp_bad,
            size: 14,
            color: chrome.statusFailed,
          ),
        },
      ),
    );
  }

  static Widget _dot(Color color) => Container(
    width: dotSize,
    height: dotSize,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}
