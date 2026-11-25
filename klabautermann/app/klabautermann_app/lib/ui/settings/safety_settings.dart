import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_keystore/app_lock.dart' show AppLockSettings;
import 'package:klabautermann_core/klabautermann_core.dart'
    show kAdminExpiryChoices;

import '../app_lock_settings.dart';
import '../../controllers/safety_controller.dart';
import '../../l10n/app_localizations.dart';
import 'setting_write.dart';

/// The Safety tab (M4 plan M4): global read-only (SAF-06), admin mode's
/// inactivity expiry (SAF-02) and the targets the user marked protected
/// (SAF-22), each mark with a button that removes it. Per-server
/// management and read-only live in the server header's Safety menu.
class SafetyTab extends StatelessWidget {
  const SafetyTab({super.key, required this.safety, this.appLock});

  final SafetySettings safety;

  /// Null where the app lock is left out.
  final AppLockSettings? appLock;

  /// As [AppearanceTab._setMode]: the control moves once the app took the
  /// change, and a change it took but could not save says so.
  Future<void> _change(BuildContext context, Future<void> Function() change) =>
      changeSafetyWithFeedback(context, change);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: safety,
      builder: (context, _) {
        final policy = safety.value;
        final marks = [
          for (final MapEntry(key: serverId, value: server)
              in policy.servers.entries)
            for (final mark in server.marks.toList()..sort())
              (serverId: serverId, server: server, mark: mark),
        ];
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: policy.globalReadOnly,
              onChanged: (readOnly) => unawaited(
                _change(context, () => safety.setGlobalReadOnly(readOnly)),
              ),
              title: Text(l10n.settingsSafetyReadOnly),
              subtitle: Text(l10n.settingsSafetyReadOnlyDetail),
            ),
            const SizedBox(height: 16),
            Semantics(
              header: true,
              child: Text(
                l10n.settingsSafetyAdminExpiry,
                style: textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<Duration>(
              segments: [
                for (final choice in kAdminExpiryChoices)
                  ButtonSegment(
                    value: choice,
                    label: Text(
                      l10n.settingsSafetyAdminExpiryMinutes(choice.inMinutes),
                    ),
                  ),
              ],
              selected: {policy.adminExpiry},
              onSelectionChanged: (choices) => unawaited(
                _change(context, () => safety.setAdminExpiry(choices.first)),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.settingsSafetyAdminExpiryDetail,
              style: textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            Semantics(
              header: true,
              child: Text(
                l10n.settingsSafetyMarksTitle,
                style: textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: 4),
            Text(l10n.settingsSafetyMarksDetail, style: textTheme.bodyMedium),
            const SizedBox(height: 8),
            if (marks.isEmpty)
              Text(l10n.settingsSafetyMarksEmpty, style: textTheme.labelLarge),
            for (final (:serverId, :server, :mark) in marks)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  l10n.settingsSafetyMark(mark, safety.labelOf(serverId)),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: l10n.settingsSafetyMarkRemove(mark),
                  onPressed: () => unawaited(
                    _change(
                      context,
                      () => safety.setServerSafety(
                        serverId,
                        server.copyWith(marks: {...server.marks}..remove(mark)),
                      ),
                    ),
                  ),
                ),
              ),
            if (appLock case final appLock?) ...[
              const SizedBox(height: 24),
              AppLockSection(lock: appLock),
            ],
          ],
        );
      },
    );
  }
}

/// Runs [change], a safety change, and says in a top toast when it did not
/// apply or applied without being saved: the Safety tab and the server
/// header's switches word it the same.
Future<void> changeSafetyWithFeedback(
  BuildContext context,
  Future<void> Function() change,
) async {
  await writeSetting<SafetyNotSavedException>(
    context,
    change,
    notSaved: (l10n) => l10n.settingsSafetyNotSaved,
    notChanged: (l10n) => l10n.settingsSafetyNotChanged,
  );
}
