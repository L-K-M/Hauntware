import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as paths;

import 'document_workspace.dart';

final class AppDocumentDialogs implements DocumentDialogs {
  AppDocumentDialogs(this.navigatorKey);
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  Future<List<String>> pickOpenFiles() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Open text documents',
      allowMultiple: true,
    );
    return result?.paths.whereType<String>().toList() ?? [];
  }

  @override
  Future<String?> pickSavePath(String suggestedName) => FilePicker.saveFile(
    dialogTitle: 'Save document',
    fileName: paths.basename(suggestedName),
    initialDirectory: paths.isAbsolute(suggestedName)
        ? paths.dirname(suggestedName)
        : null,
  );

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
    return await showDialog<BulkCloseChoice>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Save changes to ${names.length} documents?'),
            content: Text(
              '${_listed(names)}\n\n'
              'Your changes will be lost if you close without saving them.',
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, BulkCloseChoice.discardAll),
                child: const Text('Don’t Save'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, BulkCloseChoice.cancel),
                child: const Text('Cancel'),
              ),
              FilledButton(
                autofocus: true,
                onPressed: () =>
                    Navigator.pop(context, BulkCloseChoice.saveAll),
                child: const Text('Save All'),
              ),
            ],
          ),
        ) ??
        BulkCloseChoice.cancel;
  }

  @override
  Future<CloseChoice> chooseClose(String name) async {
    final context = navigatorKey.currentContext;
    if (context == null) return CloseChoice.cancel;
    return await showDialog<CloseChoice>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Save changes to “$name”?'),
            content: const Text(
              'Your changes will be lost if you close this document without saving.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, CloseChoice.discard),
                child: const Text('Don’t Save'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, CloseChoice.cancel),
                child: const Text('Cancel'),
              ),
              FilledButton(
                autofocus: true,
                onPressed: () => Navigator.pop(context, CloseChoice.save),
                child: const Text('Save'),
              ),
            ],
          ),
        ) ??
        CloseChoice.cancel;
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
}

/// A short list of file names for a prompt: a long selection still fits.
String _listed(List<String> names) {
  const shown = 8;
  if (names.length <= shown) return names.join('\n');
  return '${names.take(shown).join('\n')}\n'
      'and ${names.length - shown} more';
}
