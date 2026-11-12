import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_fonts/ghost_fonts.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:planchette_editor/planchette_editor.dart'
    show EditorLigatures, EditorTextSize, editorDefaultFont;

import '../../controllers/editor_display.dart';
import '../../l10n/app_localizations.dart';

/// Settings → Appearance's file editor section (03 §8.5): the font family,
/// whether its ligatures draw, and the text size, written through
/// [EditorDisplaySettings] as each control changes. Every file editor
/// redraws at once.
class EditorSettingsSection extends StatefulWidget {
  const EditorSettingsSection({super.key, required this.model});

  final EditorDisplaySettings model;

  @override
  State<EditorSettingsSection> createState() => _EditorSettingsSectionState();
}

class _EditorSettingsSectionState extends State<EditorSettingsSection> {
  /// What the rows show from a choice until the model shows it. In the
  /// settings window the model trails each write by a round trip to the
  /// app, so the rows would otherwise flick back.
  EditorDisplay? _pending;

  /// The size under the thumb from a drag until the model shows it.
  int? _dragging;

  /// Counts [_write] calls: only the newest may hand the rows back or
  /// report a failure, since each write carries every earlier one.
  int _writes = 0;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_modelChanged);
  }

  @override
  void didUpdateWidget(EditorSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.model, widget.model)) return;
    oldWidget.model.removeListener(_modelChanged);
    widget.model.addListener(_modelChanged);
  }

  @override
  void dispose() {
    widget.model.removeListener(_modelChanged);
    super.dispose();
  }

  void _modelChanged() {
    if (_pending == null || widget.model.value != _pending) return;
    setState(() {
      _pending = null;
      if (_dragging == widget.model.value.textSize) _dragging = null;
    });
  }

  Future<void> _write(EditorDisplay display) async {
    if (display == (_pending ?? widget.model.value)) return;

    final l10n = AppLocalizations.of(context);
    final overlay = Overlay.of(context, rootOverlay: true);
    final write = ++_writes;
    setState(() => _pending = display);
    try {
      await widget.model.setEditorDisplay(display);
    } on EditorDisplayNotSavedException catch (error) {
      debugPrint('$error');
      if (!mounted || write != _writes) return;
      // Show what the editors draw in: the model keeps a change it could
      // not save, and the next write carries it.
      setState(() => _pending = null);
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.settingsEditorDisplayNotSaved);
      }
    } on Exception catch (error) {
      debugPrint('$error');
      if (!mounted || write != _writes) return;
      setState(() => _pending = null);
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.settingsEditorDisplayNotChanged);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) {
        final display = _pending ?? widget.model.value;
        final size = _dragging ?? display.textSize;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.editorTextSizeSection,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Row(
              children: [
                Text(l10n.editorFontLabel),
                const SizedBox(width: 16),
                Expanded(child: _menu(l10n, display)),
              ],
            ),
            SwitchListTile(
              key: const ValueKey('editor.ligatures'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.editorLigaturesLabel),
              subtitle: Text(l10n.editorLigaturesSubtitle),
              value: display.ligatures == EditorLigatures.on,
              onChanged: (on) => unawaited(
                _write(
                  display.copyWith(
                    ligatures: on ? EditorLigatures.on : EditorLigatures.off,
                  ),
                ),
              ),
            ),
            Row(
              children: [
                Text(l10n.editorTextSizeLabel),
                Expanded(
                  child: Slider(
                    key: const ValueKey('editor.textSize'),
                    min: EditorTextSize.minimum.toDouble(),
                    max: EditorTextSize.maximum.toDouble(),
                    divisions: EditorTextSize.maximum - EditorTextSize.minimum,
                    value: size.toDouble(),
                    label: l10n.editorTextSizeValue(size),
                    semanticFormatterCallback: (value) =>
                        l10n.editorTextSizeValue(value.round()),
                    onChanged: (value) {
                      final next = value.round();
                      if (next == display.textSize) return;
                      setState(() => _dragging = next);
                      unawaited(_write(display.copyWith(textSize: next)));
                    },
                    onChangeEnd: (_) {
                      if (_dragging == widget.model.value.textSize) {
                        setState(() => _dragging = null);
                      }
                    },
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: Text(
                    l10n.editorTextSizeValue(size),
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _menu(AppLocalizations l10n, EditorDisplay display) {
    final chosen = display.chosenFamily;
    final bundled = chosen == null
        ? editorDefaultFont
        : BundledMonoFont.named(chosen);
    return OutlinedButton.icon(
      key: const ValueKey('editor.font'),
      icon: const Icon(Icons.font_download_outlined),
      label: Text(
        bundled == editorDefaultFont
            ? l10n.editorFontDefault(editorDefaultFont.displayName)
            : bundled?.displayName ?? chosen!,
        overflow: TextOverflow.ellipsis,
      ),
      onPressed: () => _pickFont(l10n, display),
    );
  }

  Future<void> _pickFont(AppLocalizations l10n, EditorDisplay display) async {
    final chosen = await showMonoFontPicker(
      context,
      current: display.chosenFamily ?? '',
      defaultFont: editorDefaultFont,
      fontSize: display.textSize.toDouble(),
      ligatures: display.ligatures == EditorLigatures.on
          ? MonoLigatures.on
          : MonoLigatures.off,
      labels: MonoFontPickerLabels(
        title: l10n.editorFontPickerTitle,
        search: l10n.editorFontPickerSearch,
        included: l10n.editorFontPickerIncluded,
        installed: l10n.editorFontPickerInstalled,
        empty: l10n.editorFontPickerEmpty,
        ligatures: l10n.editorLigaturesLabel,
        apply: l10n.editorFontPickerUse,
        cancel: l10n.editorDialogCancel,
        defaultLabel: l10n.editorFontPickerDefault,
        monospaceOnly: l10n.editorFontPickerMonospace,
        preview: l10n.previewPanelLabel,
        noLigatures: l10n.editorFontPickerNoLigatures,
      ),
    );
    if (chosen == null || !mounted) return;

    unawaited(
      _write(
        (_pending ?? widget.model.value).copyWith(
          family: chosen.family,
          ligatures: chosen.ligatures == MonoLigatures.on
              ? EditorLigatures.on
              : EditorLigatures.off,
        ),
      ),
    );
  }
}
