import 'package:flutter/material.dart';

import 'family_hues.dart';
import 'ghost_file_item.dart';

/// The listing's kind-glyph families (Poltergeist D32 §6, coloured by
/// D34's family hues). A glyph is a sighted-user hint only: the
/// announced kind stays the entry's file type (02 §13), so a wrong
/// guess from an extension never misleads assistive tech.
///
/// Ported from Poltergeist's `lib/ui/panes/pane_format.dart`
/// (`PaneKindCategory`, extension tables, `paneKindCategory`) and
/// `lib/ui/panes/kind_glyph.dart` (`kindGlyph`, `kindIcon`) so the
/// classifier and glyph/hue table stay identical across the apps.
enum GhostFileKind {
  folder,
  link,
  image,
  document,
  code,
  archive,
  pdf,
  audio,
  video,
  other,
}

// Extension families, lowercase, one space-separated table per family —
// machine data the classifier splits once, never rendered.
const _imageExtensions =
    'png jpg jpeg gif webp bmp tif tiff heic heif svg ico avif psd raw';
const _documentExtensions =
    'txt md markdown rst log csv tsv rtf doc docx odt pages xls xlsx ods '
    'numbers ppt pptx odp epub';
const _codeExtensions =
    'json yaml yml toml xml html htm css scss js mjs ts jsx tsx dart py rb '
    'go rs java kt swift c h cc cpp hpp';
const _scriptExtensions =
    'm mm cs php sh bash zsh fish ps1 bat sql ini conf cfg env lock';
const _archiveExtensions =
    'zip tar gz tgz bz2 xz 7z rar zst lz4 dmg iso deb rpm pkg jar apk';
const _audioExtensions = 'mp3 wav flac aac ogg m4a opus';
const _videoExtensions = 'mp4 mov mkv avi webm m4v wmv mpg';

Set<String> _extensionSet(List<String> tables) => {
  for (final table in tables) ...table.split(' '),
};

final _kindByExtension = <String, GhostFileKind>{
  for (final ext in _extensionSet([_imageExtensions])) ext: GhostFileKind.image,
  for (final ext in _extensionSet([_documentExtensions]))
    ext: GhostFileKind.document,
  for (final ext in _extensionSet([_codeExtensions, _scriptExtensions]))
    ext: GhostFileKind.code,
  for (final ext in _extensionSet([_archiveExtensions]))
    ext: GhostFileKind.archive,
  for (final ext in _extensionSet([_audioExtensions])) ext: GhostFileKind.audio,
  for (final ext in _extensionSet([_videoExtensions])) ext: GhostFileKind.video,
  'pdf': GhostFileKind.pdf,
};

/// The kind-glyph family for [item]: its file type first (folders and
/// links are never guessed from a name), then the lowercase extension
/// after the last dot — a leading dot is part of a dotfile's stem, so
/// `.bashrc` has no extension and reads as a generic file.
GhostFileKind ghostFileKind(GhostFileItem item) {
  switch (item.type) {
    case GhostFileNodeType.directory:
      return GhostFileKind.folder;
    case GhostFileNodeType.symbolicLink:
      return GhostFileKind.link;
    case GhostFileNodeType.file || GhostFileNodeType.other:
      break;
  }
  final name = item.name;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return GhostFileKind.other;
  final extension = name.substring(dot + 1).toLowerCase();
  return _kindByExtension[extension] ?? GhostFileKind.other;
}

/// A listing kind's glyph and family hue (D32 §6 as D34 colours it):
/// one table for the desktop rows, the touch rows' kind badges, and
/// every other surface that names an item by its kind. The glyphs are
/// the filled faces, since a hairline outline at 16 px carries too
/// little colour to be told apart at a glance; the active selection
/// repaints them on-accent, where the tint would sink into the fill.
(IconData, FamilyHue) ghostFileKindGlyph(GhostFileKind kind) => switch (kind) {
  GhostFileKind.folder => (Icons.folder, FamilyHue.blue),
  GhostFileKind.link => (Icons.shortcut, FamilyHue.cyan),
  GhostFileKind.image => (Icons.image, FamilyHue.pink),
  GhostFileKind.document => (Icons.description, FamilyHue.graphite),
  GhostFileKind.code => (Icons.integration_instructions, FamilyHue.orange),
  GhostFileKind.archive => (Icons.inventory_2, FamilyHue.brown),
  GhostFileKind.pdf => (Icons.picture_as_pdf, FamilyHue.red),
  GhostFileKind.audio => (Icons.audio_file, FamilyHue.purple),
  GhostFileKind.video => (Icons.video_file, FamilyHue.purple),
  GhostFileKind.other => (Icons.insert_drive_file, FamilyHue.graphite),
};

/// [kind]'s glyph as an [Icon] in its hue for [context]'s theme.
Icon ghostFileKindIcon(
  BuildContext context,
  GhostFileKind kind, {
  required double size,
}) {
  final (glyph, hue) = ghostFileKindGlyph(kind);
  return Icon(glyph, size: size, color: FamilyPalette.of(context).glyph(hue));
}
