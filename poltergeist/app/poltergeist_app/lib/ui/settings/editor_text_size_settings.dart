import 'dart:async';

import 'package:flutter/material.dart';
import 'package:planchette_editor/planchette_editor.dart' show EditorTextSize;

import '../../l10n/app_localizations.dart';
import '../../services/application_error_reporter.dart';
import '../../services/settings_models.dart';
import '../top_toast.dart';

/// Settings → Appearance's built-in editor part: the text size every
/// editor window and route draws in, which View › Zoom steps too.
///
/// Writes through as the slider moves, so open editors resize under it.
class EditorTextSizeSection extends StatefulWidget {
  const EditorTextSizeSection({super.key, required this.model});

  final EditorTextSizeModel model;

  @override
  State<EditorTextSizeSection> createState() => _EditorTextSizeSectionState();
}

class _EditorTextSizeSectionState extends State<EditorTextSizeSection> {
  /// The size under the thumb while it moves. In the Settings window the
  /// model trails each write by a round trip to the app, so the thumb
  /// would otherwise jump back between frames.
  int? _dragging;

  Future<void> _write(int size) async {
    try {
      await widget.model.setTextSize(size);
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      if (!mounted) return;
      showTopToastIn(context, message: error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) {
        final size = _dragging ?? widget.model.value;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.editorTextSizeSection, style: theme.textTheme.titleSmall),
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
                      if (next == size) return;
                      setState(() => _dragging = next);
                      unawaited(_write(next));
                    },
                    onChangeEnd: (_) => setState(() => _dragging = null),
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
            Text(
              l10n.editorTextSizeHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }
}
