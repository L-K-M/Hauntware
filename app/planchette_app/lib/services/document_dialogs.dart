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
  Future<int?> promptLineNumber(String documentName, int maxLines) async {
    final context = navigatorKey.currentContext;
    if (context == null) return null;
    return showDialog<int>(
      context: context,
      builder: (context) => _LineNumberDialog(maxLines: maxLines),
    );
  }
}

class _LineNumberDialog extends StatefulWidget {
  const _LineNumberDialog({required this.maxLines});
  final int maxLines;

  @override
  State<_LineNumberDialog> createState() => _LineNumberDialogState();
}

class _LineNumberDialogState extends State<_LineNumberDialog> {
  final _field = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() {
    final line = int.tryParse(_field.text.trim());
    if (line == null || line < 1 || line > widget.maxLines) {
      setState(
        () => _error = 'Enter a line between 1 and ${widget.maxLines}.',
      );
      return;
    }
    Navigator.pop(context, line);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Go to Line'),
    content: SizedBox(
      width: 280,
      child: TextField(
        controller: _field,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          hintText: 'Line 1–${widget.maxLines}',
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Go')),
    ],
  );
}
