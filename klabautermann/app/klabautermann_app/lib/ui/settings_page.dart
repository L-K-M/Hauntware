import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart'
    show MonitorEligibility, kMonitorSetLimit;

import '../controllers/announcement_controller.dart';
import '../controllers/appearance_controller.dart';
import '../controllers/monitor_set.dart';
import '../l10n/app_localizations.dart';
import '../services/settings_window/settings_window_link.dart';
import 'about_dialog.dart';
import 'inspector_pane.dart' show PlaceholderPaneBody;
import 'appearance_tab.dart';
import 'monitor_set_feedback.dart';

/// Settings (03 §10.2): the seven planned tabs as placeholders, except
/// General, which holds A11Y-15's switch (D60) and the about row (M16),
/// Appearance, which already drives the app's appearance, and Servers,
/// which holds FL-21's monitor set (03 §4.3 step 4). A route on
/// phones (and wherever the desktop window cannot open); on desktop the
/// same page fills the settings window (`settings_window_app.dart`).
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.appearance,
    required this.announcements,
    required this.appVersion,
    required this.monitorSet,
    this.initialTab = SettingsTab.general,
    this.tabRequests,
  });

  final AppearanceSettings appearance;
  final AnnouncementSettings announcements;
  final MonitorSetSettings monitorSet;

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
    SettingsTab.docker => l10n.settingsTabDocker,
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
                appVersion: widget.appVersion,
              ),
              SettingsTab.appearance => AppearanceTab(
                appearance: widget.appearance,
              ),
              SettingsTab.servers => ServersTab(monitorSet: widget.monitorSet),
              _ => const PlaceholderPaneBody(),
            },
        ],
      ),
    );
  }
}

/// The General tab: A11Y-15's switch for threshold-band announcements
/// (D60), which the Overview's health card links to, and the about row
/// (M16): the app title with its preview label and the version, opening
/// the About dialog. Phones have no About command, so this row is their
/// way to the dialog.
class GeneralTab extends StatelessWidget {
  const GeneralTab({
    super.key,
    required this.announcements,
    required this.appVersion,
  });

  final AnnouncementSettings announcements;

  /// As [SettingsPage.appVersion].
  final String? appVersion;

  /// As [AppearanceTab._setMode]: the switch moves only once the app took
  /// the change, and a change it took but could not save says so.
  Future<void> _set(BuildContext context, bool announce) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final l10n = AppLocalizations.of(context);
    try {
      await announcements.setAnnounceThresholdBands(announce);
    } on AnnouncementNotSavedException catch (error) {
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.settingsAnnounceNotSaved);
      }
    } on Exception catch (error) {
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.settingsAnnounceNotChanged);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: announcements,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Semantics(
            header: true,
            child: Text(
              l10n.settingsAccessibilityTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: announcements.value,
            onChanged: (announce) => unawaited(_set(context, announce)),
            title: Text(l10n.settingsAnnounceBands),
            subtitle: Text(l10n.settingsAnnounceBandsDetail),
          ),
          const SizedBox(height: 24),
          Semantics(
            header: true,
            child: Text(
              l10n.settingsAboutTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          const SizedBox(height: 4),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.appTitle),
            subtitle: Text(appVersionLine(l10n, appVersion)),
            onTap: () => showAppAboutDialog(context, version: appVersion),
          ),
        ],
      ),
    );
  }
}

/// The Servers tab: FL-21's monitor set (03 §4.3 step 4), a switch per
/// fleet server in fleet order. A server that cannot join says why and
/// its switch is off and disabled; one more than the set holds says the
/// set is full when its switch is turned on.
class ServersTab extends StatelessWidget {
  const ServersTab({super.key, required this.monitorSet});

  final MonitorSetSettings monitorSet;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: monitorSet,
      builder: (context, _) {
        final candidates = monitorSet.value;
        final monitored = candidates.where((c) => c.monitored).length;
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
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
          ],
        );
      },
    );
  }
}
