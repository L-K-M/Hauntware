import 'package:planchette_editor/planchette_editor.dart';

import '../l10n/app_localizations.dart';

/// Adapt the shared find and Go to Line bars to Poltergeist's localization
/// resources. The shared status row's strings are not overridden: the
/// editor hides that row and draws its own from the ARB file.
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
  @override
  String get wholeWords => l10n.editorWholeWordsTooltip;
  @override
  String get regularExpression => l10n.editorRegularExpressionTooltip;
  @override
  String get findPatternHint => l10n.editorFindPatternHint;
  @override
  String patternInvalid(String detail) => l10n.editorPatternInvalid(detail);
  @override
  String get patternTooSlow => l10n.editorPatternTooSlow;
  @override
  String get caseFoldLimited => l10n.editorCaseFoldLimited;
  @override
  String get goToLine => l10n.editorGoToLineTooltip;
  @override
  String get closeGoToLine => l10n.editorCloseGoToLineTooltip;
  @override
  String goToLineHint(int lines) => l10n.editorGoToLineHint(lines);
  @override
  String goToLineInvalid(int lines) => l10n.editorGoToLineInvalid(lines);
}
