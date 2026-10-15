import 'package:flutter/material.dart';
import 'package:ghost_servers/ghost_servers.dart';
import 'package:ghost_theme/ghost_theme.dart' show GhostChrome;
import 'package:ghost_ui/ghost_ui.dart' show SidebarDotStyle, SidebarStatusDot;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'access/access_panel.dart' show engineNameText;
import 'coverage.dart' show ServerCoverageChip;
import 'fleet_rail.dart' show linkStatusWord;
import 'fleet_row_state.dart';
import 'fleet_rows.dart' show fleetStatusIcon, fleetStatusStrings;

/// The server header of 03 §10.2 and §10.5: the server's name, unless the
/// phone's app bar carries it, its link state, the coverage chip, the
/// detected runtime, and any messages about what this client cannot do
/// for the server.
///
/// The state resolves through `ghostServerIndicator` under the rail rule,
/// as the server's fleet row does, so both read the same: a dot, an icon
/// and a word (A11Y-01). Where the indicator shows nothing, the link's own
/// word stands, so the header always says the state. Everything wraps
/// rather than clips at large text (A11Y-09).
class ServerHeader extends StatelessWidget {
  const ServerHeader({
    super.key,
    required this.server,
    required this.fleet,
    required this.monitoring,
    this.showTitle = true,
    this.limitations = const [],
  });

  final FleetServer server;

  /// The link status and the probe's answer arrive through it; the owner
  /// rebuilds the header when it notifies.
  final FleetController fleet;

  /// The probe's profile, for the runtime.
  final MonitoringController monitoring;

  final bool showTitle;

  /// Client-limitation messages (03 §5.3), each ARB text, shown under the
  /// header's facts. None arrive before K45 words them.
  final List<String> limitations;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (showTitle)
              Semantics(
                header: true,
                child: Text(
                  AppLocalizations.of(context).serverTitle(server.displayName),
                  style: theme.textTheme.titleLarge,
                ),
              ),
            ServerLinkState(server: server, fleet: fleet),
          ],
        ),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ServerCoverageChip(fleet: fleet),
            // Re-read on every build: a server that left the fleet and came
            // back has a new profile listenable (SYN-08).
            ValueListenableBuilder<HostProfile?>(
              valueListenable: monitoring.profileFor(server.id),
              builder: (context, profile, _) => Text(
                detectedRuntimeText(AppLocalizations.of(context), profile),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        for (final message in limitations)
          MergeSemantics(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                Expanded(
                  child: Text(message, style: theme.textTheme.bodyMedium),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A server's link state as a dot, an icon and a word, read as one node
/// ("Server status: Connected").
class ServerLinkState extends StatelessWidget {
  const ServerLinkState({super.key, required this.server, required this.fleet});

  final FleetServer server;
  final FleetController fleet;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final chrome = GhostChrome.of(context, klabautermannThemeStyle);
    final link = fleet.linkStatusFor(server.id);
    final indicator = ghostServerIndicator(
      fleetStatusStrings(l10n, link),
      GhostIndicatorRule.rail,
      session: ghostSessionOf(link),
      probe: ghostProbeOf(fleet.reachabilityFor(server.id)),
    );
    final word = indicator.label ?? linkStatusWord(l10n, link);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      container: true,
      label: l10n.statusSemantics(word),
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            if (ghostStatusDot(
                  indicator,
                  GhostStatusColors(
                    online: chrome.statusConnected,
                    connecting: chrome.statusConnecting,
                    offline: chrome.statusFailed,
                  ),
                )
                case final dot?)
              _LinkDot(dot),
            Icon(
              fleetStatusIcon(indicator.glyph) ?? Icons.link_off,
              size: 16,
              color: muted,
            ),
            Flexible(
              child: Text(
                word,
                style: theme.textTheme.labelLarge?.copyWith(color: muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The indicator's dot on its own, as the sidebar kit draws it in a row's
/// mark, which keeps its painter private: solid for live truth, a ring for
/// a probe's observation, a bar through it for a refusal.
class _LinkDot extends StatelessWidget {
  const _LinkDot(this.dot);

  final SidebarStatusDot dot;

  static const double _extent = 10;

  @override
  Widget build(BuildContext context) {
    final ring = dot.style == SidebarDotStyle.ring;
    return Container(
      width: _extent,
      height: _extent,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: ring ? null : dot.color,
        border: ring ? Border.all(color: dot.color, width: 2) : null,
      ),
      child: dot.style == SidebarDotStyle.blocked
          ? Center(
              child: SizedBox(
                width: _extent * 0.6,
                height: 2,
                child: ColoredBox(color: Theme.of(context).colorScheme.surface),
              ),
            )
          : null,
    );
  }
}

/// The detected runtime (CN-09) in one line, from the access check over
/// the probe's [profile], as the Access tab derives it (03 §10.4): the
/// engines found, none, unknown, or not checked before the probe answers.
/// A Docker engine, known only by its socket's path, carries the Access
/// tab's caveat that a `podman-docker` install may answer there.
String detectedRuntimeText(AppLocalizations l10n, HostProfile? profile) {
  if (profile == null) return l10n.overviewHeaderRuntimeNotChecked;

  final access = evaluateAccess(profile);
  if (access.engines.isNotEmpty) {
    final engines = access.engines
        .map((engine) => engineNameText(l10n, engine))
        .join(l10n.overviewHeaderRuntimeSeparator);
    return access.engines.any((e) => e.runtime == EngineRuntime.docker)
        ? l10n.overviewHeaderRuntimeDockerPath(engines)
        : l10n.overviewHeaderRuntime(engines);
  }
  return switch (access.row(AccessItem.runtime).status) {
    AccessStatus.missing => l10n.overviewHeaderRuntimeNone,
    AccessStatus.ok ||
    AccessStatus.unknown => l10n.overviewHeaderRuntimeUnknown,
  };
}
