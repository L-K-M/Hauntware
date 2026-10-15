import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_fonts/ghost_fonts.dart' show BundledMonoFont;
import 'package:planchette_editor/planchette_editor.dart'
    show EditorLigatures, editorDefaultFont;

import '../../l10n/app_localizations.dart';
import '../../services/application_error_reporter.dart';
import '../../services/editor_font.dart';
import '../../services/settings_models.dart';
import '../top_toast.dart';

/// Settings → Appearance's built-in editor font, under the text size: the
/// included fonts and whether their ligatures draw. Every editor window,
/// route and compare view redraws as it changes.
class EditorFontSection extends StatefulWidget {
  const EditorFontSection({super.key, required this.model});

  final EditorFontModel model;

  @override
  State<EditorFontSection> createState() => _EditorFontSectionState();
}

class _EditorFontSectionState extends State<EditorFontSection> {
  /// The menu's value for the editor's default: storing no family keeps
  /// editors on the default should it ever change.
  static const _standard = '';

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

  /// The included fonts, each drawn in its own face, the editor's default
  /// marked. A family stored some other way leads the list, so opening it
  /// changes nothing.
  Widget _menu(AppLocalizations l10n, EditorFont font) {
    final chosen = font.chosenFamily;
    final bundled = chosen == null
        ? editorDefaultFont
        : BundledMonoFont.named(chosen);
    final selected = switch (bundled) {
      null => chosen!,
      editorDefaultFont => _standard,
      final named => named.displayName,
    };
    return DropdownButton<String>(
      key: const ValueKey('editor.font'),
      isExpanded: true,
      value: selected,
      items: [
        if (bundled == null)
          DropdownMenuItem(value: chosen, child: Text(chosen!)),
        for (final option in BundledMonoFont.values)
          DropdownMenuItem(
            value: option == editorDefaultFont ? _standard : option.displayName,
            child: Text(
              option == editorDefaultFont
                  ? l10n.editorFontDefault(option.displayName)
                  : option.displayName,
              style: TextStyle(fontFamily: option.family),
            ),
          ),
      ],
      onChanged: (family) {
        if (family == null) return;
        unawaited(_write(font.copyWith(family: family)));
      },
    );
  }
}
