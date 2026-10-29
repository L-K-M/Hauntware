import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_fonts/ghost_fonts.dart';
import 'package:planchette_editor/planchette_editor.dart';

import 'app_settings.dart';

/// Settings: what the app looks like and how new documents indent.
///
/// Edits apply live rather than behind an OK button, so a text size can be
/// seen before it is kept. Cancel restores what was there when the dialog
/// opened, which is the one thing a live-preview dialog has to get right, and
/// a click outside the dialog does nothing, so a preview is never kept or
/// dropped by accident.
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.settings});

  final SettingsController settings;

  /// Show the dialog and resolve once the user is done.
  static Future<void> show(
    BuildContext context, {
    required SettingsController settings,
  }) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => SettingsDialog(settings: settings),
  );

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  /// What was in force when the dialog opened, so Cancel has something to put
  /// back. Captured in initState: a lazy initializer would first run inside
  /// Cancel and capture the previewed value instead.
  late final AppSettings _starting;

  @override
  void initState() {
    super.initState();
    _starting = widget.settings.value;
  }

  AppSettings get _value => widget.settings.value;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.settings,
    builder: (context, _) => _dialog(context),
  );

  Widget _dialog(BuildContext context) {
    final theme = Theme.of(context);
    final indentation = _value.indentation;
    final tabs = indentation.style == IndentStyle.tabs;
    return AlertDialog(
      title: const Text('Settings'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _section(theme, 'Appearance'),
              SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('System')),
                  ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                ],
                selected: {_value.themeMode},
                onSelectionChanged: (selection) =>
                    _apply(_value.copyWith(themeMode: selection.first)),
              ),
              const SizedBox(height: 16),
              _section(theme, 'Text'),
              _slider(
                theme: theme,
                label: 'Size',
                value: _value.fontSize,
                min: AppSettings.minimumFontSize,
                max: AppSettings.maximumFontSize,
                onChanged: (size) => _apply(_value.copyWith(fontSize: size)),
              ),
              _fontMenu(theme),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Ligatures'),
                subtitle: const Text(
                  'Join character pairs such as -> and != into one symbol, '
                  'in fonts that draw them.',
                ),
                value: _value.ligatures == EditorLigatures.on,
                onChanged: (on) => _apply(
                  _value.copyWith(
                    ligatures: on ? EditorLigatures.on : EditorLigatures.off,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _section(theme, 'Indentation for new documents'),
              OverflowBar(
                alignment: MainAxisAlignment.spaceBetween,
                spacing: 16,
                overflowSpacing: 8,
                children: [
                  Text('Indent with', style: theme.textTheme.bodyMedium),
                  SegmentedButton<IndentStyle>(
                    segments: const [
                      ButtonSegment(
                        value: IndentStyle.spaces,
                        label: Text('Spaces'),
                      ),
                      ButtonSegment(
                        value: IndentStyle.tabs,
                        label: Text('Tabs'),
                      ),
                    ],
                    selected: {indentation.style},
                    onSelectionChanged: (selection) => _apply(
                      _value.copyWith(
                        indentation: selection.first == IndentStyle.tabs
                            ? Indentation.tabs(width: indentation.width)
                            : Indentation.spaces(indentation.width),
                      ),
                    ),
                  ),
                ],
              ),
              _slider(
                theme: theme,
                label: 'Width',
                value: indentation.width,
                min: 1,
                max: AppSettings.maximumIndentWidth,
                onChanged: (width) => _apply(
                  _value.copyWith(
                    indentation: tabs
                        ? Indentation.tabs(width: width)
                        : Indentation.spaces(width),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'A file that already indents, or a format that requires '
                  'tabs, keeps its own.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 16),
              _section(theme, 'Saving'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Trim trailing whitespace on save'),
                value:
                    _value.saveOptions.trailingWhitespace ==
                    TrailingWhitespacePolicy.trim,
                onChanged: (enabled) => _apply(
                  _value.copyWith(
                    saveOptions: TextSaveOptions(
                      trailingWhitespace: enabled
                          ? TrailingWhitespacePolicy.trim
                          : TrailingWhitespacePolicy.preserve,
                      finalNewline: _value.saveOptions.finalNewline,
                    ),
                  ),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Ensure final newline on save'),
                value:
                    _value.saveOptions.finalNewline ==
                    FinalNewlinePolicy.ensure,
                onChanged: (enabled) => _apply(
                  _value.copyWith(
                    saveOptions: TextSaveOptions(
                      trailingWhitespace: _value.saveOptions.trailingWhitespace,
                      finalNewline: enabled
                          ? FinalNewlinePolicy.ensure
                          : FinalNewlinePolicy.preserve,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _section(theme, 'About'),
              // The notices of everything Planchette includes: Flutter's
              // NOTICES, plus the APK's Maven libraries on Android
              // (ghost_licenses).
              ListTile(
                key: const ValueKey('settings.licenses'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Open-source licenses'),
                subtitle: const Text(
                  'Public domain (Unlicense). The libraries, fonts and engine '
                  'it includes keep their own licenses.',
                ),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'Planchette',
                  applicationLegalese:
                      "Planchette's own code is public domain (Unlicense). It "
                      'includes third-party components that keep their own '
                      'licenses, listed here.',
                ),
              ),
              if (widget.settings.error case final error?)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _cancel, child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _section(ThemeData theme, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      label,
      style: theme.textTheme.labelMedium?.copyWith(
        color: theme.colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _fontMenu(ThemeData theme) {
    final stored = _value.fontFamily;
    final bundled = stored == null
        ? editorDefaultFont
        : BundledMonoFont.named(stored);
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text('Font', style: theme.textTheme.bodyMedium),
        ),
        Expanded(
          child: OutlinedButton.icon(
            key: const ValueKey('settings.font'),
            icon: const Icon(Icons.font_download_outlined),
            label: Text(
              bundled == editorDefaultFont
                  ? '${editorDefaultFont.displayName} (default)'
                  : bundled?.displayName ?? stored!,
              overflow: TextOverflow.ellipsis,
            ),
            onPressed: _pickFont,
          ),
        ),
      ],
    );
  }

  Future<void> _pickFont() async {
    final chosen = await showMonoFontPicker(
      context,
      current: _value.fontFamily ?? '',
      defaultFont: editorDefaultFont,
      fontSize: _value.fontSize.toDouble(),
      ligatures: _value.ligatures == EditorLigatures.on
          ? MonoLigatures.on
          : MonoLigatures.off,
    );
    if (chosen == null || !mounted) return;

    _apply(
      _value.copyWith(
        fontFamily: () => chosen.family.isEmpty ? null : chosen.family,
        ligatures: chosen.ligatures == MonoLigatures.on
            ? EditorLigatures.on
            : EditorLigatures.off,
      ),
    );
  }

  /// Whole steps only: sizes and widths are integers, and a step per value
  /// lets the keyboard arrows move one at a time.
  Widget _slider({
    required ThemeData theme,
    required String label,
    required int value,
    required int min,
    required int max,
    required ValueChanged<int> onChanged,
  }) => Row(
    children: [
      SizedBox(
        width: 64,
        child: Text(label, style: theme.textTheme.bodyMedium),
      ),
      Expanded(
        child: Slider(
          value: value.clamp(min, max).toDouble(),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: max - min,
          label: '$value',
          semanticFormatterCallback: (value) => '$label ${value.round()}',
          onChanged: (value) => onChanged(value.round()),
        ),
      ),
      SizedBox(
        width: 32,
        child: Text(
          '$value',
          textAlign: TextAlign.end,
          style: theme.textTheme.bodyMedium,
        ),
      ),
    ],
  );

  void _apply(AppSettings next) => unawaited(widget.settings.update(next));

  /// Restore the preview without replacing layout changes from another
  /// window or the View menu.
  void _cancel() {
    unawaited(
      widget.settings.update(
        _starting.copyWith(
          sidebarVisible: _value.sidebarVisible,
          sidebarWidth: _value.sidebarWidth,
        ),
      ),
    );
    Navigator.of(context).pop();
  }
}
