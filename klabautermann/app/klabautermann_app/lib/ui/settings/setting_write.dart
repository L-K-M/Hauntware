import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;

import '../../l10n/app_localizations.dart';

/// What became of a setting change [writeSetting] ran.
enum SettingWrite {
  /// Applied and saved.
  saved,

  /// Applied for this run, but not saved: the controller threw its own
  /// not-saved exception.
  notSaved,

  /// Not applied: anything else it threw.
  notChanged,
}

/// Runs [change], a device setting's write, and says in a top toast when
/// it applied without being saved (an [E], [notSaved]'s words) or did not
/// apply (any other [Exception], [notChanged]'s words). The settings tabs
/// word every change this way. [report], when given, decides at the end
/// whether the toast still applies, as for a write a later one replaced.
/// The error goes to the debug log; it is a diagnostic, never shown.
Future<SettingWrite> writeSetting<E extends Exception>(
  BuildContext context,
  Future<void> Function() change, {
  required String Function(AppLocalizations l10n) notSaved,
  required String Function(AppLocalizations l10n) notChanged,
  bool Function()? report,
}) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  final l10n = AppLocalizations.of(context);
  final SettingWrite outcome;
  try {
    await change();
    return SettingWrite.saved;
  } on E catch (error) {
    debugPrint('$error');
    outcome = SettingWrite.notSaved;
  } on Exception catch (error) {
    debugPrint('$error');
    outcome = SettingWrite.notChanged;
  }

  if (report?.call() == false || !overlay.mounted) return outcome;
  showTopToast(
    overlay,
    message: outcome == SettingWrite.notSaved
        ? notSaved(l10n)
        : notChanged(l10n),
  );
  return outcome;
}
