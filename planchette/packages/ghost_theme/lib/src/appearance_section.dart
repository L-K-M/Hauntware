import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghost_ui/ghost_ui.dart';

import 'app_appearance.dart';
import 'ghost_theme.dart';
import 'ghost_theme_codec.dart';
import 'ghost_theme_presets.dart';
import 'ghost_theme_style.dart';
import 'theme_palette.dart';

/// Where the Appearance editor reads the device's appearance and writes it
/// back: each host's settings store (design docs/design/ghost-theme.md §4).
abstract interface class GhostAppearanceModel {
  /// The appearance as stored when the editor opens.
  AppAppearance get value;

  /// Stores [palette] and [mode]. A failure is reported to the user and the
  /// editor keeps its values, so the next change writes them again.
  Future<void> setAppearance(ThemePalette palette, ThemeModePreference mode);
}

/// A section heading, with a help dialog when [help] is set: the host's
/// own settings header, so the editor lines up with its other tabs.
typedef GhostAppearanceHeader =
    Widget Function(String title, {String? helpTitle, String? help});

/// Every word the Appearance editor shows. The defaults are Séance's own
/// literals; a host that localizes extends this class and overrides each
/// member from its ARB (design §3). Preset names and `Custom` are stored
/// data, never translated in the palette itself: [presetLabel] maps them
/// for display.
class GhostAppearanceStrings {
  const GhostAppearanceStrings();

  String get themeTitle => 'Theme';
  String get themeHelpTitle => 'Themes';
  String get themeHelp =>
      'A theme is kept on this device only and never syncs. To use one '
      'elsewhere, copy it here and paste it into Séance on the other device.';
  String get themeFootnote =>
      'Picking a theme copies its colours here. It is a starting point, not '
      'a mode, so everything below stays yours to change.';

  /// What the preset grid and the footers call the preset stored as
  /// [storedName].
  String presetLabel(String storedName) => storedName;
  String presetTooltip(String name) => 'Use the $name theme';

  String get modeTitle => 'Mode';
  String get modeLead => 'Automatic colours follow';
  String get modeSystem => 'System';
  String get modeLight => 'Light';
  String get modeDark => 'Dark';
  String ownSurfaceNote({required bool dark}) =>
      'This theme has its own surface, so it is always '
      '${dark ? 'dark' : 'light'}. Set Surface to Automatic to choose a mode.';

  String get coloursTitle => 'Colours';
  String get coloursHelpTitle => 'Automatic colours';
  String get coloursHelp =>
      'Automatic colours are the light or dark neutrals Séance ships with, '
      'as the mode picks them. Once you give the theme a surface of its own, '
      'they are mixed from that surface and the text instead. Lines and the '
      'selection may be translucent.';
  String get accent => 'Accent';

  String slotLabel(ThemeSlot slot) => switch (slot) {
    ThemeSlot.surface => 'Surface',
    ThemeSlot.sidebar => 'Sidebar',
    ThemeSlot.raised => 'Headers and bars',
    ThemeSlot.text => 'Text',
    ThemeSlot.secondaryText => 'Secondary text',
    ThemeSlot.hairline => 'Lines',
    ThemeSlot.selection => 'Selection',
    ThemeSlot.online => 'Online',
    ThemeSlot.offline => 'Offline',
    ThemeSlot.connecting => 'Connecting',
    ThemeSlot.unknown => 'Unknown',
  };

  String get statusTitle => 'Status colours';
  String get statusFootnote =>
      'Each status also keeps its own shape and its name, so these colours '
      'never have to say it alone.';

  String get automatic => 'Automatic';
  String automaticSemantics(String label) => '$label: Automatic';
  String chooseColour(String label) => 'Choose the $label colour';
  String chooseAutomaticColour(String label) =>
      'Choose a $label colour (now Automatic)';

  String get terminalColoursTitle => 'Terminal colours';
  String get terminalColoursHelpTitle => 'Terminal colours';
  String get terminalColoursHelp =>
      'Terminals use the colours below while Colors is "Follow the app '
      'theme". Turned off, they use Séance\'s built-in dark or light terminal '
      'colours.';
  String get ownTerminalTitle => "Use the theme's terminal colours";
  String get ownTerminalSubtitle => 'Off, terminals keep the built-in colours.';
  String get terminalBackground => 'Background';
  String get terminalText => 'Text';
  String get terminalCursor => 'Cursor';
  String get terminalSelection => 'Selection';
  String get ansiNormal => 'Normal';
  String get ansiBright => 'Bright';

  /// The ANSI colour at [index], in [ThemeTerminalColors.ansi]'s order.
  String ansiName(int index) => const [
    'Black',
    'Red',
    'Green',
    'Yellow',
    'Blue',
    'Magenta',
    'Cyan',
    'White',
    'Bright black',
    'Bright red',
    'Bright green',
    'Bright yellow',
    'Bright blue',
    'Bright magenta',
    'Bright cyan',
    'Bright white',
  ][index];

  String get shapeTitle => 'Shape and type';
  String get interfaceFont => 'Interface font';
  String get interfaceFontHint => 'System default';
  String get interfaceFontHelper =>
      'Terminals and code keep their monospace font.';
  String get chooseInstalledFont => 'Choose an installed font';
  String get corners => 'Corners';
  String get cornersSquare => 'Square';
  String cornersPercent(int percent) => '$percent%';
  String cornersSemantics(String label) => 'Corners $label';

  String get shareTitle => 'Share';
  String get copyTheme => 'Copy theme';
  String get pasteTheme => 'Paste theme';
  String get shareFootnote =>
      'Copies the theme as text you can keep or send. Pasting reads what it '
      'can and leaves everything else at the default.';
  String get themeCopied => 'Theme copied.';
  String get pasteNotATheme =>
      'The clipboard does not hold a theme. Copy one with Copy theme first.';

  String get startOverTitle => 'Start over';
  String resetButton(String name) => 'Reset to $name';
  String get usingOwnColours => 'Using your own colours.';
  String usingPreset(String name) => 'Using $name.';
  String get resetTitle => 'Reset the theme?';
  String resetBody(String name) =>
      'Every colour, the terminal colours, the font and the corners go back '
      'to the $name theme. The mode stays as it is.';
  String get cancel => 'Cancel';
  String get reset => 'Reset';

  String notSaved(Object error) => 'Appearance not saved: $error';
}

const List<ThemeSlot> _colourSlots = [
  ThemeSlot.surface,
  ThemeSlot.sidebar,
  ThemeSlot.raised,
  ThemeSlot.text,
  ThemeSlot.secondaryText,
  ThemeSlot.hairline,
  ThemeSlot.selection,
];

const List<ThemeSlot> _statusSlots = [
  ThemeSlot.online,
  ThemeSlot.offline,
  ThemeSlot.connecting,
  ThemeSlot.unknown,
];

/// A preset tile's minimum width: two to a row on a phone, four or so in
/// the settings window.
const double _presetTileMinWidth = 148;
const double _presetGap = 10;

/// The corner a preset tile draws at its preset's own scale, so the grid
/// previews the corners as well as the colours.
const double _presetTileRadius = 8;

/// Below this the corner slider says "Square" rather than a percentage.
const double _squareCornerScale = 0.01;

/// The Appearance editor, after Vervellum's `AppearanceView`: this device's
/// theme, for any host whose [style] binds the shared model. Pick a preset,
/// then change anything.
///
/// Written to be played with. Every control writes straight through the
/// [model] and the app repaints as it does: there is no Save button, and
/// there should not be one, because the only way to judge a theme is to
/// look at it. The window this editor is in repaints too, so it is its own
/// preview.
///
/// The palette is the editor's own copy, edited here and handed to the
/// model whole: in a settings window, the model's value is a copy that
/// trails each write by a round trip.
///
/// The host lays it out with [page] and [header], its settings tab's own
/// widgets, and supplies what only it has: an installed-font picker
/// ([pickInstalledFont]), the terminal colours a palette starts from
/// ([defaultTerminalColors], which also turns the terminal colours section
/// on), and sections of its own terminal settings ([terminalSection],
/// [terminalColoursLead]).
final class GhostAppearanceSection extends StatefulWidget {
  const GhostAppearanceSection({
    super.key,
    required this.style,
    required this.model,
    required this.page,
    required this.header,
    this.strings = const GhostAppearanceStrings(),
    this.pickInstalledFont,
    this.defaultTerminalColors,
    this.terminalSection,
    this.terminalColoursLead,
    this.hexStyle,
  });

  final GhostThemeStyle style;
  final GhostAppearanceModel model;

  /// The host's scrolling settings page around the editor's widgets.
  final Widget Function(List<Widget> children) page;
  final GhostAppearanceHeader header;
  final GhostAppearanceStrings strings;

  /// Opens the host's picker of installed fonts with the field's [current]
  /// family; null where there is no installed collection to read, which
  /// leaves the interface font a text field.
  final Future<String?> Function(BuildContext context, String current)?
  pickInstalledFont;

  /// The terminal colours a palette takes when it starts carrying its own,
  /// at the brightness it is drawn at. Null for a host without terminals,
  /// which shows no terminal colours section.
  final ThemeTerminalColors Function(Brightness drawnAt)? defaultTerminalColors;

  /// A whole section of the host's own terminal settings, its heading
  /// included, shown after the status colours. It gets the palette and the
  /// brightness it is drawn at, for a preview.
  final List<Widget> Function(
    BuildContext context,
    ThemePalette palette,
    Brightness drawnAt,
  )?
  terminalSection;

  /// The host's own control at the top of the terminal colours section.
  final Widget Function(BuildContext context)? terminalColoursLead;

  /// The colour picker's hex box style: the host's monospace stack.
  final TextStyle? hexStyle;

  @override
  State<GhostAppearanceSection> createState() => _GhostAppearanceSectionState();
}

class _GhostAppearanceSectionState extends State<GhostAppearanceSection> {
  late final GhostThemePresets _presets = GhostThemePresets(widget.style);
  late final GhostThemeCodec _codec = GhostThemeCodec(widget.style);

  late ThemePalette _palette = widget.model.value.palette;
  late ThemeModePreference _mode = widget.model.value.mode;

  /// Colours handed back to Automatic this session, so switching one off
  /// Automatic again returns what it was rather than starting over. Not
  /// persisted: it is an undo for a click, not a second copy of the theme.
  /// Cleared by anything that replaces the theme wholesale (a preset, a
  /// paste, a reset), which is not what it undoes.
  final Map<ThemeSlot, Color> _setAside = {};
  ThemeTerminalColors? _terminalSetAside;

  late final TextEditingController _font = TextEditingController(
    text: _palette.fontFamily ?? '',
  );

  /// One write in flight at a time; see [_persist].
  bool _writing = false;
  bool _dirty = false;

  GhostAppearanceStrings get _s => widget.strings;

  @override
  void dispose() {
    _font.dispose();
    super.dispose();
  }

  /// What Automatic colours follow here, whatever the palette.
  Brightness get _automatic =>
      automaticBrightness(MediaQuery.platformBrightnessOf(context), _mode);

  /// The brightness the palette is drawn at.
  Brightness get _drawnAt => resolveBrightness(
    _palette,
    MediaQuery.platformBrightnessOf(context),
    _mode,
  );

  /// Writes the palette and mode as they are now, one write at a time.
  ///
  /// The controls write through on every change (a corner drag is dozens a
  /// second) and each write is a settings save, and in a settings window a
  /// round trip to the app as well. Changes that land while one is in
  /// flight fold into a single write after it, of whatever is current then,
  /// rather than queueing one each. Finishes even if the tab is closed
  /// mid-drag, so the last value is the one that sticks.
  Future<void> _persist() async {
    if (_writing) {
      _dirty = true;
      return;
    }
    _writing = true;
    try {
      do {
        _dirty = false;
        try {
          await widget.model.setAppearance(_palette, _mode);
        } catch (e) {
          // Reported only when no newer write is waiting to retry: against a
          // failing disk a corner drag would otherwise toast once per write.
          if (mounted && !_dirty) {
            showTopToastIn(context, message: _s.notSaved(e));
          }
        }
      } while (_dirty);
    } finally {
      _writing = false;
    }
  }

  void _replace(ThemePalette palette) {
    if (palette == _palette) return;
    setState(() => _palette = palette);
    unawaited(_persist());
  }

  /// An edit to one value: the result is named for what it now matches.
  void _edit(ThemePalette palette) => _replace(_presets.relabel(palette));

  /// A whole theme at once: a preset, a paste, the reset.
  void _adopt(ThemePalette palette) {
    _setAside.clear();
    _terminalSetAside = null;
    _font.text = palette.fontFamily ?? '';
    _replace(palette);
  }

  void _setMode(ThemeModePreference mode) {
    if (mode == _mode) return;
    setState(() => _mode = mode);
    unawaited(_persist());
  }

  /// Off Automatic, a slot starts from what it was set aside as, or from
  /// what it draws as right now, so the first change is an adjustment and
  /// not a recovery from black.
  void _setAutomatic(ThemeSlot slot, bool automatic) {
    if (automatic) {
      final current = _palette.slot(slot);
      if (current == null) return;
      _setAside[slot] = current;
      _edit(_palette.withSlot(slot, null));
      return;
    }
    final start =
        _setAside.remove(slot) ??
        GhostTheme.resolvedSlots(widget.style, _palette, _automatic)[slot]!;
    _edit(_palette.withSlot(slot, start));
  }

  Future<Color?> _pick(
    String label,
    Color initial, {
    bool allowAlpha = false,
  }) => showColorPicker(
    context,
    initial: initial,
    title: label,
    allowAlpha: allowAlpha,
    hexStyle: widget.hexStyle,
  );

  Future<void> _pickSlot(ThemeSlot slot, Color current) async {
    final picked = await _pick(
      _s.slotLabel(slot),
      current,
      allowAlpha: slot.allowsAlpha,
    );
    if (picked == null || !mounted) return;
    _edit(_palette.withSlot(slot, picked));
  }

  Future<void> _pickAccent() async {
    final picked = await _pick(_s.accent, _palette.accent);
    if (picked == null || !mounted) return;
    _edit(_palette.copyWith(accent: picked));
  }

  void _setOwnTerminal(bool own) {
    if (own) {
      _edit(
        _palette.withTerminal(
          _terminalSetAside ?? widget.defaultTerminalColors!(_drawnAt),
        ),
      );
      return;
    }
    _terminalSetAside = _palette.terminal;
    _edit(_palette.withTerminal(null));
  }

  Future<void> _pickTerminal(
    String label,
    Color current,
    ThemeTerminalColors Function(ThemeTerminalColors colors, Color picked)
    apply, {
    bool allowAlpha = false,
  }) async {
    final picked = await _pick(label, current, allowAlpha: allowAlpha);
    final colors = _palette.terminal;
    if (picked == null || colors == null || !mounted) return;
    _edit(_palette.withTerminal(apply(colors, picked)));
  }

  void _commitFont() {
    final family = _font.text.trim();
    if (family == (_palette.fontFamily ?? '')) return;
    _edit(_palette.withFontFamily(family));
  }

  Future<void> _pickFont() async {
    final chosen = await widget.pickInstalledFont!(context, _font.text.trim());
    if (chosen == null || !mounted) return;
    _font.text = chosen;
    _commitFont();
  }

  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(
        text: const JsonEncoder.withIndent('  ').convert(_palette.toJson()),
      ),
    );
    if (mounted) showTopToastIn(context, message: _s.themeCopied);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text;
    final pasted = text == null ? null : _codec.tryParse(text);
    if (pasted == null) {
      showTopToastIn(context, message: _s.pasteNotATheme);
      return;
    }
    _adopt(pasted);
  }

  Future<void> _reset() async {
    final initial = _s.presetLabel(_presets.initial.name);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_s.resetTitle),
        content: Text(_s.resetBody(initial)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_s.reset),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _adopt(_presets.initial);
  }

  @override
  Widget build(BuildContext context) {
    final header = widget.header;
    final resolved = GhostTheme.resolvedSlots(
      widget.style,
      _palette,
      _automatic,
    );
    final current = _presets.matching(_palette);
    final terminalSection = widget.terminalSection;
    return widget.page([
      header(_s.themeTitle, helpTitle: _s.themeHelpTitle, help: _s.themeHelp),
      _PresetGrid(
        style: widget.style,
        presets: _presets,
        strings: _s,
        selected: current,
        automatic: _automatic,
        onPick: _adopt,
      ),
      _Footnote(_s.themeFootnote),
      const Divider(height: 40),
      header(_s.modeTitle),
      ..._modeSection(),
      const Divider(height: 40),
      header(
        _s.coloursTitle,
        helpTitle: _s.coloursHelpTitle,
        help: _s.coloursHelp,
      ),
      _ColourRow(
        strings: _s,
        label: _s.accent,
        color: _palette.accent,
        onPick: _pickAccent,
      ),
      for (final slot in _colourSlots) _slotRow(slot, resolved),
      const Divider(height: 40),
      header(_s.statusTitle),
      for (final slot in _statusSlots) _slotRow(slot, resolved),
      _Footnote(_s.statusFootnote),
      if (terminalSection != null) ...[
        const Divider(height: 40),
        ...terminalSection(context, _palette, _drawnAt),
      ],
      if (widget.defaultTerminalColors != null) ...[
        const Divider(height: 40),
        header(
          _s.terminalColoursTitle,
          helpTitle: _s.terminalColoursHelpTitle,
          help: _s.terminalColoursHelp,
        ),
        ..._terminalColoursSection(),
      ],
      const Divider(height: 40),
      header(_s.shapeTitle),
      ..._shapeSection(),
      const Divider(height: 40),
      header(_s.shareTitle),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: _copy,
            icon: const Icon(Icons.copy_outlined, size: 18),
            label: Text(_s.copyTheme),
          ),
          OutlinedButton.icon(
            onPressed: _paste,
            icon: const Icon(Icons.paste_outlined, size: 18),
            label: Text(_s.pasteTheme),
          ),
        ],
      ),
      _Footnote(_s.shareFootnote),
      const Divider(height: 40),
      header(_s.startOverTitle),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton(
            onPressed: _reset,
            child: Text(_s.resetButton(_s.presetLabel(_presets.initial.name))),
          ),
          Text(
            current == null
                ? _s.usingOwnColours
                : _s.usingPreset(_s.presetLabel(current.name)),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ]);
  }

  List<Widget> _modeSection() {
    final ownSurface = _palette.surface != null;
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(_s.modeLead, style: Theme.of(context).textTheme.bodyMedium),
      ),
      SegmentedButton<ThemeModePreference>(
        segments: [
          ButtonSegment(
            value: ThemeModePreference.system,
            icon: const Icon(Icons.brightness_auto_outlined),
            label: Text(_s.modeSystem),
          ),
          ButtonSegment(
            value: ThemeModePreference.light,
            icon: const Icon(Icons.light_mode_outlined),
            label: Text(_s.modeLight),
          ),
          ButtonSegment(
            value: ThemeModePreference.dark,
            icon: const Icon(Icons.dark_mode_outlined),
            label: Text(_s.modeDark),
          ),
        ],
        selected: {_mode},
        // A surface of its own decides the brightness, so no mode can
        // change what is drawn; offering the choice would be a control that
        // does nothing.
        onSelectionChanged: ownSurface
            ? null
            : (selection) => _setMode(selection.single),
      ),
      if (ownSurface)
        _Footnote(_s.ownSurfaceNote(dark: _drawnAt == Brightness.dark)),
    ];
  }

  Widget _slotRow(ThemeSlot slot, Map<ThemeSlot, Color> resolved) {
    final label = _s.slotLabel(slot);
    final automatic = _palette.slot(slot) == null;
    final shown = _palette.slot(slot) ?? resolved[slot]!;
    return _ColourRow(
      strings: _s,
      label: label,
      color: shown,
      automatic: automatic,
      onAutomaticChanged: (value) => _setAutomatic(slot, value),
      onPick: () => _pickSlot(slot, shown),
    );
  }

  List<Widget> _terminalColoursSection() {
    final colors = _palette.terminal;
    final lead = widget.terminalColoursLead;
    Widget row(
      String label,
      Color color,
      ThemeTerminalColors Function(ThemeTerminalColors, Color) apply, {
      bool allowAlpha = false,
    }) => _ColourRow(
      strings: _s,
      label: label,
      color: color,
      onPick: () => _pickTerminal(label, color, apply, allowAlpha: allowAlpha),
    );
    return [
      if (lead != null) ...[lead(context), const SizedBox(height: 8)],
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(_s.ownTerminalTitle),
        subtitle: Text(_s.ownTerminalSubtitle),
        value: colors != null,
        onChanged: _setOwnTerminal,
      ),
      if (colors != null) ...[
        row(
          _s.terminalBackground,
          colors.background,
          (c, picked) => c.copyWith(background: picked),
        ),
        row(
          _s.terminalText,
          colors.foreground,
          (c, picked) => c.copyWith(foreground: picked),
        ),
        row(
          _s.terminalCursor,
          colors.cursor,
          (c, picked) => c.copyWith(cursor: picked),
        ),
        row(
          _s.terminalSelection,
          colors.selection,
          (c, picked) => c.copyWith(selection: picked),
          allowAlpha: true,
        ),
        const SizedBox(height: 8),
        _AnsiGrid(
          strings: _s,
          colors: colors,
          onPick: (index) => _pickTerminal(
            _s.ansiName(index),
            colors.ansi[index],
            (c, picked) => c.withAnsi(index, picked),
          ),
        ),
      ],
    ];
  }

  List<Widget> _shapeSection() {
    final scale = _palette.cornerScale;
    final cornerLabel = scale <= _squareCornerScale
        ? _s.cornersSquare
        : _s.cornersPercent((scale * 100).round());
    return [
      TextField(
        controller: _font,
        decoration: InputDecoration(
          labelText: _s.interfaceFont,
          hintText: _s.interfaceFontHint,
          helperText: _s.interfaceFontHelper,
          // Only where there is an installed collection to read.
          suffixIcon: widget.pickInstalledFont != null
              ? IconButton(
                  tooltip: _s.chooseInstalledFont,
                  icon: const Icon(Icons.font_download_outlined),
                  onPressed: _pickFont,
                )
              : null,
        ),
        onSubmitted: (_) => _commitFont(),
        onTapOutside: (_) {
          // Overriding onTapOutside replaces TextField's default handler, so
          // the dismissal it would have done has to be done here.
          FocusManager.instance.primaryFocus?.unfocus();
          _commitFont();
        },
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Text(_s.corners),
          Expanded(
            child: Slider(
              min: ThemePalette.minCornerScale,
              max: ThemePalette.maxCornerScale,
              divisions: 40,
              value: scale,
              label: cornerLabel,
              // The text beside the slider is a sibling, not its label:
              // without this a screen reader says "65%" and never of what.
              semanticFormatterCallback: (_) =>
                  _s.cornersSemantics(cornerLabel),
              onChanged: (value) =>
                  _edit(_palette.copyWith(cornerScale: value)),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              cornerLabel,
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    ];
  }
}

/// A line of small print under a section's controls.
class _Footnote extends StatelessWidget {
  const _Footnote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// One colour: its name, an Automatic box where it may be Automatic, and a
/// swatch that opens the picker.
class _ColourRow extends StatelessWidget {
  const _ColourRow({
    required this.strings,
    required this.label,
    required this.color,
    required this.onPick,
    this.automatic,
    this.onAutomaticChanged,
  });

  final GhostAppearanceStrings strings;
  final String label;

  /// What the swatch shows: the colour set, or what Automatic draws now.
  final Color color;
  final VoidCallback onPick;

  /// Null for a colour that cannot be Automatic.
  final bool? automatic;
  final ValueChanged<bool>? onAutomaticChanged;

  @override
  Widget build(BuildContext context) {
    final automatic = this.automatic;
    final onAutomaticChanged = this.onAutomaticChanged;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          if (automatic != null && onAutomaticChanged != null)
            InkWell(
              onTap: () => onAutomaticChanged(!automatic),
              borderRadius: BorderRadius.circular(4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: automatic,
                    semanticLabel: strings.automaticSemantics(label),
                    onChanged: (value) => onAutomaticChanged(value ?? false),
                  ),
                  ExcludeSemantics(child: Text(strings.automatic)),
                  const SizedBox(width: 12),
                ],
              ),
            ),
          _SwatchButton(
            color: color,
            tooltip: automatic == true
                ? strings.chooseAutomaticColour(label)
                : strings.chooseColour(label),
            onPressed: onPick,
          ),
        ],
      ),
    );
  }
}

class _SwatchButton extends StatelessWidget {
  const _SwatchButton({
    required this.color,
    required this.tooltip,
    required this.onPressed,
    this.size = 28,
  });

  final Color color;
  final String tooltip;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    // Merged, tooltip inside: a Tooltip's own annotation above the button
    // would merge into whatever node is above it, which for these rows is
    // the page, and every swatch would say every other's name.
    return MergeSemantics(
      child: Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          value: formatThemeColor(color),
          excludeSemantics: true,
          onTap: onPressed,
          child: InkWell(
            onTap: onPressed,
            customBorder: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(size / 6),
            ),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: ColorSwatchBox(color: color, size: size),
            ),
          ),
        ),
      ),
    );
  }
}

/// The presets as small pictures of themselves: surface, accent, name and
/// the four status colours, which is what actually differs between two
/// themes that both read as "dark blue" in a list of names.
class _PresetGrid extends StatelessWidget {
  const _PresetGrid({
    required this.style,
    required this.presets,
    required this.strings,
    required this.selected,
    required this.automatic,
    required this.onPick,
  });

  final GhostThemeStyle style;
  final GhostThemePresets presets;
  final GhostAppearanceStrings strings;
  final ThemePalette? selected;

  /// What a preset that leaves its surface Automatic would be drawn at.
  final Brightness automatic;
  final ValueChanged<ThemePalette> onPick;

  /// What each preset looks like at a brightness, in the presets' order,
  /// per style. Worked out once per run: the presets never change, the
  /// editor rebuilds on every edit, and each look seeds a Material colour
  /// scheme.
  static final Map<
    GhostThemeStyle,
    Map<Brightness, List<Map<ThemeSlot, Color>>>
  >
  _looks = {};

  @override
  Widget build(BuildContext context) {
    final all = presets.all;
    final looks = (_looks[style] ??= {}).putIfAbsent(
      automatic,
      () => [
        for (final preset in all)
          GhostTheme.resolvedSlots(style, preset, automatic),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns =
            ((width + _presetGap) / (_presetTileMinWidth + _presetGap))
                .floor()
                .clamp(1, all.length);
        final tileWidth = (width - _presetGap * (columns - 1)) / columns;
        return Wrap(
          spacing: _presetGap,
          runSpacing: _presetGap,
          children: [
            for (final (i, preset) in all.indexed)
              SizedBox(
                width: tileWidth,
                child: _PresetTile(
                  preset: preset,
                  label: strings.presetLabel(preset.name),
                  tooltip: strings.presetTooltip(
                    strings.presetLabel(preset.name),
                  ),
                  colours: looks[i],
                  selected: selected?.name == preset.name,
                  onTap: () => onPick(preset),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.preset,
    required this.label,
    required this.tooltip,
    required this.colours,
    required this.selected,
    required this.onTap,
  });

  final ThemePalette preset;
  final String label;
  final String tooltip;
  final Map<ThemeSlot, Color> colours;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(
      _presetTileRadius * preset.cornerScale,
    );
    final text = colours[ThemeSlot.text]!;
    // Merged with the tooltip inside, as in [_SwatchButton].
    return MergeSemantics(
      child: Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          selected: selected,
          child: Material(
            color: colours[ThemeSlot.surface],
            shape: RoundedRectangleBorder(
              borderRadius: radius,
              side: BorderSide(
                color: selected ? preset.accent : colours[ThemeSlot.hairline]!,
                width: selected ? 2 : 1,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 13,
                          height: 13,
                          decoration: BoxDecoration(
                            color: preset.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            // In the preset's own text colour: the tile is
                            // drawn in the preset's colours, and Terminal's
                            // name in the app's black would vanish on it.
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  color: text,
                                  fontWeight: FontWeight.w500,
                                ),
                          ),
                        ),
                        if (selected)
                          Icon(
                            Icons.check_circle,
                            size: 16,
                            color: preset.accent,
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        for (final (i, slot) in _statusSlots.indexed) ...[
                          if (i > 0) const SizedBox(width: 3),
                          Expanded(
                            child: Container(
                              height: 6,
                              decoration: BoxDecoration(
                                color: colours[slot],
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The sixteen ANSI colours as two rows of eight, normal over bright.
class _AnsiGrid extends StatelessWidget {
  const _AnsiGrid({
    required this.strings,
    required this.colors,
    required this.onPick,
  });

  final GhostAppearanceStrings strings;
  final ThemeTerminalColors colors;
  final ValueChanged<int> onPick;

  static const int _perRow = 8;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var row = 0; row < 2; row++)
          Row(
            children: [
              SizedBox(
                width: 64,
                child: Text(
                  row == 0 ? strings.ansiNormal : strings.ansiBright,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              for (var column = 0; column < _perRow; column++)
                Builder(
                  builder: (context) {
                    final index = row * _perRow + column;
                    return _SwatchButton(
                      color: colors.ansi[index],
                      size: 24,
                      tooltip: strings.chooseColour(strings.ansiName(index)),
                      onPressed: () => onPick(index),
                    );
                  },
                ),
            ],
          ),
      ],
    );
  }
}
