import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart'
    show FsLocation, LocalFsLocation, TransferOperation;

import 'pane_drop.dart';
import 'pane_location.dart';

/// What a Paste does with the clipboard's items (P4-21, decision Q5).
enum FileClipboardMode {
  /// Copy: the items stay where they are; Paste copies them, as often
  /// as the user pastes.
  copy,

  /// Cut: the items are dimmed where they are; the next Paste moves
  /// them and empties the clipboard.
  cut,
}

/// The items Copy or Cut put on the clipboard: their host and the root
/// paths of the selection when it was taken.
@immutable
class FileClipboardContent {
  FileClipboardContent({
    required this.source,
    required List<String> rootPaths,
    required this.mode,
  }) : rootPaths = List.unmodifiable(rootPaths);

  final FsLocation source;
  final List<String> rootPaths;
  final FileClipboardMode mode;
}

/// The app-internal file clipboard (P4-21, decision Q5): Copy, Cut and
/// Paste across panes, tabs and hosts, local or remote. It never touches
/// the OS clipboard, so other apps neither see these items nor can put
/// files here; the text clipboard (Copy Path) is unaffected.
///
/// One clipboard serves the whole window: a Copy in one pane and a
/// Paste in any other tab, on any host, is the point of it.
class FileClipboard extends ChangeNotifier {
  FileClipboardContent? _content;

  /// The items a Paste would act on, or null while the clipboard is
  /// empty.
  FileClipboardContent? get content => _content;

  /// Replaces the clipboard with [rootPaths] on [source]. An empty
  /// selection leaves the clipboard as it was.
  void put({
    required FsLocation source,
    required List<String> rootPaths,
    required FileClipboardMode mode,
  }) {
    if (rootPaths.isEmpty) return;
    _content = FileClipboardContent(
      source: source,
      rootPaths: rootPaths,
      mode: mode,
    );
    notifyListeners();
  }

  void clear() {
    if (_content == null) return;
    _content = null;
    notifyListeners();
  }

  /// Whether the row at [path] on [location] was cut and not yet pasted
  /// (it renders dimmed). A row inside a cut folder is not dimmed on its
  /// own: the folder is the item.
  bool isCut(FsLocation location, String path) {
    final content = _content;
    if (content == null || content.mode != FileClipboardMode.cut) {
      return false;
    }
    return _sameHost(content.source, location) &&
        content.rootPaths.contains(path);
  }
}

bool _sameHost(FsLocation a, FsLocation b) => paneDropSameFilesystem(a, b);

/// How a Paste carries out [content] into a folder on [destination].
enum FilePasteKind {
  /// A copy through the transfer queue.
  copy,

  /// Cut on one server: each item is renamed into the folder, server
  /// side, without moving bytes.
  rename,

  /// Cut on this device or across hosts: a transfer-queue move. On one
  /// local volume the queue renames each file; anywhere else it copies
  /// a file and deletes its source only after the copy committed.
  move,
}

/// The paste a [content] makes into [destinationDir] on [destination],
/// or null when 02 §5.1's containment rules refuse it (a folder into
/// itself, or a cut item back into the folder it is in).
FilePasteKind? filePasteKind(
  FileClipboardContent content, {
  required FsLocation destination,
  required String destinationDir,
}) {
  final operation = switch (content.mode) {
    FileClipboardMode.copy => TransferOperation.copy,
    FileClipboardMode.cut => TransferOperation.move,
  };
  final allowed = paneDropAllowed(
    source: content.source,
    sourceRoots: content.rootPaths,
    destination: destination,
    destinationDir: destinationDir,
    operation: operation,
  );
  if (!allowed) return null;
  if (content.mode == FileClipboardMode.copy) return FilePasteKind.copy;
  final sameServer =
      content.source is! LocalFsLocation &&
      paneDropSameFilesystem(content.source, destination);
  return sameServer ? FilePasteKind.rename : FilePasteKind.move;
}

/// [name] inside [folder], in the folder's own separator style.
String fileChildPath(String folder, String name) {
  final separator = paneSeparator(folder);
  return folder.endsWith(separator) ? '$folder$name' : '$folder$separator$name';
}
