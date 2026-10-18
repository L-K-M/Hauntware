import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart'
    show MonitorEligibility, kMonitorSetLimit;

import '../controllers/monitor_set.dart';
import '../l10n/app_localizations.dart';

/// Why a server cannot join FL-21's monitor set, in the catalog's words;
/// null for one that can.
String? monitorIneligibleText(
  AppLocalizations l10n,
  MonitorEligibility eligibility,
) => switch (eligibility) {
  MonitorEligibility.eligible => null,
  MonitorEligibility.endpointNotConfirmed => l10n.monitorIneligibleEndpoint,
  MonitorEligibility.interactiveCredentials =>
    l10n.monitorIneligibleCredentials,
  MonitorEligibility.credentialsUnknown => l10n.monitorIneligibleUnknown,
};

/// Runs a monitor set [change] from a row's menu or the Servers tab and
/// says in a top toast what went wrong: a full set, a change applied but
/// not saved (it lasts until the app quits), or one that did not apply.
/// The suite keeps the bottom edge clear, hence the top.
Future<void> changeMonitorSetWithFeedback(
  BuildContext context,
  Future<void> Function() change,
) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  final l10n = AppLocalizations.of(context);
  final String message;
  try {
    await change();
    return;
  } on MonitorSetFullException {
    message = l10n.monitorSetFull(kMonitorSetLimit);
  } on MonitorSetNotSavedException catch (error) {
    debugPrint('$error');
    message = l10n.monitorSetNotSaved;
  } on Exception catch (error) {
    debugPrint('$error');
    message = l10n.monitorSetNotChanged;
  }
  if (overlay.mounted) showTopToast(overlay, message: message);
}
