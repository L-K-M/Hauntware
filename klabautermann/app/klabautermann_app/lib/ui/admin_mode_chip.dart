import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart'
    show AdminModePhase, AdminModeState;

import '../controllers/admin_controller.dart';
import '../l10n/app_localizations.dart';
import 'server_safety.dart';

/// Admin mode for every route (03 §8.2): the server header's chip and
/// notices read it here. Absent in tests that leave it out, where the
/// header shows neither.
class AdminScope extends InheritedNotifier<AdminController> {
  const AdminScope({
    super.key,
    required AdminController admin,
    required super.child,
  }) : super(notifier: admin);

  static AdminController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AdminScope>()?.notifier;
}

/// The server header's admin mode chip (SAF-02): off, turning on, or on
/// until its inactivity expiry, tinted while it is on. Tapping it asks
/// the engine to turn admin mode on, or off again (which also cancels a
/// start). Only a server whose actions are allowed shows it, and while
/// actions are hidden it is disabled (SAF-06).
class AdminModeChip extends StatelessWidget {
  const AdminModeChip({super.key, required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context) {
    final safety = SafetyScope.maybeOf(context);
    final admin = AdminScope.maybeOf(context);
    if (safety == null || admin == null) return const SizedBox.shrink();
    if (!serverSafetyIn(safety.value, serverId).management) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (serverReadOnlyIn(safety.value, serverId)) {
      return Tooltip(
        message: l10n.adminChipReadOnly,
        child: FilterChip(
          avatar: const Icon(Icons.admin_panel_settings_outlined),
          label: Text(l10n.adminChipOff),
          selected: false,
          onSelected: null,
        ),
      );
    }

    final state = admin.stateFor(serverId);
    final active = admin.isActive(serverId);
    final label = switch (state) {
      AdminModeState(phase: AdminModePhase.on, :final expiresAt?) =>
        l10n.adminChipOn(
          MaterialLocalizations.of(
            context,
          ).formatTimeOfDay(TimeOfDay.fromDateTime(expiresAt.toLocal())),
        ),
      _ when active => l10n.adminChipStarting,
      _ => l10n.adminChipOff,
    };
    return FilterChip(
      avatar: Icon(
        active
            ? Icons.admin_panel_settings
            : Icons.admin_panel_settings_outlined,
      ),
      label: Text(label),
      selected: active,
      showCheckmark: false,
      // The tint says root at a glance, as the elevated chrome of 8.2.
      selectedColor: scheme.errorContainer,
      onSelected: (on) => admin.setEnabled(serverId, enabled: on),
    );
  }
}

/// The server header's notices about [serverId]'s admin mode: that it is
/// on, why it could not start, or why it ended (D35: the engine sends the
/// reason, the app words it). None without both scopes.
List<String> adminNotices(BuildContext context, String serverId) {
  final admin = AdminScope.maybeOf(context);
  if (admin == null || SafetyScope.maybeOf(context) == null) return const [];
  final l10n = AppLocalizations.of(context);
  return switch (admin.stateFor(serverId)) {
    AdminModeState(phase: AdminModePhase.on) => [l10n.adminOnNotice],
    AdminModeState(phase: AdminModePhase.failed, :final failure?) => [
      l10n.adminFailure(failure.name),
    ],
    AdminModeState(phase: AdminModePhase.expired, :final ended?) => [
      l10n.adminEnded(ended.name),
    ],
    _ => const [],
  };
}

/// Whether [TurnOnAdminModeButton] shows for [serverId], so a caller can
/// leave out the space around it too.
bool adminModeOffered(BuildContext context, String serverId) {
  final safety = SafetyScope.maybeOf(context);
  final admin = AdminScope.maybeOf(context);
  if (safety == null || admin == null) return false;
  final policy = safety.value;
  return serverSafetyIn(policy, serverId).management &&
      !serverReadOnlyIn(policy, serverId) &&
      !admin.isActive(serverId);
}

/// "Turn on admin mode" where something needs root (SAF-02): the Docker
/// gate, the Access tab's socket row and an unreadable stack file. It
/// asks the engine as the header's chip does, and shows only where the
/// chip would offer that: actions allowed on [serverId], neither it nor
/// the app read-only, and admin mode not on or starting.
class TurnOnAdminModeButton extends StatelessWidget {
  const TurnOnAdminModeButton({super.key, required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context) {
    if (!adminModeOffered(context, serverId)) return const SizedBox.shrink();

    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: OutlinedButton.icon(
        onPressed: () =>
            AdminScope.maybeOf(context)!.setEnabled(serverId, enabled: true),
        icon: const Icon(Icons.admin_panel_settings_outlined),
        label: Text(AppLocalizations.of(context).adminTurnOn),
      ),
    );
  }
}
