import 'package:flutter/widgets.dart' show BuildContext;
import 'package:planchette_editor/planchette_editor.dart';

import '../l10n/app_localizations.dart';

/// Poltergeist's shared-editor copy: the package catalog for every string
/// except the dirty marker, which this product words as "Unsaved edits".
class PoltergeistEditorStrings extends LocalizedEditorStrings {
  const PoltergeistEditorStrings(super.l10n, this.hostL10n);

  /// The app's own catalog, for the strings Poltergeist words differently.
  final AppLocalizations hostL10n;

  /// The editor strings for [context]: catalog-backed when the package
  /// delegate is installed, otherwise the shared English defaults.
  static EditorStrings of(BuildContext context) {
    final catalog = LocalizedEditorStrings.maybeOf(context);
    if (catalog == null) return const EditorStrings();
    return PoltergeistEditorStrings(catalog.l10n, AppLocalizations.of(context));
  }

  @override
  String get unsaved => hostL10n.editorStatusUnsaved;
}
