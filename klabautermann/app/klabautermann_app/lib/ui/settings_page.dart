import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:ghost_keystore/app_lock.dart' show AppLockSettings;
import 'package:ghost_update/ghost_update.dart';

import '../controllers/account_size.dart';
import '../controllers/admin_memory.dart';
import '../controllers/announcement_controller.dart';
import '../controllers/appearance_controller.dart';
import '../controllers/cadence_controller.dart';
import '../controllers/device_name.dart';
import '../controllers/editor_display.dart';
import '../controllers/log_display.dart';
import '../controllers/monitor_set.dart';
import '../controllers/pin_publication_controller.dart';
import '../controllers/recovery_controller.dart';
import '../controllers/safety_controller.dart';
import '../controllers/sync_controller.dart' show PinConflictsSettings;
import '../controllers/sync_secrets_controller.dart';
import '../controllers/sync_sign_out.dart' show SyncSignOutSettings;
import '../controllers/threshold_controller.dart';
import '../controllers/time_display.dart';
import '../l10n/app_localizations.dart';
import '../services/settings_window/settings_window_link.dart';
import 'appearance_tab.dart';
import 'inspector_pane.dart' show PlaceholderPaneBody;
import 'settings/general_settings.dart';
import 'settings/safety_settings.dart';
import 'settings/servers_settings.dart';
import 'settings/sync_settings.dart';
import 'thresholds_tab.dart';

export 'settings/general_settings.dart';
export 'settings/safety_settings.dart';
export 'settings/servers_settings.dart';
export 'settings/sync_settings.dart';

/// Settings (03 §10.2): the seven planned tabs as placeholders, except
/// General, which holds A11Y-15's switch (D60), the device name (M5 plan
/// Q6) and the about row (M16),
/// Appearance, which already drives the app's appearance, Servers, which
/// holds FL-21's monitor set (03 §4.3 step 4), Safety (M4 plan M4), and
/// Sync, which holds the "sync passwords" switch (SYN-02) and CRED-05's
/// Recovery section. A route on phones (and wherever the desktop window
/// cannot open); on desktop the same page fills the settings window
/// (`settings_window_app.dart`).
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.appearance,
    required this.announcements,
    required this.appVersion,
    required this.monitorSet,
    this.thresholds,
    this.cadence,
    this.cadenceCaps,
    this.adminMemory,
    this.logDisplay,
    this.editorDisplay,
    this.timeDisplay,
    this.deviceName,
    this.safety,
    this.appLock,
    this.syncSecrets,
    this.updateChecks,
    this.pinPublication,
    this.pinConflicts,
    this.accountSize,
    this.recovery,
    this.signOut,
    this.initialTab = SettingsTab.general,
    this.tabRequests,
  });

  final AppearanceSettings appearance;
  final AnnouncementSettings announcements;
  final MonitorSetSettings monitorSet;

  /// OV-11's usage bands in the Alerts tab; null in tests that leave them
  /// out, where the tab is a placeholder.
  final ThresholdSettings? thresholds;

  /// The polling budget (SAF-19) in General; null in tests that leave it
  /// out, where General shows none.
  final CadenceSettings? cadence;

  /// The per-server caps (SAF-19) in Servers; null in tests that leave
  /// them out, where Servers shows none.
  final CadenceCapSettings? cadenceCaps;

  /// FL-16's per-server admin memory in Servers; null in tests that leave
  /// it out, where Servers shows none.
  final AdminMemorySettings? adminMemory;

  /// The log text size and wrapping (A11Y-12) in General; null in tests
  /// that leave it out, where General shows neither.
  final LogDisplaySettings? logDisplay;

  /// The file editors' font and text size (03 §8.5) in Appearance; null in
  /// tests that leave it out, where the tab shows neither.
  final EditorDisplaySettings? editorDisplay;

  /// Which zone server times show in (A11Y-07), in General; null in tests
  /// that leave it out, where General does not offer it.
  final TimeDisplaySettings? timeDisplay;

  /// Null in tests that leave it out, where General shows no device name.
  final DeviceNameSettings? deviceName;

  /// Null in tests that leave safety out, where the tab is a placeholder.
  final SafetySettings? safety;

  /// The app lock (SAF-20) in the Safety tab; null in tests that leave it
  /// out, where the tab shows no app lock.
  final AppLockSettings? appLock;

  /// Null in tests that leave it out, where the Sync tab is a placeholder.
  final SyncSecretsSettings? syncSecrets;

  /// The launch update check's opt-out (c3 §shells, D19/D23) in General;
  /// null in tests that leave it out, where General shows no switch.
  final UpdateCheckSettings? updateChecks;

  /// The host key sharing assertion; null in tests that leave it out.
  final PinPublicationSettings? pinPublication;

  /// The host-key quarantine diff (03 §4.9) in the Sync tab; null in tests
  /// that leave it out, where the tab shows no conflict cards.
  final PinConflictsSettings? pinConflicts;

  /// The sync account's size (SYN-09) in the Sync tab; null in tests that
  /// leave it out, and its value null until a sync operation succeeded.
  final ValueListenable<AccountSize?>? accountSize;

  /// CRED-05's recovery code section in the Sync tab; null in tests that
  /// leave it out, where the tab shows no recovery.
  final RecoverySettings? recovery;

  /// The sync account and its sign-out (03 §4.3) in the Sync tab; null in
  /// tests that leave it out, where the tab shows no account.
  final SyncSignOutSettings? signOut;

  /// The running build's version for the about row; null when the
  /// platform could not tell (`readAppVersion`).
  final String? appVersion;

  /// The tab the page opens on, read once when it is first built: the
  /// settings window keys each page it shows by generation, so opening on
  /// another tab makes a new page rather than updating this one.
  final SettingsTab initialTab;

  /// Tabs the app asks the showing settings window to switch to; null on
  /// the route. Subscribed once, when the page's state is created, like
  /// [initialTab].
  final Stream<SettingsTab>? tabRequests;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: SettingsTab.values.length,
    vsync: this,
    initialIndex: widget.initialTab.index,
  );
  StreamSubscription<SettingsTab>? _tabRequests;

  @override
  void initState() {
    super.initState();
    _tabRequests = widget.tabRequests?.listen(
      (tab) => _tabs.animateTo(tab.index),
    );
  }

  @override
  void dispose() {
    unawaited(_tabRequests?.cancel());
    _tabs.dispose();
    super.dispose();
  }

  static String _label(AppLocalizations l10n, SettingsTab tab) => switch (tab) {
    SettingsTab.general => l10n.settingsTabGeneral,
    SettingsTab.appearance => l10n.settingsTabAppearance,
    SettingsTab.sync => l10n.settingsTabSync,
    SettingsTab.servers => l10n.settingsTabServers,
    SettingsTab.safety => l10n.settingsTabSafety,
    SettingsTab.alerts => l10n.settingsTabAlerts,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settingsTitle),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: [
            for (final tab in SettingsTab.values) Tab(text: _label(l10n, tab)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          for (final tab in SettingsTab.values)
            switch (tab) {
              SettingsTab.general => GeneralTab(
                announcements: widget.announcements,
                cadence: widget.cadence,
                logDisplay: widget.logDisplay,
                timeDisplay: widget.timeDisplay,
                deviceName: widget.deviceName,
                updateChecks: widget.updateChecks,
                appVersion: widget.appVersion,
              ),
              SettingsTab.appearance => AppearanceTab(
                appearance: widget.appearance,
                editorDisplay: widget.editorDisplay,
              ),
              SettingsTab.servers => ServersTab(
                monitorSet: widget.monitorSet,
                cadenceCaps: widget.cadenceCaps,
                adminMemory: widget.adminMemory,
              ),
              SettingsTab.sync when widget.syncSecrets != null => SyncTab(
                syncSecrets: widget.syncSecrets!,
                pinPublication: widget.pinPublication,
                pinConflicts: widget.pinConflicts,
                accountSize: widget.accountSize,
                recovery: widget.recovery,
                signOut: widget.signOut,
              ),
              SettingsTab.safety when widget.safety != null => SafetyTab(
                safety: widget.safety!,
                appLock: widget.appLock,
              ),
              SettingsTab.alerts when widget.thresholds != null =>
                ThresholdsTab(thresholds: widget.thresholds!),
              _ => const PlaceholderPaneBody(),
            },
        ],
      ),
    );
  }
}
