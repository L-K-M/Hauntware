import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/application_error_reporter.dart';
import '../../services/registered_command.dart';
import '../../services/third_party_bookmark_import_setup.dart';
import 'bookmark_import_dialog.dart';
import 'third_party_bookmark_import_dialog.dart';

const kThirdPartyBookmarkImportCommandId = 'favorite.importThirdParty';

RegisteredCommand buildThirdPartyBookmarkImportCommand({
  required ThirdPartyBookmarkImportSetup setup,
  required bool Function() enabled,
}) {
  return RegisteredCommand(
    id: kThirdPartyBookmarkImportCommandId,
    scope: CommandScope.app,
    label: (l10n) => l10n.bookmarkImportCommandLabel,
    icon: Icons.move_to_inbox_outlined,
    enabled: enabled,
    disabledReason: (l10n) => l10n.commandDisabledBusy,
    run: (context) async {
      final format = await showThirdPartyBookmarkSourceChooser(context);
      if (format == null || !context.mounted) return;
      await _runSource(context, setup, format);
    },
    submenuItems: (_) => [
      for (final format in ThirdPartyBookmarkFormat.values)
        _sourceCommand(setup, enabled, format),
    ],
    menuPlacement: const CommandMenuPlacement(
      menu: AppMenuId.server,
      order: 42,
      group: 2,
    ),
  );
}

RegisteredCommand _sourceCommand(
  ThirdPartyBookmarkImportSetup setup,
  bool Function() enabled,
  ThirdPartyBookmarkFormat format,
) {
  return RegisteredCommand(
    id: '$kThirdPartyBookmarkImportCommandId:${format.name}',
    scope: CommandScope.app,
    label: (l10n) => _sourceLabel(l10n, format),
    enabled: enabled,
    disabledReason: (l10n) => l10n.commandDisabledBusy,
    run: (context) => _runSource(context, setup, format),
  );
}

Future<ThirdPartyBookmarkFormat?> showThirdPartyBookmarkSourceChooser(
  BuildContext context,
) {
  final l10n = AppLocalizations.of(context);

  return showDialog<ThirdPartyBookmarkFormat>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: Text(l10n.bookmarkImportChooserTitle),
      children: [
        for (final format in ThirdPartyBookmarkFormat.values)
          SimpleDialogOption(
            key: ValueKey('bookmarkImport.source.${format.name}'),
            onPressed: () => Navigator.pop(dialogContext, format),
            child: Text(_sourceLabel(l10n, format)),
          ),
      ],
    ),
  );
}

Future<void> _runSource(
  BuildContext context,
  ThirdPartyBookmarkImportSetup setup,
  ThirdPartyBookmarkFormat format,
) async {
  while (true) {
    if (!context.mounted) return;

    final files = await _pickFiles(context, setup, format);
    if (!context.mounted || files == null || files.isEmpty) return;

    final List<Bookmark> existing;
    try {
      existing = await setup.bookmarks.load();
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      if (!context.mounted) return;
      _notify(
        context,
        AppLocalizations.of(context).sshImportFavoritesLoadFailed,
      );
      return;
    }
    if (!context.mounted) return;

    final result = await showThirdPartyBookmarkImportDialog(
      context,
      format: format,
      files: files,
      startPreview: () => setup.startPreview(
        format: format,
        files: files,
        existingBookmarks: existing,
      ),
    );
    if (!context.mounted) return;
    if (result.exit == BookmarkImportDialogExit.reselect) continue;
    if (result.exit != BookmarkImportDialogExit.imported) return;

    await _persist(context, setup.bookmarks, result.bookmarks);
    return;
  }
}

Future<List<ThirdPartyBookmarkImportFile>?> _pickFiles(
  BuildContext context,
  ThirdPartyBookmarkImportSetup setup,
  ThirdPartyBookmarkFormat format,
) async {
  while (context.mounted) {
    try {
      return await setup.pickFiles(format);
    } on ThirdPartyBookmarkImportException catch (error) {
      if (!context.mounted) return null;

      final choice = await _showPickerFailure(context, error, format);
      if (choice == _PickerFailureChoice.reselect) continue;

      return null;
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      if (!context.mounted) return null;
      _notify(context, AppLocalizations.of(context).bookmarkImportPickFailed);
      return null;
    }
  }

  return null;
}

enum _PickerFailureChoice { cancel, reselect }

Future<_PickerFailureChoice?> _showPickerFailure(
  BuildContext context,
  ThirdPartyBookmarkImportException error,
  ThirdPartyBookmarkFormat format,
) {
  final l10n = AppLocalizations.of(context);

  return showDialog<_PickerFailureChoice>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.bookmarkImportTitle(_sourceLabel(l10n, format))),
      content: Text(
        thirdPartyBookmarkImportFailureMessage(l10n, error, const [], format),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(dialogContext, _PickerFailureChoice.cancel),
          child: Text(l10n.sshImportCancel),
        ),
        FilledButton.tonal(
          onPressed: () =>
              Navigator.pop(dialogContext, _PickerFailureChoice.reselect),
          child: Text(l10n.bookmarkImportChooseAnother),
        ),
      ],
    ),
  );
}

Future<void> _persist(
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
    _notify(context, AppLocalizations.of(context).sshImportFavoritesSaveFailed);
    return;
  }
  if (!context.mounted) return;

  _notify(
    context,
    AppLocalizations.of(context).sshImportImported(imported.length),
  );
}

String _sourceLabel(AppLocalizations l10n, ThirdPartyBookmarkFormat format) =>
    switch (format) {
      ThirdPartyBookmarkFormat.fileZilla => l10n.bookmarkImportFileZilla,
      ThirdPartyBookmarkFormat.winScp => l10n.bookmarkImportWinScp,
      ThirdPartyBookmarkFormat.cyberduck => l10n.bookmarkImportCyberduck,
    };

void _notify(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));
}
