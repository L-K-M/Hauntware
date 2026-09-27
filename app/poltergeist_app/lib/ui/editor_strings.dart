import 'package:planchette_editor/planchette_editor.dart';

import '../l10n/app_localizations.dart';

/// Adapt the shared search surface to Poltergeist's localization resources.
class PoltergeistEditorStrings extends EditorStrings {
  const PoltergeistEditorStrings(this.l10n);
  final AppLocalizations l10n;

  @override
  String get findHint => l10n.editorFindHint;
  @override
  String get matchCase => l10n.editorMatchCaseTooltip;
  @override
  String get previousMatch => l10n.editorPreviousMatchTooltip;
  @override
  String get nextMatch => l10n.editorNextMatchTooltip;
  @override
  String get closeSearch => l10n.editorCloseSearchTooltip;
  @override
  String get noMatches => l10n.editorNoMatches;
  @override
  String get showReplace => l10n.editorShowReplaceTooltip;
  @override
  String get replaceHint => l10n.editorReplaceHint;
  @override
  String get replace => l10n.editorReplaceLabel;
  @override
  String get replaceAll => l10n.editorReplaceAllLabel;
  @override
  String matchCount(int current, int total, {bool capped = false}) => capped
      ? l10n.editorMatchCountCapped(current, total)
      : l10n.editorMatchCount(current, total);
}
