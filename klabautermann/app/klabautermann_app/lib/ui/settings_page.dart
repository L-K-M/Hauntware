import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show ghostFormatBinarySize, showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart'
    show MonitorEligibility, kAdminExpiryChoices, kMonitorSetLimit;

import '../controllers/account_size.dart';
import '../controllers/announcement_controller.dart';
import '../controllers/cadence_controller.dart';
import '../controllers/app_lock_controller.dart';
import '../controllers/appearance_controller.dart';
import '../controllers/device_name.dart';
import '../controllers/log_display.dart';
import '../controllers/monitor_set.dart';
import '../controllers/pin_publication_controller.dart';
import '../controllers/safety_controller.dart';
import '../controllers/sync_secrets_controller.dart';
import '../controllers/threshold_controller.dart';
import '../l10n/app_localizations.dart';
import '../services/settings_window/settings_window_link.dart';
import 'about_dialog.dart';
import 'app_lock_settings.dart';
import 'inspector_pane.dart' show PlaceholderPaneBody;
import 'appearance_tab.dart';
import 'monitor_set_feedback.dart';
import 'server_editing.dart';
import 'thresholds_tab.dart';

/// Settings (03 §10.2): the seven planned tabs as placeholders, except
/// General, which holds A11Y-15's switch (D60), the device name (M5 plan
/// Q6) and the about row (M16),
/// Appearance, which already drives the app's appearance, Servers, which
/// holds FL-21's monitor set (03 §4.3 step 4), Safety (M4 plan M4), and
/// Sync, which holds the "sync passwords" switch (SYN-02). A
/// route on phones (and wherever the desktop window cannot open); on
/// desktop the same page fills the settings window
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
    this.logDisplay,
    this.deviceName,
    this.safety,
    this.appLock,
    this.syncSecrets,
    this.pinPublication,
    this.accountSize,
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

  /// The log text size and wrapping (A11Y-12) in General; null in tests
  /// that leave it out, where General shows neither.
  final LogDisplaySettings? logDisplay;

  /// Null in tests that leave it out, where General shows no device name.
  final DeviceNameSettings? deviceName;

  /// Null in tests that leave safety out, where the tab is a placeholder.
  final SafetySettings? safety;

  /// The app lock (SAF-20) in the Safety tab; null in tests that leave it
  /// out, where the tab shows no app lock.
  final AppLockSettings? appLock;

  /// Null in tests that leave it out, where the Sync tab is a placeholder.
  final SyncSecretsSettings? syncSecrets;

  /// The host key sharing assertion; null in tests that leave it out.
  final PinPublicationSettings? pinPublication;

  /// The sync account's size (SYN-09) in the Sync tab; null in tests that
  /// leave it out, and its value null until a sync operation succeeded.
  final ValueListenable<AccountSize?>? accountSize;

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
                cadence: widget.cadence,
                logDisplay: widget.logDisplay,
                deviceName: widget.deviceName,
                appVersion: widget.appVersion,
              ),
              SettingsTab.appearance => AppearanceTab(
                appearance: widget.appearance,
              ),
              SettingsTab.servers => ServersTab(
                monitorSet: widget.monitorSet,
                cadenceCaps: widget.cadenceCaps,
              ),
              SettingsTab.sync when widget.syncSecrets != null => SyncTab(
                syncSecrets: widget.syncSecrets!,
                pinPublication: widget.pinPublication,
                accountSize: widget.accountSize,
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

/// The General tab: A11Y-15's switch for threshold-band announcements
/// (D60), which the Overview's health card links to, the device name the
/// host syslog line gives (SAF-13, M5 plan Q6), and the about row (M16):
/// the app title with its preview label and the version, opening the
/// About dialog. Phones have no About command, so this row is their way
/// to the dialog.
class GeneralTab extends StatelessWidget {
  const GeneralTab({
    super.key,
    required this.announcements,
    this.cadence,
    this.logDisplay,
    this.deviceName,
    required this.appVersion,
  });

  final AnnouncementSettings announcements;

  /// As [SettingsPage.cadence].
  final CadenceSettings? cadence;

  /// As [SettingsPage.logDisplay].
  final LogDisplaySettings? logDisplay;

  /// As [SettingsPage.deviceName].
  final DeviceNameSettings? deviceName;

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

  /// As [_set], for the polling budget.
  Future<void> _setCadence(
    BuildContext context,
    CadenceSettings cadence,
    CadencePreset preset,
  ) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final l10n = AppLocalizations.of(context);
    try {
      await cadence.setCadence(preset);
    } on CadenceNotSavedException catch (error) {
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.settingsCadenceNotSaved);
      }
    } on Exception catch (error) {
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.settingsCadenceNotChanged);
      }
    }
  }

  /// As [_set], for the log display.
  Future<void> _setLogDisplay(
    BuildContext context,
    LogDisplaySettings logDisplay,
    LogDisplay display,
  ) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final l10n = AppLocalizations.of(context);
    try {
      await logDisplay.setLogDisplay(display);
    } on LogDisplayNotSavedException catch (error) {
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.settingsLogDisplayNotSaved);
      }
    } on Exception catch (error) {
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.settingsLogDisplayNotChanged);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cadence = this.cadence;
    final logDisplay = this.logDisplay;
    return ListenableBuilder(
      listenable: Listenable.merge([announcements, ?cadence, ?logDisplay]),
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
          if (logDisplay != null) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.settingsLogTextSize),
              subtitle: Text(l10n.settingsLogTextSizeDetail),
              trailing: DropdownButton<int>(
                value: logDisplay.value.textSize,
                items: [
                  for (
                    var size = kLogTextSizeMin;
                    size <= kLogTextSizeMax;
                    size++
                  )
                    DropdownMenuItem(
                      value: size,
                      child: Text(l10n.settingsLogTextSizeValue(size)),
                    ),
                ],
                onChanged: (size) {
                  if (size == null) return;
                  unawaited(
                    _setLogDisplay(
                      context,
                      logDisplay,
                      logDisplay.value.copyWith(textSize: size),
                    ),
                  );
                },
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: logDisplay.value.wrap == LogWrap.on,
              onChanged: (wrap) => unawaited(
                _setLogDisplay(
                  context,
                  logDisplay,
                  logDisplay.value.copyWith(
                    wrap: wrap ? LogWrap.on : LogWrap.off,
                  ),
                ),
              ),
              title: Text(l10n.settingsLogWrap),
              subtitle: Text(l10n.settingsLogWrapDetail),
            ),
          ],
          if (cadence != null) ...[
            const SizedBox(height: 24),
            Semantics(
              header: true,
              child: Text(
                l10n.settingsCadenceTitle,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: 4),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.settingsCadenceLabel),
              subtitle: Text(l10n.settingsCadenceDetail(cadence.value.name)),
              trailing: DropdownButton<CadencePreset>(
                value: cadence.value,
                items: [
                  for (final preset in CadencePreset.values)
                    DropdownMenuItem(
                      value: preset,
                      child: Text(l10n.settingsCadencePreset(preset.name)),
                    ),
                ],
                onChanged: (preset) {
                  if (preset == null) return;
                  unawaited(_setCadence(context, cadence, preset));
                },
              ),
            ),
          ],
          if (deviceName case final deviceName?) ...[
            const SizedBox(height: 24),
            Semantics(
              header: true,
              child: Text(
                l10n.settingsDeviceTitle,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: 8),
            DeviceNameField(deviceName: deviceName),
          ],
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

/// The device name's field (M5 plan Q6): what it shows is the name in
/// force; it applies when submitted or left, and a blank name means the
/// default. A name taken but not saved, or not taken, says so in a top
/// toast, as the switches do.
class DeviceNameField extends StatefulWidget {
  const DeviceNameField({super.key, required this.deviceName});

  final DeviceNameSettings deviceName;

  @override
  State<DeviceNameField> createState() => _DeviceNameFieldState();
}

class _DeviceNameFieldState extends State<DeviceNameField> {
  late final _text = TextEditingController(text: widget.deviceName.value);
  final _focus = FocusNode();
  var _applying = false;

  @override
  void initState() {
    super.initState();
    widget.deviceName.addListener(_changed);
    _focus.addListener(() {
      if (!_focus.hasFocus) unawaited(_apply());
    });
  }

  @override
  void dispose() {
    widget.deviceName.removeListener(_changed);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  /// Shows a name set elsewhere, such as in the other settings surface,
  /// unless the user is typing here.
  void _changed() {
    if (_focus.hasFocus) return;
    _text.text = widget.deviceName.value;
  }

  /// Submitting leaves the field first, so a submit reaches this twice;
  /// leaving it unchanged sets nothing, which over the window's link
  /// would otherwise send a change that is none.
  Future<void> _apply() async {
    if (!mounted || _applying) return;
    if (_text.text.trim() == widget.deviceName.value &&
        widget.deviceName.saved) {
      _text.text = widget.deviceName.value;
      return;
    }
    _applying = true;
    try {
      await _set();
    } finally {
      _applying = false;
    }
  }

  Future<void> _set() async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final l10n = AppLocalizations.of(context);
    try {
      await widget.deviceName.setDeviceName(_text.text);
    } on DeviceNameNotSavedException catch (error) {
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.settingsDeviceNameNotSaved);
      }
    } on Exception catch (error) {
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.settingsDeviceNameNotChanged);
      }
    }
    // The name in force: trimmed, the default for a blank one, or the old
    // one when the change was not taken.
    if (mounted) _text.text = widget.deviceName.value;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return TextField(
      controller: _text,
      focusNode: _focus,
      maxLength: kDeviceNameMaxLength,
      decoration: InputDecoration(
        labelText: l10n.settingsDeviceName,
        helperText: l10n.settingsDeviceNameDetail,
        helperMaxLines: 3,
      ),
      onSubmitted: (_) => unawaited(_apply()),
    );
  }
}

/// The Sync tab: the device's "sync passwords" switch (03 §4.5, SYN-02),
/// in Séance's words. While on, sync rounds add the passwords and keys
/// other devices synced to this device's vault. Once a release is offered,
/// the host key sharing assertion too (D15, M5 plan M07).
/// SYN-09's account size view: what Klabautermann's records take of
/// their budget, with a warning near and at it, and every prefix's
/// records and bytes, the largest first.
class _AccountSizeSection extends StatelessWidget {
  const _AccountSizeSection({required this.size});

  final AccountSize size;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final warning = size.full
        ? l10n.settingsAccountSizeFull
        : size.warns
        ? l10n.settingsAccountSizeWarn
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            l10n.settingsAccountSizeTitle,
            style: theme.textTheme.titleSmall,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.settingsAccountSizeUsed(
            ghostFormatBinarySize(size.prefixBytes),
            ghostFormatBinarySize(size.budgetBytes),
          ),
        ),
        if (warning != null) ...[
          const SizedBox(height: 4),
          Text(
            warning,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          l10n.settingsAccountSizeDetail,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        for (final row in size.rows)
          MergeSemantics(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(row.prefix),
              // Under the prefix rather than beside it: a trailing figure
              // takes its full width and overflows a narrow window at
              // large text (A11Y-09).
              subtitle: Text(
                l10n.settingsAccountSizeRow(
                  row.records,
                  ghostFormatBinarySize(row.bytes),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class SyncTab extends StatelessWidget {
  const SyncTab({
    super.key,
    required this.syncSecrets,
    this.pinPublication,
    this.accountSize,
  });

  final SyncSecretsSettings syncSecrets;
  final PinPublicationSettings? pinPublication;

  /// As [SettingsPage.accountSize].
  final ValueListenable<AccountSize?>? accountSize;

  /// As [_set], for the host key sharing switch.
  Future<void> _assert(BuildContext context, bool asserted) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final l10n = AppLocalizations.of(context);
    try {
      await pinPublication!.setAsserted(asserted);
    } on Exception catch (error) {
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.settingsPinPublicationNotChanged);
      }
    }
  }

  /// As [GeneralTab._set].
  Future<void> _set(BuildContext context, bool enabled) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final l10n = AppLocalizations.of(context);
    try {
      await syncSecrets.setSyncSecrets(enabled);
    } on SyncSecretsNotSavedException catch (error) {
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.settingsSyncSecretsNotSaved);
      }
    } on Exception catch (error) {
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.settingsSyncSecretsNotChanged);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pins = pinPublication;
    return ListenableBuilder(
      listenable: Listenable.merge([syncSecrets, ?pins, ?accountSize]),
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Semantics(
            header: true,
            child: Text(
              l10n.settingsSyncSecretsTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: syncSecrets.value,
            onChanged: (enabled) => unawaited(_set(context, enabled)),
            title: Text(l10n.settingsSyncSecrets),
            subtitle: Text(l10n.settingsSyncSecretsDetail),
          ),
          if (pins?.value case PinPublication(
            :final release?,
            :final asserted,
          )) ...[
            const SizedBox(height: 24),
            Semantics(
              header: true,
              child: Text(
                l10n.settingsPinPublicationTitle,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: asserted,
              onChanged: (value) => unawaited(_assert(context, value)),
              title: Text(l10n.settingsPinPublication(release)),
              subtitle: Text(l10n.settingsPinPublicationDetail),
            ),
          ],
          if (accountSize?.value case final size?) ...[
            const SizedBox(height: 24),
            _AccountSizeSection(size: size),
          ],
        ],
      ),
    );
  }
}

/// The Servers tab: FL-21's monitor set (03 §4.3 step 4), a switch per
/// fleet server in fleet order. A server that cannot join says why and
/// its switch is off and disabled; one more than the set holds says the
/// set is full when its switch is turned on. Below it, each server's
/// polling cap (SAF-19) when [cadenceCaps] is given.
class ServersTab extends StatelessWidget {
  const ServersTab({super.key, required this.monitorSet, this.cadenceCaps});

  final MonitorSetSettings monitorSet;

  /// As [SettingsPage.cadenceCaps].
  final CadenceCapSettings? cadenceCaps;

  /// Caps [serverId] at [cap] and says in a toast when that applied but
  /// was not saved, or did not apply, as General's preset does.
  Future<void> _setCap(
    BuildContext context,
    CadenceCapSettings caps,
    String serverId,
    CadenceCap? cap,
  ) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final l10n = AppLocalizations.of(context);
    try {
      await caps.setCap(serverId, cap);
    } on CadenceNotSavedException catch (error) {
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.settingsCadenceCapNotSaved);
      }
    } on Exception catch (error) {
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.settingsCadenceCapNotChanged);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final caps = cadenceCaps;
    return ListenableBuilder(
      listenable: Listenable.merge([monitorSet, ?caps]),
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
