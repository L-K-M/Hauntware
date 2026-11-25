import 'dart:async';

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart'
    show MonitorEligibility, kMonitorSetLimit;

import '../../controllers/admin_memory.dart';
import '../../controllers/cadence_controller.dart';
import '../../controllers/monitor_set.dart';
import '../../l10n/app_localizations.dart';
import '../monitor_set_feedback.dart';
import '../server_editing.dart';
import 'setting_write.dart';

/// The Servers tab: FL-21's monitor set (03 §4.3 step 4), a switch per
/// fleet server in fleet order. A server that cannot join says why and
/// its switch is off and disabled; one more than the set holds says the
/// set is full when its switch is turned on. Below it, each server's
/// polling cap (SAF-19) when [cadenceCaps] is given, and its admin memory
/// switch (FL-16) when [adminMemory] is given.
class ServersTab extends StatelessWidget {
  const ServersTab({
    super.key,
    required this.monitorSet,
    this.cadenceCaps,
    this.adminMemory,
  });

  final MonitorSetSettings monitorSet;

  /// As [SettingsPage.cadenceCaps].
  final CadenceCapSettings? cadenceCaps;

  /// As [SettingsPage.adminMemory].
  final AdminMemorySettings? adminMemory;

  /// Turns [serverId]'s admin memory on or off and says in a toast when
  /// that applied but was not saved, or did not apply, as [_setCap] does.
  Future<void> _setRemembered(
    BuildContext context,
    AdminMemorySettings memory,
    String serverId, {
    required bool remembered,
  }) async {
    await writeSetting<AdminMemoryNotSavedException>(
      context,
      () => memory.setRemembered(serverId, remembered: remembered),
      notSaved: (l10n) => l10n.settingsAdminMemoryNotSaved,
      notChanged: (l10n) => l10n.settingsAdminMemoryNotChanged,
    );
  }

  /// Caps [serverId] at [cap] and says in a toast when that applied but
  /// was not saved, or did not apply, as General's preset does.
  Future<void> _setCap(
    BuildContext context,
    CadenceCapSettings caps,
    String serverId,
    CadenceCap? cap,
  ) async {
    await writeSetting<CadenceNotSavedException>(
      context,
      () => caps.setCap(serverId, cap),
      notSaved: (l10n) => l10n.settingsCadenceCapNotSaved,
      notChanged: (l10n) => l10n.settingsCadenceCapNotChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final caps = cadenceCaps;
    final memory = adminMemory;
    return ListenableBuilder(
      listenable: Listenable.merge([monitorSet, ?caps, ?memory]),
      builder: (context, _) {
        final candidates = monitorSet.value;
        final monitored = candidates.where((c) => c.monitored).length;
        final editing = ServerEditingScope.maybeOf(context);
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            // FL-03's entry point here, while an account is enrolled (P16).
            // The desktop settings window has no engine of its own, so it
            // offers none; the rail's add menu does.
            if (editing != null)
              ListenableBuilder(
                listenable: editing.sync,
                builder: (context, _) {
                  if (!editing.enabled) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Semantics(
                          header: true,
                          child: Text(
                            l10n.settingsServersAccountTitle,
                            style: textTheme.titleSmall,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n.settingsServersAccountDetail,
                          style: textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 12),
                        FilledButton.tonal(
                          onPressed: () =>
                              unawaited(openServerEditor(context, editing)),
                          child: Text(l10n.addServer),
                        ),
                      ],
                    ),
                  );
                },
              ),
            Semantics(
              header: true,
              child: Text(
                l10n.settingsMonitorTitle,
                style: textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.settingsMonitorDetail(kMonitorSetLimit),
              style: textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Text(
              candidates.isEmpty
                  ? l10n.settingsMonitorEmpty
                  : l10n.settingsMonitorCount(monitored, kMonitorSetLimit),
              style: textTheme.labelLarge,
            ),
            for (final candidate in candidates)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: candidate.monitored,
                onChanged: candidate.eligibility == MonitorEligibility.eligible
                    ? (monitor) => unawaited(
                        changeMonitorSetWithFeedback(
                          context,
                          () => monitorSet.setMonitored(
                            candidate.serverId,
                            monitored: monitor,
                          ),
                        ),
                      )
                    : null,
                title: Text(candidate.label),
                subtitle: switch (monitorIneligibleText(
                  l10n,
                  candidate.eligibility,
                )) {
                  final reason? => Text(reason),
                  null => null,
                },
              ),
            if (caps != null && candidates.isNotEmpty) ...[
              const SizedBox(height: 24),
              Semantics(
                header: true,
                child: Text(
                  l10n.settingsCadenceCapsTitle,
                  style: textTheme.titleSmall,
                ),
              ),
              const SizedBox(height: 4),
              Text(l10n.settingsCadenceCapsDetail, style: textTheme.bodyMedium),
              for (final candidate in candidates)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(candidate.label),
                  trailing: DropdownButton<CadenceCap?>(
                    value: caps.value[candidate.serverId],
                    items: [
                      DropdownMenuItem(child: Text(l10n.settingsCadenceNoCap)),
                      for (final cap in CadenceCap.values)
                        DropdownMenuItem(
                          value: cap,
                          child: Text(l10n.settingsCadencePreset(cap.name)),
                        ),
                    ],
                    onChanged: (cap) => unawaited(
                      _setCap(context, caps, candidate.serverId, cap),
                    ),
                  ),
                ),
            ],
            if (memory != null && candidates.isNotEmpty) ...[
              const SizedBox(height: 24),
              Semantics(
                header: true,
                child: Text(
                  l10n.settingsAdminMemoryTitle,
                  style: textTheme.titleSmall,
                ),
              ),
              const SizedBox(height: 4),
              Text(l10n.settingsAdminMemoryDetail, style: textTheme.bodyMedium),
              for (final candidate in candidates)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: memory.value.contains(candidate.serverId),
                  onChanged: (remembered) => unawaited(
                    _setRemembered(
                      context,
                      memory,
                      candidate.serverId,
                      remembered: remembered,
                    ),
                  ),
                  // The monitor set's switch above carries the same name,
                  // so a screen reader hears which switch this is.
                  title: Text(
                    candidate.label,
                    semanticsLabel: l10n.settingsAdminMemorySwitch(
                      candidate.label,
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}
