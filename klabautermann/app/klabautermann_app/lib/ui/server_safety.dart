import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/safety_controller.dart';
import '../l10n/app_localizations.dart';
import 'actions/action_entry.dart' show OperationsScope;
import 'actions/activity_page.dart';
import 'settings_page.dart' show changeSafetyWithFeedback;

/// The safety preferences for every route (M4 plan M4): the server
/// header's Safety menu and notices read them here, as the Overview reads
/// the announcement switch from `AnnouncementScope`. Absent in tests that
/// leave safety out, where the header shows neither.
class SafetyScope extends InheritedNotifier<SafetySettings> {
  const SafetyScope({
    super.key,
    required SafetySettings safety,
    required super.child,
  }) : super(notifier: safety);

  static SafetySettings? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SafetyScope>()?.notifier;
}

/// [serverId]'s preferences in [policy], or the defaults (management off).
ServerSafety serverSafetyIn(SafetyPolicy policy, String serverId) =>
    policy.servers[serverId] ?? const ServerSafety();

/// Whether actions on [serverId] are hidden: the server or every server
/// is read-only (SAF-06).
bool serverReadOnlyIn(SafetyPolicy policy, String serverId) =>
    policy.globalReadOnly || serverSafetyIn(policy, serverId).readOnly;

/// The server header's notices about [serverId]'s safety: observe-only
/// while management is off, 03 §4.3's step 5 (SAF-01), and read-only
/// while actions are hidden (SAF-06). None without a [SafetyScope].
List<String> serverSafetyNotices(BuildContext context, String serverId) {
  final safety = SafetyScope.maybeOf(context);
  if (safety == null) return const [];
  final l10n = AppLocalizations.of(context);
  final policy = safety.value;
  return [
    if (!serverSafetyIn(policy, serverId).management) l10n.serverObserveOnly,
    if (serverReadOnlyIn(policy, serverId)) l10n.serverReadOnlyNotice,
  ];
}

/// The server header's Safety menu: the per-server Allow actions switch
/// (management, SAF-01) and Read-only switch (SAF-06). Nothing without a
/// [SafetyScope].
class ServerSafetyMenu extends StatelessWidget {
  const ServerSafetyMenu({super.key, required this.serverId, this.serverName});

  final String serverId;

  /// The name the Activity page's title shows; the id without it.
  final String? serverName;

  @override
  Widget build(BuildContext context) {
    final safety = SafetyScope.maybeOf(context);
    if (safety == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final current = serverSafetyIn(safety.value, serverId);

    void set({bool? management, bool? readOnly}) => unawaited(
      changeSafetyWithFeedback(
        context,
        () => safety.setServerSafety(
          serverId,
          ServerSafety(
            management: management ?? current.management,
            readOnly: readOnly ?? current.readOnly,
            marks: current.marks,
          ),
        ),
      ),
    );

    return MenuAnchor(
      menuChildren: [
        CheckboxMenuButton(
          value: current.management,
          onChanged: (on) => set(management: on ?? false),
          child: Text(l10n.serverAllowActions),
        ),
        CheckboxMenuButton(
          value: current.readOnly,
          onChanged: (on) => set(readOnly: on ?? false),
          child: Text(l10n.serverReadOnly),
        ),
        if (OperationsScope.maybeOf(context) case final operations?)
          MenuItemButton(
            leadingIcon: const Icon(Icons.history),
            onPressed: () => unawaited(
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ActivityPage(
                    operations: operations,
                    serverId: serverId,
                    serverName: serverName ?? serverId,
                  ),
                ),
              ),
            ),
            child: Text(l10n.activityMenu),
          ),
      ],
      builder: (context, controller, _) => IconButton(
        icon: const Icon(Icons.shield_outlined),
        tooltip: l10n.serverSafetyMenu,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}
