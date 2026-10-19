import 'package:flutter/foundation.dart' show ValueListenable;
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
import 'docker/docker_endpoint.dart';
import 'fleet_rail.dart' show linkFailureText, linkStatusWord;
import 'fleet_row_state.dart';
import 'fleet_rows.dart' show fleetStatusIcon, fleetStatusStrings;
import 'admin_mode_chip.dart';
import 'server_safety.dart';

/// The server header of 03 §10.2 and §10.5: the server's name, unless the
/// phone's app bar carries it, its link state, the coverage chip, the
/// runtime, the Docker transport label in every mode (03 §5.9, E4) with
/// SAF-08's engine badge and the low-session indicator, and why the link
/// failed when the engine could tell, a client limitation (03 §5.3)
/// included.
///
/// Once the Docker endpoint names a route, the runtime is the engine the
/// API names there (M13), without the caveat that Podman may answer on
/// Docker's path; before, it is the probe's detected runtime.
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

  /// The probe's profile, for the runtime, and the Docker endpoint.
  final MonitoringController monitoring;

  final bool showTitle;

  /// Further client-limitation messages (03 §5.3), each ARB text, shown
  /// under the link failure: the phones' background line (PLT-04).
  final List<String> limitations;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failure = linkFailureText(
      AppLocalizations.of(context),
      fleet.linkStatusFor(server.id),
    );
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
            ServerSafetyMenu(
              serverId: server.id,
              serverName: server.displayName,
            ),
            AdminModeChip(serverId: server.id),
          ],
        ),
        _EngineFacts(
          // Re-read on every build: a server that left the fleet and came
          // back has new listenables (SYN-08).
          profile: monitoring.profileFor(server.id),
          endpoint: monitoring.docker.endpointFor(server.id),
          leading: ServerCoverageChip(fleet: fleet),
        ),
        for (final message in [
          ?failure,
          ...serverSafetyNotices(context, server.id),
          ...adminNotices(context, server.id),
          ...limitations,
        ])
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

/// [leading], then the runtime, the Docker transport label, SAF-08's
/// badge for the engine a route reaches and the low-session indicator,
/// wrapping at large text.
class _EngineFacts extends StatelessWidget {
  const _EngineFacts({
    required this.profile,
    required this.endpoint,
    required this.leading,
  });

  final ValueListenable<HostProfile?> profile;
  final ValueListenable<DockerEndpointState?> endpoint;
  final Widget leading;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([profile, endpoint]),
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      final theme = Theme.of(context);
      final style = theme.textTheme.labelMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      );
      final state = endpoint.value;
      final route = state?.route;
      return Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          leading,
          Text(
            route == null
                ? detectedRuntimeText(l10n, profile.value)
                : l10n.overviewHeaderRuntime(dockerEngineText(l10n, route)),
            style: style,
          ),
          Text(dockerTransportText(l10n, state), style: style),
          if (route != null)
            DockerRootBadge(route: route, user: profile.value?.user),
          if (state?.lowSession ?? false)
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 4,
              children: [
                Icon(
                  Icons.low_priority,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                Flexible(child: Text(l10n.dockerLowSession, style: style)),
              ],
            ),
        ],
      );
    },
  );
}

/// The most of its surface's height the server header takes; past it, it
/// scrolls.
const double _headerMaxShare = 0.4;

/// [header] over [child], as both server surfaces stack them: the header
/// grows with large text instead of clipping (A11Y-09), and where it
/// would pass [_headerMaxShare] of the height, as on a landscape phone or
/// a narrow desktop window at 200 % text, it scrolls, so [child] keeps the
/// rest. [banner], when given, sits between them, outside the header's
/// scroll.
class HeaderedBody extends StatelessWidget {
  const HeaderedBody({
    super.key,
    required this.header,
    required this.headerPadding,
    this.banner,
    required this.child,
  });

  final Widget header;

  /// Around [header], inside its scroll view.
  final EdgeInsetsGeometry headerPadding;

  /// Such as the return banner (03 §9.5 item 6), which bounds its own
  /// height.
  final Widget? banner;

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: box.maxHeight * _headerMaxShare,
          ),
          // Not primary: the panel's scroll view answers a status bar tap.
          child: SingleChildScrollView(
            primary: false,
            padding: headerPadding,
            child: header,
          ),
        ),
        ?banner,
        Expanded(child: child),
      ],
    ),
  );
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
