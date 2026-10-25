import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show SidebarMenuAction, SidebarMenuEntry, SidebarMenuSubmenu;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../l10n/app_localizations.dart';
import '../docker/containers_view.dart' show EngineContainerState;
import '../docker/images_view.dart' show ImageEntry;
import '../docker/networks_view.dart' show NetworkEntry;
import '../docker/volumes_view.dart' show VolumeEntry, validVolumeName;
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

/// What a service's menu offers (STK-23), in its order.
enum StackServiceOffer { start, stop, restart, pull, recreate, scale }

String _serviceOfferLabel(AppLocalizations l10n, StackServiceOffer offer) =>
    switch (offer) {
      StackServiceOffer.start => l10n.dockerStackStart,
      StackServiceOffer.stop => l10n.dockerStackStop,
      StackServiceOffer.restart => l10n.dockerStackRestart,
      StackServiceOffer.pull => l10n.dockerStackServicePull,
      StackServiceOffer.recreate => l10n.dockerStackServiceRecreate,
      StackServiceOffer.scale => l10n.dockerStackServiceScale,
    };

/// What [offer] on [service] of [project] asks the engine to plan;
/// [replicas] for [StackServiceOffer.scale].
ActionIntent stackServiceIntent(
  String serverId, {
  required String project,
  required String service,
  required StackServiceOffer offer,
  int? replicas,
}) => switch (offer) {
  StackServiceOffer.start => StackAction(
    serverId,
    project: project,
    verb: StackVerb.start,
    service: service,
  ),
  StackServiceOffer.stop => StackAction(
    serverId,
    project: project,
    verb: StackVerb.stop,
    service: service,
  ),
  StackServiceOffer.restart => StackAction(
    serverId,
    project: project,
    verb: StackVerb.restart,
    service: service,
  ),
  StackServiceOffer.pull => StackComposeAction(
    serverId,
    project: project,
    verb: StackComposeVerb.pullService,
    service: service,
  ),
  StackServiceOffer.recreate => StackComposeAction(
    serverId,
    project: project,
    verb: StackComposeVerb.recreateService,
    service: service,
  ),
  StackServiceOffer.scale => StackComposeAction(
    serverId,
    project: project,
    verb: StackComposeVerb.scaleService,
    service: service,
    replicas: replicas,
  ),
};

/// A service's actions (STK-23) as a menu on its card, where actions on
/// [serverId] are allowed. Scale asks for the replica count first. The
/// engine refuses what the stack's verdict or manager does not allow,
/// and the preview says why.
class StackServiceMenu extends StatelessWidget {
  const StackServiceMenu({
    super.key,
    required this.serverId,
    required this.project,
    required this.service,
    this.replicas,
  });

  final String serverId;
  final String project;
  final String service;

  /// The service's container count, which Scale starts from.
  final int? replicas;

  Future<void> _choose(BuildContext context, StackServiceOffer offer) async {
    int? count;
    if (offer == StackServiceOffer.scale) {
      count = await showDialog<int>(
        context: context,
        builder: (context) =>
            _ScaleDialog(service: service, initial: replicas ?? 1),
      );
      if (count == null || !context.mounted) return;
    }
    startAction(
      context,
      stackServiceIntent(
        serverId,
        project: project,
        service: service,
        offer: offer,
        replicas: count,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ActionEntry(
      serverId: serverId,
      point: ActionEntryPoint.stackService,
      child: PopupMenuButton<StackServiceOffer>(
        tooltip: l10n.dockerStackServiceActions(service),
        icon: const Icon(Icons.more_vert),
        onSelected: (offer) => unawaited(_choose(context, offer)),
        itemBuilder: (context) => [
          for (final offer in StackServiceOffer.values)
            PopupMenuItem(
              value: offer,
              child: Text(_serviceOfferLabel(l10n, offer)),
            ),
        ],
      ),
    );
  }
}

/// Asks how many containers [service] should run, 0 to
/// [kComposeMaxScale].
class _ScaleDialog extends StatefulWidget {
  const _ScaleDialog({required this.service, required this.initial});

  final String service;
  final int initial;

  @override
  State<_ScaleDialog> createState() => _ScaleDialogState();
}

class _ScaleDialogState extends State<_ScaleDialog> {
  late final _count = TextEditingController(text: widget.initial.toString());

  @override
  void dispose() {
    _count.dispose();
    super.dispose();
  }

  int? get _value {
    final value = int.tryParse(_count.text.trim());
    return value != null && value >= 0 && value <= kComposeMaxScale
        ? value
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final value = _value;
    void submit() {
      if (value != null) Navigator.pop(context, value);
    }

    return AlertDialog(
      title: Text(l10n.dockerStackScaleTitle(widget.service)),
      content: TextField(
        controller: _count,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: l10n.dockerStackScaleLabel,
          errorText: value == null
              ? l10n.dockerStackScaleRange(kComposeMaxScale)
              : null,
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.dockerStackScaleCancel),
        ),
        FilledButton(
          onPressed: value == null ? null : submit,
          child: Text(l10n.dockerStackServiceScale),
        ),
      ],
    );
  }
}

/// Takes a whole stack down (STK-23): its containers and networks, never
/// its volumes. The preview asks for the typed confirmation.
class StackDownButton extends StatelessWidget {
  const StackDownButton({
    super.key,
    required this.serverId,
    required this.project,
  });

  final String serverId;
  final String project;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final error = Theme.of(context).colorScheme.error;
    return ActionEntry(
      serverId: serverId,
      point: ActionEntryPoint.stackDown,
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: error),
          onPressed: () => startAction(
            context,
            StackComposeAction(
              serverId,
              project: project,
              verb: StackComposeVerb.down,
            ),
          ),
          icon: const Icon(Icons.arrow_downward),
          label: Text(l10n.dockerStackDown),
        ),
      ),
    );
  }
}

/// [entry]'s actions for the Volumes table's row menu, where actions on
/// [serverId] are allowed (VOL-02): Remove, which the engine refuses for
/// a volume a container mounts.
List<SidebarMenuEntry> volumeActionEntries(
  BuildContext context, {
  required String serverId,
  required VolumeEntry entry,
}) {
  if (!actionsAllowedAt(context, serverId, ActionEntryPoint.volumeRemove)) {
    return const [];
  }
  return [
    SidebarMenuAction(
      label: AppLocalizations.of(context).dockerVolumeRemove,
      onSelected: () =>
          startAction(context, RemoveVolume(serverId, name: entry.volume.name)),
    ),
  ];
}

/// The same action behind a button on the Volumes phone row, which has
/// no row menu.
class VolumeActionsButton extends StatelessWidget {
  const VolumeActionsButton({
    super.key,
    required this.serverId,
    required this.entry,
  });

  final String serverId;
  final VolumeEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ActionEntry(
      serverId: serverId,
      point: ActionEntryPoint.volumeRemove,
      child: MenuAnchor(
        menuChildren: [
          MenuItemButton(
            onPressed: () => startAction(
              context,
              RemoveVolume(serverId, name: entry.volume.name),
            ),
            child: Text(l10n.dockerVolumeRemove),
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

/// "Create volume…" over the Volumes list (VOL-02): asks for a name and
/// an optional driver, then plans the create.
class CreateVolumeButton extends StatelessWidget {
  const CreateVolumeButton({super.key, required this.serverId});

  final String serverId;

  Future<void> _create(BuildContext context) async {
    final request = await showDialog<({String name, String? driver})>(
      context: context,
      builder: (context) => const _CreateVolumeDialog(),
    );
    if (request == null || !context.mounted) return;
    startAction(
      context,
      CreateVolume(serverId, name: request.name, driver: request.driver),
    );
  }

  @override
  Widget build(BuildContext context) => ActionEntry(
    serverId: serverId,
    point: ActionEntryPoint.volumeCreate,
    child: OutlinedButton.icon(
      onPressed: () => unawaited(_create(context)),
      icon: const Icon(Icons.add),
      label: Text(AppLocalizations.of(context).dockerVolumeCreate),
    ),
  );
}

class _CreateVolumeDialog extends StatefulWidget {
  const _CreateVolumeDialog();

  @override
  State<_CreateVolumeDialog> createState() => _CreateVolumeDialogState();
}

class _CreateVolumeDialogState extends State<_CreateVolumeDialog> {
  final _name = TextEditingController();
  final _driver = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _driver.dispose();
    super.dispose();
  }

  /// Whether the user tried to submit, after which an empty name says
  /// it is required rather than staying quiet.
  bool _submitted = false;

  /// Why the typed name cannot be sent, or null. The driver is not
  /// checked: a plugin driver is a reference such as `vieux/sshfs`, which
  /// the daemon resolves, and an empty one asks for its default.
  String? _problem(AppLocalizations l10n, String text) {
    final value = text.trim();
    if (value.isEmpty) return l10n.dockerVolumeNameRequired;
    return validVolumeName(value) ? null : l10n.dockerVolumeNameInvalid;
  }

  void _submit() {
    final l10n = AppLocalizations.of(context);
    if (_problem(l10n, _name.text) != null) {
      setState(() => _submitted = true);
      return;
    }
    final driver = _driver.text.trim();
    Navigator.of(
      context,
    ).pop((name: _name.text.trim(), driver: driver.isEmpty ? null : driver));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final nameProblem = _name.text.isEmpty && !_submitted
        ? null
        : _problem(l10n, _name.text);
    return AlertDialog(
      title: Text(l10n.dockerVolumeCreateTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: l10n.dockerVolumesColumnName,
              errorText: nameProblem,
            ),
          ),
          TextField(
            controller: _driver,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: l10n.dockerVolumesColumnDriver,
              hintText: l10n.dockerVolumeDriverHint,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.actionConfirmCancel),
        ),
        FilledButton(
          onPressed: _name.text.trim().isEmpty ? null : _submit,
          child: Text(l10n.dockerVolumeCreateSubmit),
        ),
      ],
    );
  }
}

/// [entry]'s actions for the Networks table's row menu, where actions on
/// [serverId] are allowed (DNW-02): Remove for a user-defined network,
/// none for a built-in one, which stays.
List<SidebarMenuEntry> networkActionEntries(
  BuildContext context, {
  required String serverId,
  required NetworkEntry entry,
}) {
  if (entry.builtin ||
      !actionsAllowedAt(context, serverId, ActionEntryPoint.networkRemove)) {
    return const [];
  }
  return [
    SidebarMenuAction(
      label: AppLocalizations.of(context).dockerNetworkRemove,
      onSelected: () => startAction(
        context,
        RemoveNetwork(serverId, networkId: entry.network.id),
      ),
    ),
  ];
}

/// The same action behind a button on the Networks phone row, which has
/// no row menu; a built-in network shows none.
class NetworkActionsButton extends StatelessWidget {
  const NetworkActionsButton({
    super.key,
    required this.serverId,
    required this.entry,
  });

  final String serverId;
  final NetworkEntry entry;

  @override
  Widget build(BuildContext context) {
    if (entry.builtin) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    return ActionEntry(
      serverId: serverId,
      point: ActionEntryPoint.networkRemove,
      child: MenuAnchor(
        menuChildren: [
          MenuItemButton(
            onPressed: () => startAction(
              context,
              RemoveNetwork(serverId, networkId: entry.network.id),
            ),
            child: Text(l10n.dockerNetworkRemove),
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
