import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_fonts/ghost_fonts.dart';
import 'package:ghost_theme/ghost_theme.dart'
    show GhostAppearanceModel, GhostAppearanceSection;

import '../services/settings_backend.dart';
import '../services/system_fonts.dart';
import '../theme.dart';
import '../theme/app_appearance.dart';
import '../theme/theme_palette.dart';
import 'color_picker.dart';
import 'font_picker.dart';
import 'settings_layout.dart';
import 'terminal_appearance.dart';
import 'top_toast.dart';

/// The Appearance tab: this device's theme, in ghost_theme's shared editor
/// ([GhostAppearanceSection]) with Séance's words, layout and pickers, and
/// its terminal's text and colour source, which are Séance's own settings.
///
/// The theme writes straight through the backend as the editor changes it
/// (see [GhostAppearanceSection]); the terminal settings are written with
/// their own backend call and survive a preset or a reset.
class AppearanceSettings extends StatefulWidget {
  const AppearanceSettings({
    super.key,
    required this.backend,
    required this.systemFonts,
  });

  final SettingsBackend backend;

  /// The installed families behind the interface and terminal font pickers.
  final SystemFonts systemFonts;

  @override
  State<AppearanceSettings> createState() => _AppearanceSettingsState();
}

/// The backend as the shared editor's model.
final class _BackendAppearance implements GhostAppearanceModel {
  const _BackendAppearance(this._backend);

  final SettingsBackend _backend;

  @override
  AppAppearance get value => AppAppearance(
    palette: _backend.settings.themePalette,
    mode: _backend.settings.themeMode,
  );

  @override
  Future<void> setAppearance(ThemePalette palette, ThemeModePreference mode) =>
      _backend.setAppearance(palette, mode);
}

class _AppearanceSettingsState extends State<AppearanceSettings> {
  late final _model = _BackendAppearance(widget.backend);

  /// The palette the editor last drew the terminal section with, for the
  /// terminal font picker's preview, which opens outside that build.
  ThemePalette? _palette;

  /// The terminal's text and colour source. Not part of the theme: they are
  /// written with their own backend call and survive a preset or a reset.
  late double _terminalFontSize = clampTerminalFontSize(
    widget.backend.settings.terminalFontSize,
  );
  late TerminalPalette _terminalPalette =
      widget.backend.settings.terminalPalette;
  late TerminalLigatures _terminalLigatures =
      widget.backend.settings.terminalLigatures;

  /// The family as last committed; [_terminalFont] may be mid-edit.
  late String _terminalFamily = widget.backend.settings.terminalFontFamily
      .trim();
  late final TextEditingController _terminalFont = TextEditingController(
    text: _terminalFamily,
  );

  @override
  void dispose() {
    _terminalFont.dispose();
    super.dispose();
  }

  Future<String?> _pickFont(BuildContext context, String current) =>
      showFontPicker(
        context,
        fonts: widget.systemFonts,
        current: current,
        title: 'Interface font',
        filter: FontPickerFilter.all,
        builtInLabel: 'Use system default',
      );

  /// Writes the terminal's settings and repaints every live session. Called
  /// on slider release and on each discrete choice.
  Future<void> _persistTerminal() async {
    try {
      await widget.backend.setTerminalAppearance(
        fontSize: _terminalFontSize,
        fontFamily: _terminalFamily,
        palette: _terminalPalette,
        ligatures: _terminalLigatures,
      );
    } catch (e) {
      if (!mounted) return;
      showTopToastIn(context, message: 'Terminal appearance not saved: $e');
    }
  }

  void _commitTerminalFont() {
    final family = _terminalFont.text.trim();
    if (family == _terminalFamily) return;
    setState(() => _terminalFamily = family);
    unawaited(_persistTerminal());
  }

  /// A dismissal leaves the field alone; the default choice clears it,
  /// which is what a blank family already means to [TerminalAppearance].
  Future<void> _pickTerminalFont() async {
    final chosen = await showMonoFontPicker(
      context,
      current: _terminalFont.text.trim(),
      defaultFont: kDefaultTerminalFont,
      fontSize: _terminalFontSize,
      ligatures: _terminalLigatures == TerminalLigatures.on
          ? MonoLigatures.on
          : MonoLigatures.off,
      installedFonts: widget.systemFonts.isSupported
          ? () async => {
              for (final font in await widget.systemFonts.families())
                font.name: font.monospaced,
            }
          : null,
      labels: const MonoFontPickerLabels(title: 'Terminal font'),
      previewBuilder: (family, ligatures) => SizedBox(
        width: 360,
        child: _TerminalPreview(
          appearance: TerminalAppearance.of(
            fontSize: _terminalFontSize,
            fontFamily: family,
            ligatures: ligatures == MonoLigatures.on
                ? TerminalLigatures.on
                : TerminalLigatures.off,
            palette: _terminalPalette,
            themeColors: _palette?.terminal,
            brightness: Theme.of(context).brightness,
          ),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    _terminalFont.text = chosen.family;
    setState(() {
      _terminalFamily = chosen.family;
      _terminalLigatures = chosen.ligatures == MonoLigatures.on
          ? TerminalLigatures.on
          : TerminalLigatures.off;
    });
    unawaited(_persistTerminal());
  }

  @override
  Widget build(BuildContext context) => GhostAppearanceSection(
    style: seanceThemeStyle,
    model: _model,
    page: (children) => SettingsPage(
      storageKey: const PageStorageKey('appearance-settings'),
      children: children,
    ),
    header: (title, {helpTitle, help}) =>
        SettingsSectionHeader(title, helpTitle: helpTitle, help: help),
    pickInstalledFont: widget.systemFonts.isSupported ? _pickFont : null,
    defaultTerminalColors: (drawnAt) =>
        SeanceTerminalThemes.toColors(SeanceTerminalThemes.builtIn(drawnAt)),
    terminalSection: (context, palette, drawnAt) {
      _palette = palette;
      return [
        SettingsSectionHeader(
          'Terminal',
          helpTitle: 'Terminal appearance',
          help:
              'Font size, family, colors and ligatures apply to every session '
              'on this device. With the terminal focused you can zoom without '
              'opening Settings: ⌘ with +, − or 0 on macOS and iPadOS, '
              'Ctrl+Shift with the same keys elsewhere (plain Ctrl chords '
              'belong to the shell). Leave the font family blank to use '
              '${kDefaultTerminalFont.displayName}, which ships with Séance '
              'and draws ligatures. The button in the field lists the fonts '
              'Séance includes and, on desktop, the ones installed here, each '
              'previewed in its own face; you can also type any family name '
              'the system knows.',
        ),
        ..._terminalTextSection(palette, drawnAt),
      ];
    },
    terminalColoursLead: (context) => DropdownButtonFormField<TerminalPalette>(
      initialValue: _terminalPalette,
      // A phone's width ellipsizes the longest choice instead of
      // overflowing.
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Colors'),
      items: const [
        DropdownMenuItem(
          value: TerminalPalette.followApp,
          child: Text('Follow the app theme'),
        ),
        DropdownMenuItem(
          value: TerminalPalette.alwaysDark,
          child: Text('Always dark'),
        ),
        DropdownMenuItem(
          value: TerminalPalette.alwaysLight,
          child: Text('Always light'),
        ),
      ],
      onChanged: (value) {
        if (value == null || value == _terminalPalette) return;
        setState(() => _terminalPalette = value);
        unawaited(_persistTerminal());
      },
    ),
    hexStyle: seanceHexStyle,
  );

  /// The preview, drawn as the terminal will draw it in [palette] at
  /// [drawnAt], then the text controls.
  List<Widget> _terminalTextSection(ThemePalette palette, Brightness drawnAt) {
    final sizeLabel = '${_terminalFontSize.round()} pt';
    return [
      _TerminalPreview(
        appearance: TerminalAppearance.of(
          fontSize: _terminalFontSize,
          fontFamily: _terminalFamily,
          ligatures: _terminalLigatures,
          palette: _terminalPalette,
          themeColors: palette.terminal,
          brightness: drawnAt,
        ),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          const Text('Size'),
          Expanded(
            child: Slider(
              key: const ValueKey('terminal.textSize'),
              min: kMinTerminalFontSize,
              max: kMaxTerminalFontSize,
              divisions:
                  ((kMaxTerminalFontSize - kMinTerminalFontSize) /
                          kTerminalFontSizeStep)
                      .round(),
              value: _terminalFontSize,
              label: sizeLabel,
              semanticFormatterCallback: (_) => 'Terminal size $sizeLabel',
              onChanged: (value) => setState(
                () => _terminalFontSize = clampTerminalFontSize(value),
              ),
              onChangeEnd: (_) => _persistTerminal(),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              sizeLabel,
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
      TextField(
        key: const ValueKey('terminal.font'),
        controller: _terminalFont,
        decoration: InputDecoration(
          labelText: 'Font family (optional)',
          hintText:
              'e.g. Fira Code — blank uses ${kDefaultTerminalFont.displayName}',
          // Everywhere: the fonts Séance includes are always there to pick.
          // Installed ones join them only where there is a collection to
          // read (on mobile an app sees the system faces it is given rather
          // than a user-managed library).
          suffixIcon: IconButton(
            tooltip: 'Choose a font',
            icon: const Icon(Icons.font_download_outlined),
            onPressed: _pickTerminalFont,
          ),
        ),
        onSubmitted: (_) => _commitTerminalFont(),
        onTapOutside: (_) {
          // As for the interface font's field: the override has to dismiss
          // the soft keyboard itself.
          FocusManager.instance.primaryFocus?.unfocus();
          _commitTerminalFont();
        },
      ),
      SwitchListTile(
        key: const ValueKey('terminal.ligatures'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Ligatures'),
        subtitle: const Text(
          'Join character pairs such as -> and != into one symbol, in fonts '
          'that draw them.',
        ),
        value: _terminalLigatures == TerminalLigatures.on,
        onChanged: (on) {
          setState(
            () => _terminalLigatures = on
                ? TerminalLigatures.on
                : TerminalLigatures.off,
          );
          unawaited(_persistTerminal());
        },
      ),
    ];
  }
}

/// A few words of shell output as the terminal draws them, in its font,
/// size, ligatures and colours: a prompt, an arrow a ligature font joins,
/// an error, a warning, a success.
class _TerminalPreview extends StatelessWidget {
  const _TerminalPreview({required this.appearance});

  final TerminalAppearance appearance;

  @override
  Widget build(BuildContext context) {
    final theme = appearance.theme;
    final style = appearance.style;
    final text = style.toTextStyle(color: theme.foreground);
    TextSpan span(String text, Color color) => TextSpan(
      text: text,
      style: TextStyle(color: color),
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.background,
        borderRadius: BorderRadius.circular(
          SeanceChrome.of(context, seanceThemeStyle).corner(6),
        ),
      ),
      child: Text.rich(
        TextSpan(
          style: text,
          children: [
            span('deploy@web', theme.green),
            span(':', theme.foreground),
            span('~/site', theme.blue),
            span(r'$ make', theme.foreground),
            const TextSpan(text: '\n'),
            span('=> building 14 pages\n', theme.foreground),
            span('error:', theme.red),
            span(' missing target\n', theme.foreground),
            span('warning:', theme.yellow),
            span(' 2 files skipped\n', theme.foreground),
            span('ok', theme.cyan),
            span(' 14 passed ', theme.foreground),
            span('(0.8 s)', theme.magenta),
            const TextSpan(text: '\nIl1 | 0Oo  {}[]  -> != ===\n'),
            const TextSpan(
              text: 'Aa Bb 0123  ',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const TextSpan(
              text: 'Aa Bb 0123',
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
          ],
        ),
        semanticsLabel: 'Terminal preview',
      ),
    );
  }
}
