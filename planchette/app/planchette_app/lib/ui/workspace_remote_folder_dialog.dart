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

  void _open() {
    if (ModalRoute.of(context)?.isCurrent != true) return;
    final folder = normalizeServerStartDirectory(_path.text);
    if (folder == null) {
      setState(() => _error = 'Enter a folder using /path, ~ or ~/path.');
      return;
    }
    Navigator.pop(context, folder);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
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
        onSubmitted: (_) => _open(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _open, child: const Text('Open')),
    ],
  );

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }
}
