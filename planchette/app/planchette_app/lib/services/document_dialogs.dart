import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart';
import 'package:path/path.dart' as paths;

import 'android_documents.dart';
import 'document_windows.dart';
import 'document_workspace.dart';
import 'document_store.dart';

final class AppDocumentDialogs implements DocumentDialogs {
  AppDocumentDialogs(this.navigatorKey, {this.pickers, this.android});
  final GlobalKey<NavigatorState> navigatorKey;
  final AndroidDocuments? android;

  /// The window's own native file dialogs. file_selector parents every
  /// dialog to the plugin registry's view — the main window — which may be
  /// hidden while other windows are open, so a window that can be one of
  /// several asks the runner for a dialog owned by its own view instead.
  final WindowPickers? pickers;

  // file_selector shows each platform's own dialog. On Linux that is GTK's
  // chooser, which goes through the desktop portal only where GTK would, so
  // Open and Save As work on desktops that run no portal service.
  @override
  Future<List<String>> pickOpenFiles() async {
    final documents = android;
    if (documents != null) return documents.pickOpenFiles();
    final window = pickers;
    if (window != null && window.available) {
      return window.pickOpenFiles();
    }
    final files = await openFiles(confirmButtonText: 'Open');
    return [for (final file in files) file.path];
  }

  Future<String?> pickDirectory() {
    final window = pickers;
    if (window != null && window.available) return window.pickDirectory();
    return getDirectoryPath(confirmButtonText: 'Open Folder');
  }

  /// Key picking shares the window-owned dialog and bounded UTF-8 reader.
  Future<String?> pickKeyText() async {
    final selected = await pickOpenFiles();
    if (selected.isEmpty) return null;
    if (selected.length != 1) {
      throw const FormatException('Choose one private-key file.');
    }
    return (await LocalDocumentStore().load(selected.single)).text;
  }

  @override
  Future<String?> pickSavePath(String suggestedName) async {
    final documents = android;
    if (documents != null) {
      return documents.pickSavePath(paths.basename(suggestedName));
    }
    final window = pickers;
    if (window != null && window.available) {
      return window.pickSavePath(
        suggestedName: paths.basename(suggestedName),
        initialDirectory: paths.isAbsolute(suggestedName)
            ? paths.dirname(suggestedName)
            : null,
      );
    }
    final location = await getSaveLocation(
      suggestedName: paths.basename(suggestedName),
      initialDirectory: paths.isAbsolute(suggestedName)
          ? paths.dirname(suggestedName)
          : null,
      confirmButtonText: 'Save',
    );
    return location?.path;
  }

  @override
  Future<bool> confirmReplace(String path) async {
    final context = navigatorKey.currentContext;
    if (context == null) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Replace “${paths.basename(path)}”?'),
            content: const Text(
              'The existing file will be replaced with this document.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Replace'),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Future<BulkCloseChoice> chooseBulkClose(List<String> names) async {
    // The workspace offers this question only when more than one document is
    // unsaved; a single one gets the prompt that names its file.
    assert(names.length > 1, 'the bulk close question covers several files');
    final context = navigatorKey.currentContext;
    if (context == null) return BulkCloseChoice.cancel;
    final choice = await showGhostCloseDialog(
      context,
      title: 'Save changes to ${names.length} documents?',
      body:
          '${_listed(names)}\n\n'
          'Your changes will be lost if you close without saving them.',
      saveLabel: 'Save All',
    );
    return switch (choice) {
      GhostCloseChoice.save => BulkCloseChoice.saveAll,
      GhostCloseChoice.dontSave => BulkCloseChoice.discardAll,
      GhostCloseChoice.cancel => BulkCloseChoice.cancel,
      null => BulkCloseChoice.cancel,
    };
  }

  @override
  Future<CloseChoice> chooseClose(String name) async {
    final context = navigatorKey.currentContext;
    if (context == null) return CloseChoice.cancel;
    final choice = await showGhostCloseDialog(
      context,
      title: 'Save changes to “$name”?',
      body:
          'Your changes will be lost if you close this document without saving.',
    );
    return switch (choice) {
      GhostCloseChoice.save => CloseChoice.save,
      GhostCloseChoice.dontSave => CloseChoice.discard,
      GhostCloseChoice.cancel => CloseChoice.cancel,
      null => CloseChoice.cancel,
    };
  }

  @override
  Future<ReadOnlyChoice> chooseReadOnlySave(String name) async {
    final context = navigatorKey.currentContext;
    if (context == null) return ReadOnlyChoice.cancel;
    return await showDialog<ReadOnlyChoice>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('“$name” is read-only'),
            content: const Text(
              'Saving replaces the file anyway and keeps it read-only. You '
              'can save your changes as a new file instead.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, ReadOnlyChoice.cancel),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, ReadOnlyChoice.saveAnyway),
                child: const Text('Save Anyway'),
              ),
              FilledButton(
                autofocus: true,
                onPressed: () => Navigator.pop(context, ReadOnlyChoice.saveAs),
                child: const Text('Save As…'),
              ),
            ],
          ),
        ) ??
        ReadOnlyChoice.cancel;
  }

  @override
  Future<bool> confirmRevert(String name) async {
    final context = navigatorKey.currentContext;
    if (context == null) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Revert “$name” to its saved version?'),
            content: const Text('Your unsaved changes will be lost.'),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Revert'),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Future<bool> confirmDiscardRecovery(String name) async {
    final context = navigatorKey.currentContext;
    if (context == null) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Delete the recovery copy “$name”?'),
            content: const Text(
              'It holds the earlier contents of a document Planchette could '
              'not save. If you keep it, it opens again the next time you '
              'start Planchette.',
            ),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Future<bool> offerSaveElsewhere(String name, String folder) async {
    final context = navigatorKey.currentContext;
    if (context == null) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Save “$name” somewhere else?'),
            content: Text(
              'The folder $folder does not let Planchette create the '
              'temporary file a safe save needs, so the file cannot be saved '
              'there. You can save a copy in another folder instead.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                autofocus: true,
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Save As…'),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Future<SaveSiblingChoice> chooseSaveSiblings(
    String name,
    List<String> siblings,
  ) async {
    final context = navigatorKey.currentContext;
    if (context == null) return SaveSiblingChoice.keep;
    return await showDialog<SaveSiblingChoice>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Files left by an interrupted save of “$name”'),
            content: Text(
              'An earlier save of this document stopped before it finished '
              'and left ${siblings.length == 1 ? 'this file' : 'these files'} '
              'beside it. Each holds a version of its text: the one before '
              'that save or the one it was writing. Open them to compare, or '
              'delete them if you do not need them.\n\n${_listed(siblings)}',
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, SaveSiblingChoice.delete),
                child: const Text('Delete'),
              ),
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.pop(context, SaveSiblingChoice.keep),
                child: const Text('Keep'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, SaveSiblingChoice.open),
                child: const Text('Open'),
              ),
            ],
          ),
        ) ??
        SaveSiblingChoice.keep;
  }
}

/// A short list of file names for a prompt: a long selection still fits.
String _listed(List<String> names) {
  const shown = 8;
  if (names.length <= shown) return names.join('\n');
  return '${names.take(shown).join('\n')}\n'
      'and ${names.length - shown} more';
}
