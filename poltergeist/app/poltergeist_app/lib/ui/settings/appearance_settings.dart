// Poltergeist's Appearance editor moved to `ghost_theme`, shared with the
// rest of the Ghost app family (design docs/design/ghost-theme.md). This
// wrapper binds the shared [GhostAppearanceSection] to Poltergeist's style,
// model and ARB words, and lays it out as the column the Settings window's
// tab and the Settings dialog both scroll.
import 'package:flutter/material.dart';
import 'package:ghost_theme/ghost_theme.dart';

import '../../l10n/app_localizations.dart';
import '../../services/settings_models.dart';
import '../../theme/app_theme.dart';
import '../../theme/theme_presets.dart';
import '../server_appearance_strings.dart';

/// Settings → Appearance: this device's theme, after Vervellum's
/// `AppearanceView` by way of Séance and `ghost_theme`. Pick a preset,
/// then change anything.
///
/// The shared editor owns the controls and the writes; this wrapper
/// supplies Poltergeist's style, its [AppearanceSettingsModel] as the
/// model, and its ARB words. The palette is the editor's own copy, edited
/// here and handed to the model whole: in the Settings window,
/// [AppearanceSettingsModel.value] trails each write by a round trip to
/// the app.
class AppearanceSection extends StatelessWidget {
  const AppearanceSection({super.key, required this.model});

  final AppearanceSettingsModel model;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return GhostAppearanceSection(
      style: poltergeistThemeStyle,
      model: _AppearanceModel(model),
      strings: PoltergeistAppearanceStrings(l10n),
      page: (children) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
      header: (title, {helpTitle, help}) =>
          _Heading(title, helpTitle: helpTitle, help: help),
      hexStyle: poltergeistMonoTextStyle,
      colorPickerStrings: PoltergeistColorPickerStrings(l10n),
    );
  }
}

/// [AppearanceSettingsModel] as the shared editor's model. A failed write
/// throws through to the editor, which says so and keeps the change.
final class _AppearanceModel implements GhostAppearanceModel {
  const _AppearanceModel(this._model);

  final AppearanceSettingsModel _model;

  @override
  AppAppearance get value => _model.value;

  @override
  Future<void> setAppearance(ThemePalette palette, ThemeModePreference mode) =>
      _model.setAppearance(palette, mode);
}

/// The editor's words from Poltergeist's ARB. The terminal strings keep the
/// package's English: Poltergeist shows no terminal section, and so none of
/// them. Preset names are stored data, so the map keys are the presets' own
/// stored names rather than literals; anything else, such as Custom, is
/// passed through.
final class PoltergeistAppearanceStrings extends GhostAppearanceStrings {
  const PoltergeistAppearanceStrings(this._l10n);

  final AppLocalizations _l10n;

  static final Map<String, String Function(AppLocalizations)> _presetLabels = {
    poltergeistThemePresets.brand.name: (l10n) => l10n.themePresetPoltergeist,
    poltergeistThemePresets.graphite.name: (l10n) => l10n.themePresetGraphite,
    poltergeistThemePresets.paper.name: (l10n) => l10n.themePresetPaper,
    poltergeistThemePresets.newsprint.name: (l10n) => l10n.themePresetNewsprint,
    poltergeistThemePresets.solarized.name: (l10n) => l10n.themePresetSolarized,
    poltergeistThemePresets.midnight.name: (l10n) => l10n.themePresetMidnight,
    poltergeistThemePresets.terminal.name: (l10n) => l10n.themePresetTerminal,
    poltergeistThemePresets.vapor.name: (l10n) => l10n.themePresetVapor,
    poltergeistThemePresets.bubblegum.name: (l10n) => l10n.themePresetBubblegum,
    poltergeistThemePresets.highContrast.name: (l10n) =>
        l10n.themePresetHighContrast,
  };

  @override
  String presetLabel(String storedName) =>
      _presetLabels[storedName]?.call(_l10n) ?? storedName;

  @override
  String get themeTitle => _l10n.appearanceThemeSection;
  @override
  String get themeHelpTitle => _l10n.appearanceThemeHelpTitle;
  @override
  String get themeHelp => _l10n.appearanceThemeHelp;
  @override
  String get themeFootnote => _l10n.appearancePresetFootnote;
  @override
  String presetTooltip(String name) => _l10n.appearancePresetTooltip(name);

  @override
  String get modeTitle => _l10n.appearanceModeSection;
  @override
  String get modeLead => _l10n.appearanceModeLabel;
  @override
  String get modeSystem => _l10n.appearanceModeSystem;
  @override
  String get modeLight => _l10n.appearanceModeLight;
  @override
  String get modeDark => _l10n.appearanceModeDark;
  @override
  String ownSurfaceNote({required bool dark}) =>
      dark ? _l10n.appearanceModeFixedDark : _l10n.appearanceModeFixedLight;

  @override
  String get coloursTitle => _l10n.appearanceColoursSection;
  @override
  String get coloursHelpTitle => _l10n.appearanceColoursHelpTitle;
  @override
  String get coloursHelp => _l10n.appearanceColoursHelp;
  @override
  String get accent => _l10n.appearanceSlotAccent;
  @override
  String get accentAdjusted => _l10n.appearanceAccentAdjusted;
  @override
  String get chosenAccentPreview => _l10n.appearanceChosenAccentPreview;
  @override
  String get adjustedAccentPreview => _l10n.appearanceAdjustedAccentPreview;
  @override
  String get useAdjustedAccent => _l10n.appearanceUseAdjustedAccent;
  @override
  String slotLabel(ThemeSlot slot) => switch (slot) {
    ThemeSlot.surface => _l10n.appearanceSlotSurface,
    ThemeSlot.sidebar => _l10n.appearanceSlotSidebar,
    ThemeSlot.raised => _l10n.appearanceSlotRaised,
    ThemeSlot.text => _l10n.appearanceSlotText,
    ThemeSlot.secondaryText => _l10n.appearanceSlotSecondaryText,
    ThemeSlot.hairline => _l10n.appearanceSlotHairline,
    ThemeSlot.selection => _l10n.appearanceSlotSelection,
    ThemeSlot.online => _l10n.appearanceSlotOnline,
    ThemeSlot.offline => _l10n.appearanceSlotOffline,
    ThemeSlot.connecting => _l10n.appearanceSlotConnecting,
    ThemeSlot.unknown => _l10n.appearanceSlotUnknown,
  };

  @override
  String get statusTitle => _l10n.appearanceStatusSection;
  @override
  String get statusFootnote => _l10n.appearanceStatusFootnote;
  @override
  String get automatic => _l10n.appearanceAutomatic;
  @override
  String automaticSemantics(String label) =>
      _l10n.appearanceAutomaticSemantics(label);
  @override
  String chooseColour(String label) => _l10n.appearanceSwatchTooltip(label);
  @override
  String chooseAutomaticColour(String label) =>
      _l10n.appearanceSwatchAutomaticTooltip(label);

  @override
  String get shapeTitle => _l10n.appearanceShapeSection;
  @override
  String get interfaceFont => _l10n.appearanceFontLabel;
  @override
  String get interfaceFontHint => _l10n.appearanceFontHint;
  @override
  String get interfaceFontHelper => _l10n.appearanceFontHelper;
  @override
  String get corners => _l10n.appearanceCorners;
  @override
  String get cornersSquare => _l10n.appearanceCornersSquare;
  @override
  String cornersPercent(int percent) => _l10n.appearanceCornersPercent(percent);
  @override
  String cornersSemantics(String label) =>
      _l10n.appearanceCornersSemantics(label);

  @override
  String get shareTitle => _l10n.appearanceShareSection;
  @override
  String get copyTheme => _l10n.appearanceCopy;
  @override
  String get pasteTheme => _l10n.appearancePaste;
  @override
  String get shareFootnote => _l10n.appearanceShareFootnote;
  @override
  String get themeCopied => _l10n.appearanceCopied;
  @override
  String get pasteNotATheme => _l10n.appearancePasteNotATheme;

  @override
  String get startOverTitle => _l10n.appearanceStartOverSection;
  @override
  String resetButton(String name) => _l10n.appearanceReset(name);
  @override
  String get usingOwnColours => _l10n.appearanceUsingCustom;
  @override
  String usingPreset(String name) => _l10n.appearanceUsingPreset(name);
  @override
  String get resetTitle => _l10n.appearanceResetTitle;
  @override
  String resetBody(String name) => _l10n.appearanceResetBody(name);
  @override
  String get cancel => _l10n.appearanceResetCancel;
  @override
  String get reset => _l10n.appearanceResetConfirm;

  @override
  String notSaved(Object error) => _l10n.appearanceNotSaved(error.toString());
}

/// A part's heading, in the settings sections' title style, with a help
/// button when there is more to say than fits beside the controls.
class _Heading extends StatelessWidget {
  const _Heading(this.title, {this.helpTitle, this.help});

  final String title;
  final String? helpTitle;
  final String? help;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final help = this.help;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleSmall),
          ),
          if (help != null)
            IconButton(
              tooltip: l10n.appearanceHelpTooltip(title),
              icon: const Icon(Icons.help_outline, size: 18),
              visualDensity: VisualDensity.compact,
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(helpTitle ?? title),
                  content: SingleChildScrollView(child: Text(help)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(l10n.appearanceHelpClose),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
