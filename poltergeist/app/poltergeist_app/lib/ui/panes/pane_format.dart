import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:ghost_ui/ghost_ui.dart';
import 'package:poltergeist_core/poltergeist_core.dart'
    show RemoteFileEntry, RemoteFileType;

import '../../l10n/app_localizations.dart';

/// Presentation formatting for pane rows (02 §2.3's rendering rules).
/// The implementations moved to `package:ghost_ui` (`ghost_file_format.dart`,
/// `ghost_file_kinds.dart`); this file keeps the pane vocabulary so the
/// listing's other surfaces — the inspector, previews, sync tables — keep
/// their names, and owns the two projections nothing else can do: the
/// app's `RemoteFileEntry` onto the shared [GhostFileItem], and its ARB
/// strings onto [GhostFileRowStrings].

/// The shared "no value" glyph (02 §2.3's unevaluated dash) for surfaces
/// beyond the row formatter — the Get Info inspector renders absent VFS
/// metadata with the same dash the listing uses.
const paneUnevaluated = ghostUnevaluated;

/// The neutral item the shared file rows render, projected from the
/// app's wire entry: only presentation data crosses — the decoded name,
/// the node type, and the optional size/modified metadata. The explicit
/// switch keeps a future [RemoteFileType] a compile error here, not a
/// silently misclassified row.
GhostFileItem paneFileItem(RemoteFileEntry entry) => GhostFileItem(
  name: entry.name,
  type: switch (entry.type) {
    RemoteFileType.file => GhostFileNodeType.file,
    RemoteFileType.directory => GhostFileNodeType.directory,
    RemoteFileType.symbolicLink => GhostFileNodeType.symbolicLink,
    RemoteFileType.other => GhostFileNodeType.other,
  },
  size: entry.size,
  modifiedAt: entry.modifiedAt,
);

/// The row strings the shared widgets need, from this app's ARB
/// contract — the desktop [GhostFileRow] and the compact
/// [GhostFileCompactRow] read the same bag, so the two surfaces cannot
/// drift in what they announce.
GhostFileRowStrings paneRowStrings(AppLocalizations l10n) =>
    GhostFileRowStrings(
      kindLabel: (type) => switch (type) {
        GhostFileNodeType.file => l10n.paneRowKindFile,
        GhostFileNodeType.directory => l10n.paneRowKindDirectory,
        GhostFileNodeType.symbolicLink => l10n.paneRowKindSymbolicLink,
        GhostFileNodeType.other => l10n.paneRowKindOther,
      },
      semanticsLabel: l10n.paneRowSemantics,
      flaggedSemanticsLabel: l10n.paneRowSemanticsFlagged,
      flaggedTooltip: l10n.paneFlaggedNameTooltip,
      renameLabel: l10n.fileRenameLabel,
      expandLabel: l10n.paneRowExpand,
      collapseLabel: l10n.paneRowCollapse,
      todayText: l10n.paneDateToday,
      yesterdayText: l10n.paneDateYesterday,
      folderLabel: l10n.compactRowFolder,
      linkLabel: l10n.compactRowLink,
      detailsText: l10n.compactRowDetails,
      actionsTooltip: l10n.compactRowActions,
    );

/// Decimal size for macOS/Linux, binary for Windows — the platform file
/// managers' convention (02 §2.3). The Linux decimal/binary preference
/// setting lands with the settings slice.
String formatPaneSize(int? bytes, {required TargetPlatform platform}) =>
    ghostFormatFileSize(bytes, platform: platform);

/// Modified-time text: relative for today/yesterday, absolute otherwise
/// (02 §2.3). Links and unevaluated sizes carry null metadata — the dash.
String formatPaneModified(
  DateTime? modified, {
  required DateTime now,
  required String localeName,
  required String Function(String time) today,
  required String Function(String time) yesterday,
}) => ghostFormatFileModified(
  modified,
  now: now,
  localeName: localeName,
  today: today,
  yesterday: yesterday,
);

/// The `ls -l` symbolic rendering of a POSIX mode's permission bits
/// (02 §2.6's read-only rwx display): nine positions — user, group,
/// other — with suid/sgid/sticky folded into the execute slots the
/// standard way (s/S, s/S, t/T).
String formatPosixModeSymbolic(int mode) => ghostFormatPosixModeSymbolic(mode);

/// The mode's permission bits as four-digit octal (02 §2.6's octal
/// display): 0755, 0644, 4755 — the leading digit carries suid/sgid/
/// sticky, so nothing the symbolic render folded into its slots is lost.
String formatPosixModeOctal(int mode) => ghostFormatPosixModeOctal(mode);

/// The listing's kind-glyph families (D32 §6, coloured by D34's family
/// hues in `kind_glyph.dart`). A glyph is a sighted-user hint only: the
/// announced kind stays the entry's file type (02 §13), so a wrong guess
/// from an extension never misleads assistive tech.
typedef PaneKindCategory = GhostFileKind;

/// The kind-glyph family for [entry]: its file type first (folders and
/// links are never guessed from a name), then the lowercase extension
/// after the last dot — a leading dot is part of a dotfile's stem, so
/// `.bashrc` has no extension and reads as a generic file.
PaneKindCategory paneKindCategory(RemoteFileEntry entry) =>
    ghostFileKind(paneFileItem(entry));
