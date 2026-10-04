import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

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
ServerIndicatorAppearance serverIndicatorOf(
  AppLocalizations l10n, {
  ServerStatus? status,
  ProbeStatus? probe,
}) {
  final connection = status == null
      ? null
      : _connectionAppearance(l10n, status);
  if (connection != null && _outranksProbe(connection.glyph, probe)) {
    return connection;
  }

  final reachability = probe == null ? null : _probeAppearance(l10n, probe);
  if (reachability != null) return reachability;

  return connection ?? (glyph: ServerIndicatorGlyph.none, label: '');
}

/// The D32 rail's resolution (10 §5). The rail tells "connected" (a
/// disc) apart from "reachable" (a ring), so any connection truth
/// beyond idle outranks the probe here: a live or in-flight transport
/// must never read as merely reachable, which [serverIndicatorOf]'s
/// tri-state list rule would show for a connected or connecting server
/// whose probe answered. With no connection (or an idle one) the probe
/// speaks, exactly as there.
ServerIndicatorAppearance railIndicatorOf(
  AppLocalizations l10n, {
  ServerStatus? status,
  ProbeStatus? probe,
}) {
  final connection = status == null
      ? null
      : _connectionAppearance(l10n, status);
  if (connection != null && connection.glyph != ServerIndicatorGlyph.idle) {
    return connection;
  }
  return serverIndicatorOf(l10n, status: status, probe: probe);
}

/// The glyphs that contradict a probe result and therefore replace it:
/// adverse truth (a block, a failure the state explains) always, and
/// authenticated transports over any non-online result — the reverse of
/// the audit finding's contradiction, since connected transports prove
/// reachability (an "unknown" claim beside them is just as wrong).
/// Pending and idle never replace a probe: an in-flight attempt does not
/// contradict the last reachability result (if the host is truly down the
/// attempt fails into a failure glyph), and a server with no transport
/// keeps the probe's answer.
bool _outranksProbe(ServerIndicatorGlyph glyph, ProbeStatus? probe) =>
    switch (glyph) {
      ServerIndicatorGlyph.blocked || ServerIndicatorGlyph.failed => true,
      ServerIndicatorGlyph.connected => probe != ProbeStatus.online,
      _ => false,
    };

/// A `detail` on the status means the state explains a failure (03 §3.2);
/// cancellation and idle teardown carry none, so `disconnected` splits into
/// [ServerIndicatorGlyph.failed] and [ServerIndicatorGlyph.idle].
ServerIndicatorAppearance _connectionAppearance(
  AppLocalizations l10n,
  ServerStatus status,
) {
  final failed = status.detail != null;
  return switch (status.state) {
    ServerConnectionState.connecting => (
      glyph: ServerIndicatorGlyph.pending,
      label: l10n.connectionStateConnecting,
    ),
    ServerConnectionState.reconnecting => (
      glyph: ServerIndicatorGlyph.pending,
      label: l10n.connectionStateReconnecting,
    ),
    ServerConnectionState.connected => (
      glyph: ServerIndicatorGlyph.connected,
      label: l10n.connectionStateConnected,
    ),
    ServerConnectionState.disconnected =>
      failed
          ? (
              glyph: ServerIndicatorGlyph.failed,
              label: l10n.connectionFailedTitle,
            )
          : (
              glyph: ServerIndicatorGlyph.idle,
              label: l10n.connectionStateNotConnected,
            ),
    ServerConnectionState.blocked => (
      glyph: ServerIndicatorGlyph.blocked,
      label: l10n.connectionBlockedTitle,
    ),
  };
}

ServerIndicatorAppearance _probeAppearance(
  AppLocalizations l10n,
  ProbeStatus probe,
) {
  return switch (probe) {
    ProbeStatus.online => (
      glyph: ServerIndicatorGlyph.probe,
      label: l10n.probeStatusOnline,
    ),
    ProbeStatus.offline => (
      glyph: ServerIndicatorGlyph.probe,
      label: l10n.probeStatusOffline,
    ),
    ProbeStatus.unknown => (
      glyph: ServerIndicatorGlyph.probe,
      label: l10n.probeStatusUnknown,
    ),
  };
}

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
