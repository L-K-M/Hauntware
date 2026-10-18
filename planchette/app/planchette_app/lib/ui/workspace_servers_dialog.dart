import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../services/workspace_catalog.dart';

Future<ServerConfig?> showWorkspaceServersDialog(
  BuildContext context,
  WorkspaceCatalog catalog,
) => showDialog<ServerConfig>(
  context: context,
  builder: (context) => _WorkspaceServersDialog(catalog: catalog),
);

class _WorkspaceServersDialog extends StatefulWidget {
  const _WorkspaceServersDialog({required this.catalog});
  final WorkspaceCatalog catalog;

  @override
  State<_WorkspaceServersDialog> createState() =>
      _WorkspaceServersDialogState();
}

class _WorkspaceServersDialogState extends State<_WorkspaceServersDialog> {
  final _baseUrl = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _passphrase = TextEditingController();
  bool _showSignIn = false;
  WorkspaceCredentialSync _credentialSync = WorkspaceCredentialSync.disabled;
  String _query = '';

  WorkspaceCatalog get _catalog => widget.catalog;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await _catalog.load();
    } catch (_) {
      // The catalog retains the actionable error for this dialog.
    }
    if (!mounted) return;
    _prepareSignIn();
    setState(() => _showSignIn = _catalog.account == null);
  }

  void _prepareSignIn() {
    final account = _catalog.account;
    _baseUrl.text = account?.baseUrl ?? '';
    _username.text = account?.username ?? '';
    _credentialSync = _catalog.credentialSync;
  }

  Future<void> _signIn() async {
    try {
      await _catalog.signIn(
        baseUrl: _baseUrl.text,
        username: _username.text,
        password: _password.text,
        encryptionPassphrase: _passphrase.text,
        credentialSync: _credentialSync,
      );
      if (!mounted) return;
      _password.clear();
      _passphrase.clear();
      setState(() => _showSignIn = false);
    } catch (_) {
      // Failed enrollment remains open with the catalog's error visible.
    }
  }

  Future<void> _refresh() async {
    try {
      await _catalog.sync();
    } catch (_) {
      // Cached servers remain selectable after a failed refresh.
    }
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _username.dispose();
    _password.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _catalog,
    builder: (context, _) {
      final busy = _catalog.busy;
      final account = _catalog.account;
      final servers = _catalog.servers.where(
        (server) => '${server.label}\n${server.host}\n${server.username}'
            .toLowerCase()
            .contains(_query),
      );
      return AlertDialog(
        title: Row(
          children: [
            const Expanded(child: Text('Workspace servers')),
            if (account != null)
              IconButton(
                tooltip: 'Refresh catalog',
                onPressed: busy ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
          ],
        ),
        content: SizedBox(
          width: 560,
          height: 520,
          child: ListView(
            children: [
              if (busy) const LinearProgressIndicator(),
              if (_catalog.error case final error?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SelectableText(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              for (final notice in _catalog.notices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(notice),
                ),
              if (_showSignIn) ...[
                const Text('Sign in to your existing suite catalog.'),
                const SizedBox(height: 16),
                TextField(
                  controller: _baseUrl,
                  readOnly: account != null,
                  enabled: !busy,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(labelText: 'Server URL'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _username,
                  readOnly: account != null,
                  enabled: !busy,
                  decoration: const InputDecoration(labelText: 'Username'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  enabled: !busy,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Account password',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passphrase,
                  enabled: !busy,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Encryption passphrase',
                  ),
                  onSubmitted: busy ? null : (_) => _signIn(),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Sync saved passwords and keys'),
                  subtitle: const Text(
                    'Optional. Credentials stay encrypted on this device.',
                  ),
                  value: _credentialSync == WorkspaceCredentialSync.enabled,
                  onChanged: busy
                      ? null
                      : (enabled) => setState(() {
                          _credentialSync = enabled
                              ? WorkspaceCredentialSync.enabled
                              : WorkspaceCredentialSync.disabled;
                        }),
                ),
                const Text('Planchette only downloads catalog changes.'),
              ] else ...[
                if (account != null)
                  Text('${account.username} · ${account.baseUrl}'),
                const SizedBox(height: 12),
                TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Search servers',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (value) =>
                      setState(() => _query = value.trim().toLowerCase()),
                ),
                const SizedBox(height: 12),
                if (servers.isEmpty)
                  Text(
                    _catalog.servers.isEmpty
                        ? 'No servers in the cached catalog. Refresh to download changes.'
                        : 'No matching servers.',
                  ),
                for (final server in servers)
                  ListTile(
                    title: Text(server.label),
                    subtitle: Text(
                      '${server.username}@${server.host}:${server.port}',
                    ),
                    leading: const Icon(Icons.dns_outlined),
                    onTap: () => Navigator.pop(context, server),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          if (_showSignIn && account != null)
            TextButton(
              onPressed: busy
                  ? null
                  : () => setState(() => _showSignIn = false),
              child: const Text('Back'),
            ),
          if (_showSignIn)
            FilledButton(
              onPressed: busy ? null : _signIn,
              child: const Text('Sign In'),
            )
          else
            TextButton(
              onPressed: busy
                  ? null
                  : () {
                      _prepareSignIn();
                      setState(() => _showSignIn = true);
                    },
              child: const Text('Sign In'),
            ),
        ],
      );
    },
  );
}
