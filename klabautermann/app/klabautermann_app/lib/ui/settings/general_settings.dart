import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:ghost_update/ghost_update.dart';

import '../about_dialog.dart';
import '../../controllers/announcement_controller.dart';
import '../../controllers/cadence_controller.dart';
import '../../controllers/device_name.dart';
import '../../controllers/log_display.dart';
import '../../controllers/time_display.dart';
import '../../l10n/app_localizations.dart';
import 'setting_write.dart';

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
    this.timeDisplay,
    this.deviceName,
    this.updateChecks,
    required this.appVersion,
  });

  final AnnouncementSettings announcements;

  /// As [SettingsPage.cadence].
  final CadenceSettings? cadence;

  /// As [SettingsPage.logDisplay].
  final LogDisplaySettings? logDisplay;

  /// As [SettingsPage.timeDisplay].
  final TimeDisplaySettings? timeDisplay;

  /// As [SettingsPage.deviceName].
  final DeviceNameSettings? deviceName;

  /// As [SettingsPage.updateChecks].
  final UpdateCheckSettings? updateChecks;

  /// As [SettingsPage.appVersion].
  final String? appVersion;

  /// As [AppearanceTab._setMode]: the switch moves only once the app took
  /// the change, and a change it took but could not save says so.
  Future<void> _set(BuildContext context, bool announce) async {
    await writeSetting<AnnouncementNotSavedException>(
      context,
      () => announcements.setAnnounceThresholdBands(announce),
      notSaved: (l10n) => l10n.settingsAnnounceNotSaved,
      notChanged: (l10n) => l10n.settingsAnnounceNotChanged,
    );
  }

  /// As [_set], for the polling budget.
  Future<void> _setCadence(
    BuildContext context,
    CadenceSettings cadence,
    CadencePreset preset,
  ) async {
    await writeSetting<CadenceNotSavedException>(
      context,
      () => cadence.setCadence(preset),
      notSaved: (l10n) => l10n.settingsCadenceNotSaved,
      notChanged: (l10n) => l10n.settingsCadenceNotChanged,
    );
  }

  /// As [_set], for the log display.
  Future<void> _setLogDisplay(
    BuildContext context,
    LogDisplaySettings logDisplay,
    LogDisplay display,
  ) async {
    await writeSetting<LogDisplayNotSavedException>(
      context,
      () => logDisplay.setLogDisplay(display),
      notSaved: (l10n) => l10n.settingsLogDisplayNotSaved,
      notChanged: (l10n) => l10n.settingsLogDisplayNotChanged,
    );
  }

  /// As [_set], for the time display.
  Future<void> _setTimeDisplay(
    BuildContext context,
    TimeDisplaySettings timeDisplay,
    TimeDisplay display,
  ) async {
    await writeSetting<TimeDisplayNotSavedException>(
      context,
      () => timeDisplay.setTimeDisplay(display),
      notSaved: (l10n) => l10n.settingsServerTimesNotSaved,
      notChanged: (l10n) => l10n.settingsServerTimesNotChanged,
    );
  }

  /// As [_set], for the update check.
  Future<void> _setUpdateChecks(
    BuildContext context,
    UpdateCheckSettings updateChecks,
    bool enabled,
  ) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final l10n = AppLocalizations.of(context);
    try {
      await updateChecks.setEnabled(enabled);
    } on Exception catch (error) {
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.settingsUpdateCheckNotChanged);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cadence = this.cadence;
    final logDisplay = this.logDisplay;
    final timeDisplay = this.timeDisplay;
    final updateChecks = this.updateChecks;
    return ListenableBuilder(
      listenable: Listenable.merge([
        announcements,
        ?cadence,
        ?logDisplay,
        ?timeDisplay,
        ?updateChecks,
      ]),
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
          if (timeDisplay != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: timeDisplay.value == TimeDisplay.server,
              onChanged: (server) => unawaited(
                _setTimeDisplay(
                  context,
                  timeDisplay,
                  server ? TimeDisplay.server : TimeDisplay.device,
                ),
              ),
              title: Text(l10n.settingsServerTimes),
              subtitle: Text(l10n.settingsServerTimesDetail),
            ),
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
          if (updateChecks != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: updateChecks.enabled,
              onChanged: (enabled) =>
                  unawaited(_setUpdateChecks(context, updateChecks, enabled)),
              title: Text(l10n.updateCheckEnabledLabel),
              subtitle: Text(l10n.updateCheckEnabledSubtitle),
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
    await writeSetting<DeviceNameNotSavedException>(
      context,
      () => widget.deviceName.setDeviceName(_text.text),
      notSaved: (l10n) => l10n.settingsDeviceNameNotSaved,
      notChanged: (l10n) => l10n.settingsDeviceNameNotChanged,
    );
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
