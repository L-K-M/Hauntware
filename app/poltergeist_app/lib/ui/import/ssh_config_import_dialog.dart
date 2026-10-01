import 'package:flutter/material.dart';

import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import 'bookmark_import_dialog.dart';

/// Shows ssh_config through D22's source-neutral preview and selection flow.
Future<List<Bookmark>?> showSshConfigImportDialog(
  BuildContext context, {
  required SshConfigImportService service,
  required String configPath,
  List<Bookmark> existingBookmarks = const [],
  DateTime Function() clock = DateTime.now,
}) async {
  final result = await showBookmarkImportDialog(
    context,
    clock: clock,
    spec: BookmarkImportDialogSpec(
      title: (l10n) => l10n.sshImportTitle,
      sourceLabel: (_) => configPath,
      emptyMessage: (l10n) => l10n.sshImportEmpty(configPath),
      failureMessage: (l10n, _) => l10n.sshImportLoadFailed(configPath),
      noticeHeading: (l10n) => l10n.sshImportUnresolvedIncludes,
      load: () async {
        final preview = await service.loadPreview(
          configPath: configPath,
          existingBookmarks: existingBookmarks,
        );

        return BookmarkImportDialogPreview(
          rows: [for (final row in preview.rows) _dialogRow(row)],
          notices: [
            for (final notice in preview.notices)
              (l10n) => _includeNotice(l10n, notice),
          ],
        );
      },
    ),
  );

  if (result.exit != BookmarkImportDialogExit.imported) return null;

  return result.bookmarks;
}

BookmarkImportDialogRow _dialogRow(SshConfigImportRow row) {
  final keyPath = row.host.identityFile;

  return BookmarkImportDialogRow(
    id: row.id,
    label: row.host.alias,
    endpoint: '${row.host.effectiveHost}:${row.port}',
    username: row.username,
    authentication: keyPath == null || keyPath.trim().isEmpty
        ? (l10n) => l10n.sshImportAuthAgent
        : (l10n) => l10n.sshImportAuthKey(keyPath),
    authenticationStyle: keyPath != null && keyPath.trim().isNotEmpty
        ? BookmarkImportTextStyle.monospace
        : BookmarkImportTextStyle.plain,
    notes: _notes(row),
    importable: row.importable,
    importByDefault: row.importByDefault,
    toBookmark: (now) => row.toBookmark(now: now),
  );
}

List<BookmarkImportText> _notes(SshConfigImportRow row) {
  final notes = <BookmarkImportText>[];

  if (row.matchesExistingBookmark) {
    notes.add(
      (l10n) =>
          l10n.sshImportDuplicateExisting(row.existingBookmarkLabel ?? ''),
    );
  } else if (row.matchesEarlierImportRow) {
    notes.add(
      (l10n) => l10n.sshImportDuplicateEarlier(row.earlierImportRowAlias ?? ''),
    );
  }

  for (final limitation in row.limitations) {
    notes.add((l10n) => _limitationText(l10n, limitation));
  }

  return List.unmodifiable(notes);
}

String _limitationText(
  AppLocalizations l10n,
  SshConfigImportLimitation limitation,
) => switch (limitation) {
  SshConfigImportLimitation.proxyJump => l10n.sshImportLimitProxyJump,
  SshConfigImportLimitation.proxyCommand => l10n.sshImportLimitProxyCommand,
  SshConfigImportLimitation.matchBlock => l10n.sshImportLimitMatch,
  SshConfigImportLimitation.hostInclude => l10n.sshImportLimitHostInclude,
  SshConfigImportLimitation.invalidPort => l10n.sshImportLimitInvalidPort,
  SshConfigImportLimitation.wildcardDefaults =>
    l10n.sshImportLimitWildcardDefaults,
};

String _includeNotice(
  AppLocalizations l10n,
  SshConfigUnresolvedInclude notice,
) => switch (notice.note) {
  SshConfigIncludeNote.cycle => l10n.sshImportNoteCycle(notice.path),
  SshConfigIncludeNote.depthExceeded => l10n.sshImportNoteDepth(notice.path),
  SshConfigIncludeNote.unreadable => l10n.sshImportNoteUnreadable(notice.path),
};
