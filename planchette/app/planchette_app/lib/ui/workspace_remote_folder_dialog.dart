import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

Future<String?> showRemoteWorkspaceRoot(
  BuildContext context,
  ServerConfig server,
) => showDialog<String>(
  context: context,
  builder: (_) => _RemoteFolder(server: server),
);

class _RemoteFolder extends StatefulWidget {
  const _RemoteFolder({required this.server});
  final ServerConfig server;

  @override
  State<_RemoteFolder> createState() => _RemoteFolderState();
}

class _RemoteFolderState extends State<_RemoteFolder> {
  late final _path = TextEditingController(
    text: widget.server.startDirectory ?? '~',
  );
  String? _error;

  /// Open's readiness: the path must name a folder the way the editor
  /// accepts it, checked live so the button never offers a refusal.
  bool get _pathValid => _folderOf(_path.text) != null;

  static String? _folderOf(String text) => normalizeServerStartDirectory(text);

  void _open() {
    if (ModalRoute.of(context)?.isCurrent != true) return;
    final folder = _folderOf(_path.text);
    if (folder == null) {
      setState(() => _error = 'Enter a folder using /path, ~ or ~/path.');
      return;
    }
    Navigator.pop(context, folder);
  }

  @override
  void initState() {
    super.initState();
    _path.addListener(() {
      if (!mounted) return;
      // A fix the user just typed outruns the error it clears.
      if (_folderOf(_path.text) != null && _error != null) {
        setState(() => _error = null);
      }
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _path,
    builder: (context, _) => AlertDialog(
      title: Text('Open Folder on ${widget.server.label}'),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _path,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Remote folder',
            helperText: 'Absolute path or relative to your login home.',
            errorText: _error,
          ),
          // Return submits, and an invalid path says why rather than
          // closing nothing.
          onSubmitted: (_) => _open(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _pathValid ? _open : null,
          child: const Text('Open'),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }
}
