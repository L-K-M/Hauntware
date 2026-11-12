import 'package:flutter/material.dart';

/// The answer to a document close question.
///
/// [save] keeps the work and closes; [dontSave] drops it; [cancel] leaves
/// the document open.
enum GhostCloseChoice { save, dontSave, cancel }

/// Asks whether to save unsaved changes before a document closes.
///
/// Save is the safe action, so it takes autofocus (02 §UX: "The safe action
/// is the default button"). A dismissal answers null, which callers treat as
/// [GhostCloseChoice.cancel]. Labels are injected so each host keeps its own
/// localized copy; the defaults are the family's English wording. A host
/// that cannot save while reloading can hide Save with [showSave].
Future<GhostCloseChoice?> showGhostCloseDialog(
  BuildContext context, {
  required String title,
  required String body,
  String saveLabel = 'Save',
  String dontSaveLabel = 'Don’t save',
  String cancelLabel = 'Cancel',
  bool showSave = true,
}) {
  return showDialog<GhostCloseChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, GhostCloseChoice.dontSave),
          child: Text(dontSaveLabel),
        ),
        TextButton(
          autofocus: !showSave,
          onPressed: () => Navigator.pop(context, GhostCloseChoice.cancel),
          child: Text(cancelLabel),
        ),
        if (showSave)
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, GhostCloseChoice.save),
            child: Text(saveLabel),
          ),
      ],
    ),
  );
}
