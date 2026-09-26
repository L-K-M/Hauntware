import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../compact/compact_pane_messages.dart';

/// The notice strip's sentence for a folder that could not be opened in
/// place (02 §2.5): which folder, and why.
String expandFailedText(
  AppLocalizations l10n,
  ({String name, RemoteFileException error})? failure,
) {
  if (failure == null) return '';
  final reason = compactRenameErrorText(l10n, failure.error);
  return l10n.paneNoticeExpandFailed(failure.name, reason);
}
