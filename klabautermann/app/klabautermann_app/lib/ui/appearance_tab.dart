import 'package:flutter/material.dart';
import 'package:ghost_theme/ghost_theme.dart';

import '../controllers/appearance_controller.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

/// The Appearance tab (M4 E25, X-01): ghost_theme's shared editor bound to
/// Klabautermann's style and words. Presets, the mode, every colour, the
/// font, the corners, copy and paste, and reset, written through
/// [AppearanceSettings] as the editor changes them: in the app straight to
/// its controller, in the desktop settings window over the link. There is
/// no terminal section; Klabautermann draws no terminal.
class AppearanceTab extends StatefulWidget {
  const AppearanceTab({super.key, required this.appearance});

  final AppearanceSettings appearance;

  @override
  State<AppearanceTab> createState() => _AppearanceTabState();
}

class _AppearanceTabState extends State<AppearanceTab> {
  /// Bumped when the app does not take a change, so the editor starts again
  /// from the app's appearance: its controls move only once the app took a
  /// change, as everywhere else in Settings. A change the app took but
  /// could not save stays.
  int _generation = 0;

  late final _model = _AppearanceModel(widget.appearance, _refused);

  void _refused() {
    if (mounted) setState(() => _generation++);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return GhostAppearanceSection(
      key: ValueKey(_generation),
      style: klabautermannThemeStyle,
      model: _model,
      strings: KlabautermannAppearanceStrings(l10n),
      page: (children) =>
          ListView(padding: const EdgeInsets.all(24), children: children),
      header: (title, {helpTitle, help}) =>
          _SectionHeader(title: title, helpTitle: helpTitle, help: help),
    );
  }
}

/// [AppearanceSettings] as the shared editor's model.
final class _AppearanceModel implements GhostAppearanceModel {
  _AppearanceModel(this._settings, this._refused);

  final AppearanceSettings _settings;
  final VoidCallback _refused;

  @override
  AppAppearance get value => _settings.value;

  @override
  Future<void> setAppearance(
    ThemePalette palette,
    ThemeModePreference mode,
  ) async {
    try {
      await _settings.setAppearance(palette, mode);
    } on AppearanceNotSavedException {
      rethrow;
    } on Object catch (error) {
      debugPrint(error.toString());
      _refused();
      rethrow;
    }
  }
}

/// The editor's words from Klabautermann's ARB (03 §10.10). The terminal
/// strings keep the package's English: Klabautermann shows no terminal
/// section, and so none of them.
final class KlabautermannAppearanceStrings extends GhostAppearanceStrings {
  const KlabautermannAppearanceStrings(this._l10n);

  final AppLocalizations _l10n;

  @override
  String get themeTitle => _l10n.appearanceThemeTitle;
  @override
  String get themeHelpTitle => _l10n.appearanceThemeHelpTitle;
  @override
  String get themeHelp => _l10n.appearanceThemeHelp;
  @override
  String get themeFootnote => _l10n.appearanceThemeFootnote;
  @override
  String presetTooltip(String name) => _l10n.appearancePresetTooltip(name);

  @override
  String get modeTitle => _l10n.appearanceModeTitle;
  @override
  String get modeLead => _l10n.appearanceModeLead;
  @override
  String get modeSystem => _l10n.themeSystem;
  @override
  String get modeLight => _l10n.themeLight;
  @override
  String get modeDark => _l10n.themeDark;
  @override
  String ownSurfaceNote({required bool dark}) =>
      dark ? _l10n.appearanceOwnSurfaceDark : _l10n.appearanceOwnSurfaceLight;

  @override
  String get coloursTitle => _l10n.appearanceColoursTitle;
  @override
  String get coloursHelpTitle => _l10n.appearanceColoursHelpTitle;
  @override
  String get coloursHelp => _l10n.appearanceColoursHelp;
  @override
  String get accent => _l10n.appearanceAccent;
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
  String get statusTitle => _l10n.appearanceStatusTitle;
  @override
  String get statusFootnote => _l10n.appearanceStatusFootnote;
  @override
  String get automatic => _l10n.appearanceAutomatic;
  @override
  String automaticSemantics(String label) =>
      _l10n.appearanceAutomaticSemantics(label);
  @override
  String chooseColour(String label) => _l10n.appearanceChooseColour(label);
  @override
  String chooseAutomaticColour(String label) =>
      _l10n.appearanceChooseAutomaticColour(label);

  @override
  String get shapeTitle => _l10n.appearanceShapeTitle;
  @override
  String get interfaceFont => _l10n.appearanceInterfaceFont;
  @override
  String get interfaceFontHint => _l10n.appearanceInterfaceFontHint;
  @override
  String get interfaceFontHelper => _l10n.appearanceInterfaceFontHelper;
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
  String get shareTitle => _l10n.appearanceShareTitle;
  @override
  String get copyTheme => _l10n.appearanceCopyTheme;
  @override
  String get pasteTheme => _l10n.appearancePasteTheme;
  @override
  String get shareFootnote => _l10n.appearanceShareFootnote;
  @override
  String get themeCopied => _l10n.appearanceThemeCopied;
  @override
  String get pasteNotATheme => _l10n.appearancePasteNotATheme;

  @override
  String get startOverTitle => _l10n.appearanceStartOverTitle;
  @override
  String resetButton(String name) => _l10n.appearanceResetButton(name);
  @override
  String get usingOwnColours => _l10n.appearanceUsingOwnColours;
  @override
  String usingPreset(String name) => _l10n.appearanceUsingPreset(name);
  @override
  String get resetTitle => _l10n.appearanceResetTitle;
  @override
  String resetBody(String name) => _l10n.appearanceResetBody(name);
  @override
  String get cancel => _l10n.appearanceCancel;
  @override
  String get reset => _l10n.appearanceReset;

  /// A change the app took but could not save, or one it did not take.
  @override
  String notSaved(Object error) => error is AppearanceNotSavedException
      ? _l10n.themeNotSaved
      : _l10n.themeNotChanged;
}

/// A section's title, with a help button when there is more to say.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.helpTitle, this.help});

  final String title;
  final String? helpTitle;
  final String? help;

  @override
  Widget build(BuildContext context) {
    final help = this.help;
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleSmall),
          ),
          if (help != null)
            IconButton(
              tooltip: l10n.appearanceAbout(title),
              icon: const Icon(Icons.help_outline, size: 20),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(helpTitle ?? title),
                  content: SingleChildScrollView(child: Text(help)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(l10n.appearanceClose),
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
