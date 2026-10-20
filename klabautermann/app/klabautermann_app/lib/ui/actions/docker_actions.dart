import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show SidebarMenuAction, SidebarMenuEntry, SidebarMenuSubmenu;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../l10n/app_localizations.dart';
import '../docker/containers_view.dart' show EngineContainerState;
import '../docker/images_view.dart' show ImageEntry;
import 'action_entry.dart';
import 'action_preview.dart';

/// A container action the app offers (CTR-02, CTR-05, CTR-06), in the
/// order its menus and buttons show them.
enum ContainerOffer {
  start,
  stop,
  restart,
  pause,
  unpause,
  kill,
  remove,
  removeVolumes;

  bool get removes => this == remove || this == removeVolumes;
}

/// The actions a container in [state] offers. A container that is up
/// cannot be removed: the app never sends `force=1`, which would kill
/// it, so it is stopped first. A state the API does not list, and one
/// being removed, offer none.
List<ContainerOffer> containerOffers(String? state) =>
    switch (EngineContainerState.of(state)) {
      EngineContainerState.running => const [
        ContainerOffer.stop,
        ContainerOffer.restart,
        ContainerOffer.pause,
        ContainerOffer.kill,
      ],
      EngineContainerState.restarting => const [
        ContainerOffer.stop,
        ContainerOffer.kill,
      ],
      EngineContainerState.paused => const [
        ContainerOffer.unpause,
        ContainerOffer.kill,
      ],
      EngineContainerState.created ||
      EngineContainerState.exited ||
      EngineContainerState.dead => const [
        ContainerOffer.start,
        ContainerOffer.remove,
        ContainerOffer.removeVolumes,
      ],
      EngineContainerState.removing || null => const [],
    };

/// What [offer] asks the engine to plan for container [containerId].
ActionIntent containerIntent(
  String serverId,
  String containerId,
  ContainerOffer offer,
) => switch (offer) {
  ContainerOffer.start => _verb(serverId, containerId, ContainerVerb.start),
  ContainerOffer.stop => _verb(serverId, containerId, ContainerVerb.stop),
  ContainerOffer.restart => _verb(serverId, containerId, ContainerVerb.restart),
  ContainerOffer.pause => _verb(serverId, containerId, ContainerVerb.pause),
  ContainerOffer.unpause => _verb(serverId, containerId, ContainerVerb.unpause),
  ContainerOffer.kill => _verb(serverId, containerId, ContainerVerb.kill),
  ContainerOffer.remove => RemoveContainer(serverId, containerId: containerId),
  ContainerOffer.removeVolumes => RemoveContainer(
    serverId,
    containerId: containerId,
    volumes: true,
  ),
};

ContainerAction _verb(String serverId, String id, ContainerVerb verb) =>
    ContainerAction(serverId, containerId: id, verb: verb);

String _offerLabel(AppLocalizations l10n, ContainerOffer offer) =>
    switch (offer) {
      ContainerOffer.start => l10n.dockerContainerStart,
      ContainerOffer.stop => l10n.dockerContainerStop,
      ContainerOffer.restart => l10n.dockerContainerRestart,
      ContainerOffer.pause => l10n.dockerContainerPause,
      ContainerOffer.unpause => l10n.dockerContainerUnpause,
      ContainerOffer.kill => l10n.dockerContainerKill,
      ContainerOffer.remove => l10n.dockerContainerRemove,
      ContainerOffer.removeVolumes => l10n.dockerContainerRemoveVolumes,
    };

ActionEntryPoint _pointOf(ContainerOffer offer) => offer.removes
    ? ActionEntryPoint.containerRemove
    : ActionEntryPoint.containerVerb;

/// The signals besides the engine's default for Kill (`SIGKILL`), under
/// Send signal.
final _otherSignals = [
  for (final signal in KillSignal.values)
    if (signal != KillSignal.sigkill) signal,
];

/// [container]'s actions for the Containers table's row menu, where
/// actions on [serverId] are allowed: its state's offers, Kill followed
/// by Send signal with every other signal.
List<SidebarMenuEntry> containerActionEntries(
  BuildContext context, {
  required String serverId,
  required ContainerSummary container,
}) {
  final l10n = AppLocalizations.of(context);
  final entries = <SidebarMenuEntry>[];
  for (final offer in containerOffers(container.state)) {
    if (!actionsAllowedAt(context, serverId, _pointOf(offer))) continue;
    entries.add(
      SidebarMenuAction(
        label: _offerLabel(l10n, offer),
        onSelected: () => startAction(
          context,
          containerIntent(serverId, container.id, offer),
        ),
      ),
    );
    if (offer == ContainerOffer.kill) {
      entries.add(
        SidebarMenuSubmenu(
          label: l10n.processSendSignal,
          children: [
            for (final signal in _otherSignals)
              SidebarMenuAction(
                label: l10n.processSignalName(signal.wireName),
                onSelected: () =>
                    _signal(context, serverId, container.id, signal),
              ),
          ],
        ),
      );
    }
  }
  return entries;
}

void _signal(
  BuildContext context,
  String serverId,
  String containerId,
  KillSignal signal,
) => startAction(
  context,
  ContainerAction(
    serverId,
    containerId: containerId,
    verb: ContainerVerb.kill,
    signal: signal,
  ),
);

/// Whether [container]'s details show any action: one its state offers
/// at an entry point where actions on [serverId] are allowed.
bool containerActionsShown(
  BuildContext context,
  String serverId,
  ContainerSummary container,
) => containerOffers(
  container.state,
).any((offer) => actionsAllowedAt(context, serverId, _pointOf(offer)));

/// The same actions as buttons in a container's details, which phones
/// reach by tapping a row (48 dp targets, no destructive swipes).
class ContainerActionButtons extends StatelessWidget {
  const ContainerActionButtons({
    super.key,
    required this.serverId,
    required this.container,
  });

  final String serverId;
  final ContainerSummary container;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final offers = containerOffers(container.state);
    Widget button(ContainerOffer offer) => ActionEntry(
      serverId: serverId,
      point: _pointOf(offer),
      child: OutlinedButton(
        onPressed: () => startAction(
          context,
          containerIntent(serverId, container.id, offer),
        ),
        child: Text(_offerLabel(l10n, offer)),
      ),
    );
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final offer in offers) button(offer),
        if (offers.contains(ContainerOffer.kill))
          ActionEntry(
            serverId: serverId,
            point: ActionEntryPoint.containerVerb,
            child: MenuAnchor(
              menuChildren: [
                for (final signal in _otherSignals)
                  MenuItemButton(
                    onPressed: () =>
                        _signal(context, serverId, container.id, signal),
                    child: Text(l10n.processSignalName(signal.wireName)),
                  ),
              ],
              builder: (context, controller, _) => OutlinedButton.icon(
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
                icon: const Icon(Icons.arrow_drop_down),
                label: Text(l10n.processSendSignal),
              ),
            ),
          ),
      ],
    );
  }
}

/// What removing [entry] asks the engine to plan (IMG-02): a plain
/// removal, or a forced one, behind the typed confirmation, for an image
/// containers use. An image whose use is unknown is planned plainly; the
/// engine counts its users and refuses it if any.
ActionIntent imageIntent(String serverId, ImageEntry entry) => RemoveImage(
  serverId,
  image: entry.image.id,
  force: (entry.containers ?? 0) > 0,
);

String _imageLabel(AppLocalizations l10n, ImageEntry entry) =>
    (entry.containers ?? 0) > 0
    ? l10n.dockerImageForceRemove
    : l10n.dockerImageRemove;

/// [entry]'s action for the Images table's row menu, where actions on
/// [serverId] are allowed.
List<SidebarMenuEntry> imageActionEntries(
  BuildContext context, {
  required String serverId,
  required ImageEntry entry,
}) {
  if (!actionsAllowedAt(context, serverId, ActionEntryPoint.imageRemove)) {
    return const [];
  }
  return [
    SidebarMenuAction(
      label: _imageLabel(AppLocalizations.of(context), entry),
      onSelected: () => startAction(context, imageIntent(serverId, entry)),
    ),
  ];
}

/// The same action behind a button on the Images phone row, which has
/// no row menu.
class ImageActionsButton extends StatelessWidget {
  const ImageActionsButton({
    super.key,
    required this.serverId,
    required this.entry,
  });

  final String serverId;
  final ImageEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ActionEntry(
      serverId: serverId,
      point: ActionEntryPoint.imageRemove,
      child: MenuAnchor(
        menuChildren: [
          MenuItemButton(
            onPressed: () => startAction(context, imageIntent(serverId, entry)),
            child: Text(_imageLabel(l10n, entry)),
          ),
        ],
        builder: (context, controller, _) => IconButton(
          tooltip: l10n.dockerActions,
          icon: const Icon(Icons.more_vert),
          onPressed: () =>
              controller.isOpen ? controller.close() : controller.open(),
        ),
      ),
    );
  }
}

String _stackLabel(AppLocalizations l10n, StackVerb verb) => switch (verb) {
  StackVerb.start => l10n.dockerStackStart,
  StackVerb.stop => l10n.dockerStackStop,
  StackVerb.restart => l10n.dockerStackRestart,
};

/// A stack's start, stop and restart (STK-03) as buttons on its overview.
/// A stack another manager deploys plans with its manager named and the
/// typed confirmation (03 §8.7), which acts anyway.
class StackActionButtons extends StatelessWidget {
  const StackActionButtons({
    super.key,
    required this.serverId,
    required this.project,
  });

  final String serverId;
  final String project;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ActionEntry(
      serverId: serverId,
      point: ActionEntryPoint.stackVerb,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final verb in StackVerb.values)
            OutlinedButton(
              onPressed: () => startAction(
                context,
                StackAction(serverId, project: project, verb: verb),
              ),
              child: Text(_stackLabel(l10n, verb)),
            ),
        ],
      ),
    );
  }
}
