import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/pinned_services.dart';
import '../l10n/app_localizations.dart';
import '../services/hand_off.dart';
import 'actions/action_entry.dart';
import 'actions/action_preview.dart';
import 'hand_off_actions.dart';
import 'system_panel.dart' show PanelSection;

/// The device's pinned services for the widgets under it; the
/// composition root puts it above every route, and a test may leave it
/// out, which pins nothing and offers no pin button.
class PinnedServicesScope extends InheritedNotifier<PinnedServicesController> {
  const PinnedServicesScope({
    super.key,
    required PinnedServicesController pins,
    required super.child,
  }) : super(notifier: pins);

  /// The pins for [context], which rebuilds when they change, or null
  /// when none are provided.
  static PinnedServicesController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<PinnedServicesScope>()
      ?.notifier;
}

/// The Poltergeist folder the quick actions' files button opens: the
/// root, since the link cannot name the login user's home.
const String _filesRoot = '/';

/// Whether [QuickActionsCard] for [serverId] has anything to offer: a
/// hand-off this device can make, reboot where actions are allowed, or a
/// pinned service to restart. The Overview leaves the card out otherwise.
bool quickActionsShown(BuildContext context, String serverId) {
  final launcher = HandOffScope.maybeOf(context);
  final handOff =
      launcher != null &&
      ((launcher.available(HandOffTarget.seance) &&
              seanceHandOff(serverId) != null) ||
          (launcher.available(HandOffTarget.poltergeist) &&
              poltergeistHandOff(serverId, path: _filesRoot) != null));
  final reboot = actionsAllowedAt(context, serverId, ActionEntryPoint.power);
  final pinned =
      (PinnedServicesScope.maybeOf(context)?.pinsFor(serverId).isNotEmpty ??
          false) &&
      actionsAllowedAt(context, serverId, ActionEntryPoint.unitVerb);
  return handOff || reboot || pinned;
}

/// OV-08's quick actions on a server's Overview: a terminal in Séance,
/// its files in Poltergeist, a restart of each service pinned from its
/// page in the Services tab, and a reboot. Each goes through the same
/// preview and confirmation as from its own tab (SAF-04); the hand-offs
/// show only where the sibling app takes them.
class QuickActionsCard extends StatelessWidget {
  const QuickActionsCard({super.key, required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pins =
        PinnedServicesScope.maybeOf(context)?.pinsFor(serverId) ??
        const <PinnedService>[];
    return PanelSection(
      title: l10n.quickActionsTitle,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OpenInSeanceButton(serverId: serverId),
            HandOffButton(
              target: HandOffTarget.poltergeist,
              link: poltergeistHandOff(serverId, path: _filesRoot),
              icon: Icons.folder_open_outlined,
              label: (l10n) => l10n.quickActionsFiles,
            ),
            if (pins.isNotEmpty)
              ActionEntry(
                serverId: serverId,
                point: ActionEntryPoint.unitVerb,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final pin in pins)
                      OutlinedButton.icon(
                        icon: const Icon(Icons.restart_alt),
                        label: Text(l10n.quickActionsRestart(pin.unit)),
                        onPressed: () => startAction(
                          context,
                          UnitAction(
                            serverId,
                            unit: pin.unit,
                            verb: SystemctlVerb.restart,
                            scope: pin.scope,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ActionEntry(
              serverId: serverId,
              point: ActionEntryPoint.power,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.power_settings_new),
                label: Text(l10n.quickActionsReboot),
                onPressed: () => startAction(
                  context,
                  PowerAction(serverId, PowerVerb.reboot),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A unit page's pin for [unit] on [serverId]'s quick actions (OV-08):
/// filled while pinned. Hidden without pins in scope; disabled while the
/// server already holds [kPinnedServicesMax] others.
class PinServiceButton extends StatelessWidget {
  const PinServiceButton({
    super.key,
    required this.serverId,
    required this.unit,
    required this.scope,
  });

  final String serverId;
  final String unit;
  final UnitScope scope;

  Future<void> _toggle(
    BuildContext context,
    PinnedServicesController pins,
    PinnedService service,
  ) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final l10n = AppLocalizations.of(context);
    try {
      await pins.toggle(serverId, service);
    } on PinnedServicesNotSavedException catch (error) {
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.quickActionsPinNotSaved);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pins = PinnedServicesScope.maybeOf(context);
    if (pins == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final service = PinnedService(unit, scope: scope);
    final pinned = pins.pinsFor(serverId).contains(service);
    return IconButton(
      tooltip: pinned
          ? l10n.quickActionsUnpin
          : pins.fullFor(serverId)
          ? l10n.quickActionsPinFull(kPinnedServicesMax)
          : l10n.quickActionsPin,
      isSelected: pinned,
      icon: const Icon(Icons.push_pin_outlined),
      selectedIcon: const Icon(Icons.push_pin),
      onPressed: pinned || !pins.fullFor(serverId)
          ? () => unawaited(_toggle(context, pins, service))
          : null,
    );
  }
}
