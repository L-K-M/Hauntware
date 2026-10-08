import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/application_error_reporter.dart';

/// Saves the bookmarks an import dialog returned and reports the outcome:
/// the imported count, or the save failure, which also goes to the error
/// reporter. An empty import saves and says nothing. The ssh_config and
/// third-party import commands both end here.
///
/// The save runs even when [context] has gone by the time it is called;
/// only the notices need it mounted.
Future<void> saveImportedBookmarks(
  BuildContext context,
  BookmarkRepository bookmarks,
  List<Bookmark> imported,
) async {
  if (imported.isEmpty) return;

  try {
    await bookmarks.upsertAll(imported);
  } on Object catch (error, stackTrace) {
    ApplicationErrorReporter().report(error, stackTrace);
    if (!context.mounted) return;
    showImportNotice(
      context,
      AppLocalizations.of(context).sshImportFavoritesSaveFailed,
    );
    return;
  }
  if (!context.mounted) return;

  showImportNotice(
    context,
    AppLocalizations.of(context).sshImportImported(imported.length),
  );
}

/// An import command's outcome, as a snackbar when the window has one.
void showImportNotice(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));
}
