import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  Future<int?> askLineNumber(int maximumLine) async {
    final context = navigatorKey.currentContext;
    if (context == null) return null;
    final input = TextEditingController();
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Go to Line'),
        content: TextField(
          controller: input,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            // Cap the field far below any real line count so every value
            // the user can enter still parses; a huge paste would
            // otherwise fail int.tryParse and silently act like Cancel.
            LengthLimitingTextInputFormatter(9),
          ],
          decoration: InputDecoration(
            hintText: 'Line number (1–$maximumLine)',
          ),
          onSubmitted: (value) =>
              Navigator.pop(dialogContext, int.tryParse(value)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, null),
            child: const Text('Cancel'),
          ),
          // Go stays disabled until the field holds a parseable number.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: input,
            builder: (context, value, _) {
              final line = int.tryParse(value.text);
              return FilledButton(
                onPressed: line == null
                    ? null
                    : () => Navigator.pop(dialogContext, line),
                child: const Text('Go'),
              );
            },
          ),
        ],
      ),
    );
    input.dispose();
    return result;
  }
}
