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
  Future<bool> confirmRevert(String name) async {
    final context = navigatorKey.currentContext;
    if (context == null) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Revert “$name”?'),
            content: const Text(
              'Your unsaved changes will be lost and the file will be '
              'reloaded from disk.',
            ),
            actions: [
              TextButton(
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
}
