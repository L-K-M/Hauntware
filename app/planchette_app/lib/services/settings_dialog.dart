import 'dart:async';

import 'package:flutter/material.dart';
import 'package:planchette_app/services/app_settings.dart';
import 'package:planchette_editor/planchette_editor.dart';

/// User-facing copy for the application shell.
///
/// The editor already takes an [EditorStrings] so a host can adapt it; the shell
/// had every label as an inline English literal, which made it the one surface
/// in the app a translation could not reach. Injecting this keeps that from
/// being true any longer, and costs a host nothing that does not care.
class ShellStrings {
  const ShellStrings();

  String get newDocument => 'New';
  String get openDocument => 'Open…';
  String get save => 'Save';
  String get saveAs => 'Save As…';
  String get closeTab => 'Close Tab';
  String get quit => 'Quit';
  String get settings => 'Settings…';
  String get undo => 'Undo';
  String get redo => 'Redo';
  String get cut => 'Cut';
  String get copy => 'Copy';
  String get paste => 'Paste';
  String get selectAll => 'Select All';
  String get find => 'Find…';
  String get replace => 'Replace…';
  String get findNext => 'Find Next';
  String get findPrevious => 'Find Previous';
  String get nextTab => 'Next Tab';
  String get previousTab => 'Previous Tab';
  String get file => 'File';
  String get edit => 'Edit';
  String get findMenu => 'Find';
  String get window => 'Window';
  String get settingsMenu => 'Settings';
  String get appName => 'Planchette';
  String get untitledHint => 'A place for your words.';
  String get dismissError => 'Dismiss error';
  String get closeTabTooltip => 'Close';
  String get newDocumentTitle => 'Start with a blank page';
  String get newDocumentAction => 'New document';
  String get openDocumentAction => 'Open…';
  String get saving => 'Saving';

  // The preferences dialog, so the shell's whole copy is in one place.
  String get settingsTitle => 'Settings';
  String get cancel => 'Cancel';
  String get done => 'Done';
  String get appearance => 'Appearance';
  String get textSize => 'Text';
  String get indentation => 'Indentation';
  String get system => 'System';
  String get light => 'Light';
  String get dark => 'Dark';
  String get size => 'Size';
  String get width => 'Width';
  String get indentWith => 'Indent with';
  String get spaces => 'Spaces';
  String get tabs => 'Tabs';
  String get tabWidthHint =>
      'A tab is one character wide, so width does not apply.';
}

/// Preferences: what the app looks like and how it indents.
///
/// Edits apply live rather than behind an OK button, so a font size can be seen
/// before it is committed. Cancel restores what was there when the dialog
/// opened, which is the one thing a live-preview dialog has to get right.
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.settings,
    required this.strings,
  });

  final SettingsController settings;
  final ShellStrings strings;

  /// Show the dialog and resolve once the user is done.
  static Future<void> show(
    BuildContext context, {
    required SettingsController settings,
    ShellStrings strings = const ShellStrings(),
  }) => showDialog<void>(
    context: context,
    builder: (context) => SettingsDialog(settings: settings, strings: strings),
  );

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  /// What was in force when the dialog opened, so Cancel has something to put
  /// back. A field initializer cannot read [widget], so it is filled in here.
  late final AppSettings _starting;

  AppSettings get _value => widget.settings.value;

  @override
  void initState() {
    super.initState();
    _starting = widget.settings.value;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.strings.settings),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _section(theme, 'Appearance'),
            _themeMode(theme),
            const SizedBox(height: 16),
            _section(theme, 'Text'),
            _fontSize(theme),
            const SizedBox(height: 16),
            _section(theme, 'Indentation'),
            _indentUnit(theme),
            _indentWidth(theme),
            if (_value.indent.usesTabs)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'A tab is one character wide, so width does not apply.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _cancel, child: Text(widget.strings.cancel)),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.strings.done),
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

  Widget _themeMode(ThemeData theme) => SegmentedButton<ThemeMode>(
    segments: const [
      ButtonSegment(value: ThemeMode.system, label: Text('System')),
      ButtonSegment(value: ThemeMode.light, label: Text('Light')),
      ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
    ],
    selected: {_value.themeMode},
    onSelectionChanged: (selection) =>
        _apply(_value.copyWith(themeMode: selection.first)),
  );

  /// A slider rather than a row of chips: a chip per size overflows a narrow
  /// dialog, and a slider also gives somewhere to drag when the exact size is
  /// not one of the round numbers.
  Widget _fontSize(ThemeData theme) => _slider(
    theme: theme,
    label: 'Size',
    value: _value.fontSize.toDouble(),
    min: AppSettings.minimumFontSize.toDouble(),
    max: AppSettings.maximumFontSize.toDouble(),
    onChanged: (size) => _apply(_value.copyWith(fontSize: size.round())),
  );

  Widget _indentUnit(ThemeData theme) => Row(
    children: [
      Expanded(child: Text('Indent with', style: theme.textTheme.bodyMedium)),
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('Spaces')),
          ButtonSegment(value: true, label: Text('Tabs')),
        ],
        selected: {_value.indent.usesTabs},
        onSelectionChanged: (selection) => _apply(
          _value.copyWith(
            indent: EditorIndent(
              usesTabs: selection.first,
              size: _value.indent.size,
            ),
          ),
        ),
      ),
    ],
  );

  Widget _indentWidth(ThemeData theme) => _slider(
    theme: theme,
    label: 'Width',
    value: _value.indent.size.toDouble().clamp(1, 16),
    min: 1,
    max: 16,
    enabled: !_value.indent.usesTabs,
    onChanged: (width) =>
        _apply(_value.copyWith(indent: EditorIndent(size: width.round()))),
  );

  Widget _slider({
    required ThemeData theme,
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    bool enabled = true,
  }) => Row(
    children: [
      SizedBox(
        width: 64,
        child: Text(label, style: theme.textTheme.bodyMedium),
      ),
      Expanded(
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          // A discrete step for tab width, continuous for font size, so a
          // fractional size is still reachable.
          divisions: label == 'Width' ? max.round() - min.round() : null,
          label: '${value.round()}',
          onChanged: enabled ? onChanged : null,
        ),
      ),
      SizedBox(
        width: 32,
        child: Text(
          '${value.round()}',
          textAlign: TextAlign.end,
          style: theme.textTheme.bodyMedium,
        ),
      ),
    ],
  );

  void _apply(AppSettings next) => unawaited(widget.settings.update(next));

  /// Put back what was in force when the dialog opened. A live-preview dialog
  /// that leaves a cancelled font size behind is worse than no dialog.
  void _cancel() {
    unawaited(widget.settings.update(_starting));
    Navigator.of(context).pop();
  }
}
