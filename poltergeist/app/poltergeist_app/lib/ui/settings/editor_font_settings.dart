import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_fonts/ghost_fonts.dart';
import 'package:planchette_editor/planchette_editor.dart'
    show EditorLigatures, EditorTextSize, editorDefaultFont;

import '../../l10n/app_localizations.dart';
import '../../services/application_error_reporter.dart';
import '../../services/editor_font.dart';
import '../../services/settings_models.dart';
import '../top_toast.dart';

/// Settings → Appearance's built-in editor font, under the text size: the
/// included fonts and whether their ligatures draw. Every editor window,
/// route and compare view redraws as it changes.
class EditorFontSection extends StatefulWidget {
  const EditorFontSection({super.key, required this.model, this.textSize});

  final EditorFontModel model;
  final EditorTextSizeModel? textSize;

  @override
  State<EditorFontSection> createState() => _EditorFontSectionState();
}

class _EditorFontSectionState extends State<EditorFontSection> {
  /// What the rows show from a choice until the model shows it. In the
  /// Settings window the model trails each write by a round trip to the
  /// app, so the rows would otherwise flick back.
  EditorFont? _pending;

  /// Counts [_write] calls: only the newest may hand the rows back or
  /// report a failure, since each write carries every earlier one.
  int _writes = 0;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_modelChanged);
  }

  @override
  void didUpdateWidget(EditorFontSection oldWidget) {
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
    setState(() => _pending = null);
  }

  Future<void> _write(EditorFont font) async {
    // The font already shown: the model would not move, so nothing would
    // clear [_pending].
    if (font == (_pending ?? widget.model.value)) return;

    final write = ++_writes;
    setState(() => _pending = font);
    try {
      await widget.model.setFont(font);
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      if (!mounted || write != _writes) return;
      // Show what the editors draw in: the model keeps a change it could
      // not save, and the next write carries it.
      setState(() => _pending = null);
      showTopToastIn(context, message: error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) {
        final font = _pending ?? widget.model.value;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Row(
              children: [
                Text(l10n.editorFontLabel),
                const SizedBox(width: 16),
                Expanded(child: _menu(l10n, font)),
              ],
            ),
            SwitchListTile(
              key: const ValueKey('editor.ligatures'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.editorLigaturesLabel),
              subtitle: Text(l10n.editorLigaturesSubtitle),
              value: font.ligatures == EditorLigatures.on,
              onChanged: (on) => unawaited(
                _write(
                  font.copyWith(
                    ligatures: on ? EditorLigatures.on : EditorLigatures.off,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _menu(AppLocalizations l10n, EditorFont font) {
    final chosen = font.chosenFamily;
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
      onPressed: () => _pickFont(l10n, font),
    );
  }

  Future<void> _pickFont(AppLocalizations l10n, EditorFont font) async {
    final chosen = await showMonoFontPicker(
      context,
      current: font.chosenFamily ?? '',
      defaultFont: editorDefaultFont,
      fontSize: (widget.textSize?.value ?? EditorTextSize.standard).toDouble(),
      ligatures: font.ligatures == EditorLigatures.on
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
        font.copyWith(
          family: chosen.family,
          ligatures: chosen.ligatures == MonoLigatures.on
              ? EditorLigatures.on
              : EditorLigatures.off,
        ),
      ),
    );
  }
}
