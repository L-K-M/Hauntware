import 'package:flutter/material.dart';

import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/third_party_bookmark_import_setup.dart';
import 'bookmark_import_dialog.dart';

const int _bytesPerMiB = 1024 * 1024;
const int _maxFileMiB = thirdPartyBookmarkImportMaxFileBytes ~/ _bytesPerMiB;
const int _maxTotalMiB = thirdPartyBookmarkImportMaxTotalBytes ~/ _bytesPerMiB;

Future<BookmarkImportDialogResult> showThirdPartyBookmarkImportDialog(
  BuildContext context, {
  required Future<ThirdPartyBookmarkPreviewTask> Function() startPreview,
  required ThirdPartyBookmarkFormat format,
  required List<ThirdPartyBookmarkImportFile> files,
  DateTime Function() clock = DateTime.now,
}) {
  ThirdPartyBookmarkPreviewTask? activeTask;
  var cancellationRequested = false;

  Future<BookmarkImportDialogPreview> load() async {
    cancellationRequested = false;
    final task = await startPreview();
    activeTask = task;
    if (cancellationRequested) task.cancel();

    try {
      final preview = await task.result;

      return BookmarkImportDialogPreview(
        rows: [
          for (final row in preview.rows)
            _dialogRow(row, showSourceName: files.length > 1),
        ],
      );
    } finally {
      if (identical(activeTask, task)) activeTask = null;
    }
  }

  void cancelLoad() {
    cancellationRequested = true;
    activeTask?.cancel();
  }

  return showBookmarkImportDialog(
    context,
    clock: clock,
    spec: BookmarkImportDialogSpec(
      title: (l10n) => l10n.bookmarkImportTitle(_localizedFormat(l10n, format)),
      sourceLabel: (l10n) => files.length == 1
          ? files.single.name
          : l10n.bookmarkImportFilesSelected(
              _localizedFormat(l10n, format),
              files.length,
            ),
      emptyMessage: (l10n) => l10n.bookmarkImportEmpty,
      failureMessage: (l10n, error) =>
          thirdPartyBookmarkImportFailureMessage(l10n, error, files, format),
      failureAction: BookmarkImportFailureAction.reselect,
      failureActionLabel: (l10n) => l10n.bookmarkImportChooseAnother,
      cancelLoad: cancelLoad,
      load: load,
    ),
  );
}

String thirdPartyBookmarkImportFailureMessage(
  AppLocalizations l10n,
  Object error,
  List<ThirdPartyBookmarkImportFile> files,
  ThirdPartyBookmarkFormat format,
) {
  if (error is! ThirdPartyBookmarkImportException) {
    return l10n.bookmarkImportReadFailed;
  }

  final sourceName =
      error.sourceName ??
      (files.length == 1 ? files.single.name : _localizedFormat(l10n, format));

  return switch (error.failure) {
    ThirdPartyBookmarkImportFailure.tooManyFiles =>
      l10n.bookmarkImportTooManyFiles(thirdPartyBookmarkImportMaxFiles),
    ThirdPartyBookmarkImportFailure.fileTooLarge =>
      l10n.bookmarkImportFileTooLarge(sourceName, _maxFileMiB),
    ThirdPartyBookmarkImportFailure.totalSizeExceeded =>
      l10n.bookmarkImportTotalSizeExceeded(_maxTotalMiB),
    ThirdPartyBookmarkImportFailure.invalidEncoding =>
      l10n.bookmarkImportInvalidEncoding(sourceName),
    ThirdPartyBookmarkImportFailure.unsafeXml => l10n.bookmarkImportUnsafeXml(
      sourceName,
    ),
    ThirdPartyBookmarkImportFailure.malformedSource =>
      l10n.bookmarkImportMalformedSource(sourceName),
    ThirdPartyBookmarkImportFailure.tooManyRows =>
      l10n.bookmarkImportTooManyRows(thirdPartyBookmarkImportMaxRows),
  };
}

BookmarkImportDialogRow _dialogRow(
  ThirdPartyBookmarkImportRow row, {
  required bool showSourceName,
}) {
  final keyPath = row.identityFilePath;

  return BookmarkImportDialogRow(
    id: row.id,
    label: row.label,
    endpoint: row.endpoint,
    username: row.username,
    authentication: (l10n) => switch (row.authMethod) {
      AuthMethod.agent => l10n.sshImportAuthAgent,
      AuthMethod.password => l10n.bookmarkImportAuthPassword,
      AuthMethod.privateKey => l10n.sshImportAuthKey(keyPath ?? ''),
    },
    authenticationStyle: row.authMethod == AuthMethod.privateKey
        ? BookmarkImportTextStyle.monospace
        : BookmarkImportTextStyle.plain,
    details: [
      (l10n) => l10n.bookmarkImportStartFolder(row.remotePath),
      if (showSourceName)
        (l10n) => l10n.bookmarkImportSourceFile(row.sourceName),
    ],
    notes: _notes(row),
    importable: row.importable,
    importByDefault: row.importByDefault,
    toBookmark: (now) => row.toBookmark(now: now),
  );
}

List<BookmarkImportText> _notes(ThirdPartyBookmarkImportRow row) {
  final notes = <BookmarkImportText>[];

  if (row.matchesExistingBookmark) {
    notes.add(
      (l10n) =>
          l10n.sshImportDuplicateExisting(row.existingBookmarkLabel ?? ''),
    );
  } else if (row.matchesEarlierImportRow) {
    notes.add(
      (l10n) => l10n.sshImportDuplicateEarlier(row.earlierImportRowLabel ?? ''),
    );
  }

  for (final issue in row.issues) {
    notes.add((l10n) => _issueText(l10n, row, issue));
  }

  return List.unmodifiable(notes);
}

String _issueText(
  AppLocalizations l10n,
  ThirdPartyBookmarkImportRow row,
  ThirdPartyBookmarkImportIssue issue,
) => switch (issue) {
  ThirdPartyBookmarkImportIssue.unsupportedProtocol =>
    row.protocolVerdict == ThirdPartyBookmarkProtocolVerdict.unknown
        ? l10n.bookmarkImportUnknownProtocol
        : l10n.bookmarkImportUnsupportedProtocol(row.protocol),
  ThirdPartyBookmarkImportIssue.invalidPort => l10n.sshImportLimitInvalidPort,
  ThirdPartyBookmarkImportIssue.missingHost => l10n.bookmarkImportMissingHost,
  ThirdPartyBookmarkImportIssue.credentialsNotImported =>
    l10n.bookmarkImportCredentialsNotImported,
  ThirdPartyBookmarkImportIssue.unsupportedKeyFormat =>
    l10n.bookmarkImportUnsupportedKeyFormat,
  ThirdPartyBookmarkImportIssue.routeNotImported =>
    l10n.bookmarkImportRouteNotImported,
  ThirdPartyBookmarkImportIssue.invalidRemotePath =>
    l10n.bookmarkImportInvalidRemotePath,
  ThirdPartyBookmarkImportIssue.fieldTooLong => l10n.bookmarkImportFieldTooLong,
  ThirdPartyBookmarkImportIssue.invalidFieldValue =>
    l10n.bookmarkImportInvalidFieldValue,
  ThirdPartyBookmarkImportIssue.persistedOutputLimitExceeded =>
    l10n.bookmarkImportPersistedOutputLimitExceeded,
};

String _localizedFormat(
  AppLocalizations l10n,
  ThirdPartyBookmarkFormat format,
) => switch (format) {
  ThirdPartyBookmarkFormat.fileZilla => l10n.bookmarkImportFileZilla,
  ThirdPartyBookmarkFormat.winScp => l10n.bookmarkImportWinScp,
  ThirdPartyBookmarkFormat.cyberduck => l10n.bookmarkImportCyberduck,
};
