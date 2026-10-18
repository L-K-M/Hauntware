import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_theme/ghost_theme.dart' show ThemeModePreference;
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart'
    show
        MonitorEligibility,
        ServerSafety,
        kAdminExpiryChoices,
        kMonitorSetLimit;

import '../controllers/announcement_controller.dart';
import '../controllers/appearance_controller.dart';
import '../controllers/monitor_set.dart';
import '../controllers/safety_controller.dart';
import '../l10n/app_localizations.dart';
import '../services/settings_window/settings_window_link.dart';
import 'inspector_pane.dart' show PlaceholderPaneBody;
import 'monitor_set_feedback.dart';

/// Settings (03 §10.2): the seven planned tabs as placeholders, except
/// General, which holds A11Y-15's switch (D60), Appearance, which
/// already drives the app's appearance, Servers, which holds FL-21's
/// monitor set (03 §4.3 step 4), and Safety (M4 plan M4). A route on
/// phones (and wherever the desktop window cannot open); on desktop the
/// same page fills the settings window (`settings_window_app.dart`).
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.appearance,
    required this.announcements,
    required this.monitorSet,
    this.safety,
    this.initialTab = SettingsTab.general,
    this.tabRequests,
  });

  final AppearanceSettings appearance;
  final AnnouncementSettings announcements;
  final MonitorSetSettings monitorSet;

  /// Null in tests that leave safety out, where the tab is a placeholder.
  final SafetySettings? safety;

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
              ),
              SettingsTab.appearance => AppearanceTab(
                appearance: widget.appearance,
              ),
              SettingsTab.servers => ServersTab(monitorSet: widget.monitorSet),
              SettingsTab.safety when widget.safety != null => SafetyTab(
                safety: widget.safety!,
              ),
              _ => const PlaceholderPaneBody(),
            },
        ],
      ),
    );
  }
}

/// The General tab: A11Y-15's switch for threshold-band announcements
/// (D60), which the Overview's health card links to.
class GeneralTab extends StatelessWidget {
  const GeneralTab({super.key, required this.announcements});

  final AnnouncementSettings announcements;

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

/// The Safety tab (M4 plan M4): global read-only (SAF-06), admin mode's
/// inactivity expiry (SAF-02) and the targets the user marked protected
/// (SAF-22), each mark with a button that removes it. Per-server
/// management and read-only live in the server header's Safety menu.
class SafetyTab extends StatelessWidget {
  const SafetyTab({super.key, required this.safety});

  final SafetySettings safety;

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
                        ServerSafety(
                          management: server.management,
                          readOnly: server.readOnly,
                          marks: {...server.marks}..remove(mark),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
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
  final overlay = Overlay.of(context, rootOverlay: true);
  final l10n = AppLocalizations.of(context);
  try {
    await change();
  } on SafetyNotSavedException catch (error) {
    debugPrint('$error');
    if (overlay.mounted) {
      showTopToast(overlay, message: l10n.settingsSafetyNotSaved);
    }
  } on Exception catch (error) {
    debugPrint('$error');
    if (overlay.mounted) {
      showTopToast(overlay, message: l10n.settingsSafetyNotChanged);
    }
  }
}

/// The working part of settings at M1a: the theme-mode choice, so
/// light/dark switching is real from the first scaffold (03 §10.9).
class AppearanceTab extends StatelessWidget {
  const AppearanceTab({super.key, required this.appearance});

  final AppearanceSettings appearance;

  /// The selection shows [AppearanceSettings.value], so it moves only once
  /// the app has taken the change; a change the app does not take leaves
  /// it where it was and says so. A change the app took but could not save
  /// stays, and says that instead, since it then lasts only until the app
  /// restarts. Both in a top toast: the suite keeps the bottom edge clear.
  Future<void> _setMode(BuildContext context, ThemeModePreference mode) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final l10n = AppLocalizations.of(context);
    try {
      await appearance.setMode(mode);
    } on AppearanceNotSavedException catch (error) {
      debugPrint('$error');
      if (overlay.mounted) showTopToast(overlay, message: l10n.themeNotSaved);
    } on Exception catch (error) {
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.themeNotChanged);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: appearance,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              l10n.themeLabel,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            SegmentedButton<ThemeModePreference>(
              segments: [
                ButtonSegment(
                  value: ThemeModePreference.system,
                  label: Text(l10n.themeSystem),
                ),
                ButtonSegment(
                  value: ThemeModePreference.light,
                  label: Text(l10n.themeLight),
                ),
                ButtonSegment(
                  value: ThemeModePreference.dark,
                  label: Text(l10n.themeDark),
                ),
              ],
              selected: {appearance.value.mode},
              onSelectionChanged: (modes) =>
                  unawaited(_setMode(context, modes.first)),
            ),
          ],
        );
      },
    );
  }
}
