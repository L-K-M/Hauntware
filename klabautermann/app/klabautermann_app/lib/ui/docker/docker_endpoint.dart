import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../l10n/app_localizations.dart';
import '../access/access_panel.dart' show engineModeText;

/// The server header's transport label (03 §5.9, E4) for [state]: the
/// route's rank once one is found, otherwise where the search stands or
/// why it found none. Null, before the engine reported anything this
/// run, reads as waiting: the app asks for the endpoint as each link
/// comes up (`DockerController`).
String dockerTransportText(AppLocalizations l10n, DockerEndpointState? state) {
  final phase = state?.phase ?? DockerEndpointPhase.waiting;
  return switch (phase) {
    DockerEndpointPhase.waiting => l10n.dockerTransportWaiting,
    DockerEndpointPhase.resolving => l10n.dockerTransportResolving,
    DockerEndpointPhase.ready => switch (state!.label) {
      DockerRouteLabel.socketForward => l10n.dockerTransportSocketForward,
      DockerRouteLabel.cliRelay => l10n.dockerTransportCliRelay,
      DockerRouteLabel.sudoRelay => l10n.dockerTransportSudoRelay,
      DockerRouteLabel.socatRelay => l10n.dockerTransportSocatRelay,
      // A ready endpoint always names its route.
      DockerRouteLabel.none => l10n.dockerTransportUnreachable,
    },
    DockerEndpointPhase.failed => switch (state!.failure) {
      DockerEndpointFailure.noRoute || null => switch (state.noRouteReason ??
          DockerNoRouteReason.noSocket) {
        DockerNoRouteReason.noRelay => l10n.dockerTransportNoRelay,
        DockerNoRouteReason.needsAdminMode =>
          l10n.dockerTransportNeedsAdminMode,
        DockerNoRouteReason.socketDenied => l10n.dockerTransportSocketDenied,
        DockerNoRouteReason.probeFailed => l10n.dockerTransportProbeFailed,
        DockerNoRouteReason.noSocket => l10n.dockerTransportNoSocket,
        DockerNoRouteReason.socketsUnknown =>
          l10n.dockerTransportSocketsUnknown,
      },
      DockerEndpointFailure.unreachable => l10n.dockerTransportUnreachable,
      DockerEndpointFailure.belowClientFloor ||
      DockerEndpointFailure.belowServerMinimum ||
      DockerEndpointFailure.apiVersionUnknown =>
        l10n.dockerTransportUnsupported,
      DockerEndpointFailure.linkError => l10n.dockerTransportLinkError,
      DockerEndpointFailure.invalidChoice => l10n.dockerTransportInvalidChoice,
      DockerEndpointFailure.invalidProgram =>
        l10n.dockerTransportInvalidProgram,
    },
  };
}

/// Why the Docker tab cannot show its panels on a failed endpoint, in a
/// sentence (03 §5.9's "the exact reason").
String dockerFailureText(
  AppLocalizations l10n,
  DockerEndpointState state,
) => switch (state.failure) {
  DockerEndpointFailure.noRoute || null => switch (state.noRouteReason ??
      DockerNoRouteReason.noSocket) {
    DockerNoRouteReason.noRelay => l10n.dockerGateNoRelay,
    DockerNoRouteReason.needsAdminMode => l10n.dockerGateNeedsAdminMode,
    DockerNoRouteReason.socketDenied => l10n.dockerGateSocketDenied,
    DockerNoRouteReason.probeFailed => l10n.dockerGateProbeFailed,
    DockerNoRouteReason.noSocket => l10n.dockerGateNoSocket,
    DockerNoRouteReason.socketsUnknown => l10n.dockerGateSocketsUnknown,
  },
  DockerEndpointFailure.unreachable => l10n.dockerGateUnreachable,
  DockerEndpointFailure.belowClientFloor => l10n.dockerGateBelowClientFloor,
  DockerEndpointFailure.belowServerMinimum => l10n.dockerGateBelowServerMinimum,
  DockerEndpointFailure.apiVersionUnknown => l10n.dockerGateApiVersionUnknown,
  DockerEndpointFailure.linkError => l10n.dockerGateLinkError,
  DockerEndpointFailure.invalidChoice => l10n.dockerGateInvalidChoice,
  DockerEndpointFailure.invalidProgram => l10n.dockerGateInvalidProgram,
};

/// The engine [route] reaches in words, as the Docker API names it
/// (M13): "Docker, rootful", or the runtime alone on a custom path whose
/// mode the path does not tell.
String dockerEngineText(AppLocalizations l10n, DockerEndpointRoute route) =>
    switch (route.mode) {
      final mode? => engineModeText(l10n, route.runtime, mode),
      null => switch (route.runtime) {
        EngineRuntime.docker => l10n.dockerRuntimeDocker,
        EngineRuntime.podman => l10n.dockerRuntimePodman,
      },
    };

/// SAF-08's badge for the engine [route] reaches (03 §8.4): a rootful
/// engine's socket, or a socket the probe cannot classify, equals root;
/// a rootless engine equals [user], the login the probe reported, when
/// it did.
class DockerRootBadge extends StatelessWidget {
  const DockerRootBadge({super.key, required this.route, this.user});

  final DockerEndpointRoute route;
  final String? user;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rootEquivalent =
        route.rootEquivalence != DockerRootEquivalence.rootlessEngine;
    final text = switch (route.rootEquivalence) {
      DockerRootEquivalence.rootfulSocket => l10n.dockerBadgeRootfulSocket,
      DockerRootEquivalence.unclassified => l10n.dockerBadgeCustomSocket,
      DockerRootEquivalence.sudoRelay => l10n.dockerBadgeSudoRelay,
      DockerRootEquivalence.rootlessEngine => switch (user) {
        final user? => l10n.dockerBadgeRootlessEngine(user),
        null => l10n.dockerBadgeRootlessEngineLogin,
      },
    };
    final foreground = rootEquivalent
        ? scheme.onErrorContainer
        : scheme.onSecondaryContainer;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: rootEquivalent
            ? scheme.errorContainer
            : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            ExcludeSemantics(
              child: Icon(
                rootEquivalent
                    ? Icons.warning_amber_outlined
                    : Icons.person_outline,
                size: 14,
                color: foreground,
              ),
            ),
            Flexible(
              child: Text(
                text,
                style: theme.textTheme.labelMedium?.copyWith(color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
