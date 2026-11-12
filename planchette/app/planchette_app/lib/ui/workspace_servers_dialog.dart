import 'dart:async';

import 'package:flutter/material.dart';
import 'package:seance_core/catalog.dart' show HostKeyConflict;
import 'package:seance_core/seance_core.dart';

import '../services/workspace_catalog.dart';
import '../widgets/mono_text_style.dart';

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
  bool _resolvingPin = false;

  WorkspaceCatalog get _catalog => widget.catalog;

  @override
  void initState() {
    super.initState();
    for (final controller in [_baseUrl, _username, _password, _passphrase]) {
      controller.addListener(_fieldsChanged);
    }
    _load();
  }

  /// The Sign In gating follows what the fields hold, so every edit
  /// rebuilds the actions.
  void _fieldsChanged() {
    if (mounted) setState(() {});
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

  /// Sign In's readiness: URL, username and password filled (the
  /// passphrase is optional) and nothing already in flight.
  bool get _canSignIn =>
      _baseUrl.text.trim().isNotEmpty &&
      _username.text.trim().isNotEmpty &&
      _password.text.isNotEmpty;

  /// Return in any field submits, the same gate the button applies.
  void _submitSignIn() {
    if (_catalog.busy || !_canSignIn) return;
    unawaited(_signIn());
  }

  Future<void> _refresh() async {
    try {
      await _catalog.sync();
    } catch (_) {
      // Cached servers remain selectable after a failed refresh.
    }
  }

  /// One resolution at a time, so a double tap cannot send two requests. The
  /// flag flips before the first await, and the buttons follow it.
  Future<void> _resolvePinConflict(
    HostKeyConflict conflict, {
    required bool keepLocal,
  }) async {
    if (_resolvingPin) return;
    _resolvingPin = true;
    if (mounted) setState(() {});
    try {
      await _catalog.resolvePinConflict(conflict, keepLocal: keepLocal);
    } catch (_) {
      // The catalog's error is visible above, as for a failed refresh.
    } finally {
      _resolvingPin = false;
      if (mounted) setState(() {});
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
              for (final conflict in _catalog.hostKeyConflicts)
                _PinConflictCard(
                  conflict: conflict,
                  busy: busy || _resolvingPin,
                  onResolve: _resolvePinConflict,
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
                  onSubmitted: busy ? null : (_) => _submitSignIn(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _username,
                  readOnly: account != null,
                  enabled: !busy,
                  decoration: const InputDecoration(labelText: 'Username'),
                  onSubmitted: busy ? null : (_) => _submitSignIn(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  enabled: !busy,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  decoration: const InputDecoration(
                    labelText: 'Account password',
                  ),
                  onSubmitted: busy ? null : (_) => _submitSignIn(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passphrase,
                  enabled: !busy,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  decoration: const InputDecoration(
                    labelText: 'Encryption passphrase',
                  ),
                  onSubmitted: busy ? null : (_) => _submitSignIn(),
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
              onPressed: busy || !_canSignIn ? null : _submitSignIn,
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

/// One synced host key that differs from this device's pin, with the two
/// actions that resolve it. The durable notice above stays until the next
/// sync; this card is the in-memory conflict itself.
class _PinConflictCard extends StatelessWidget {
  const _PinConflictCard({
    required this.conflict,
    required this.busy,
    required this.onResolve,
  });

  final HostKeyConflict conflict;
  final bool busy;
  final Future<void> Function(
    HostKeyConflict conflict, {
    required bool keepLocal,
  })
  onResolve;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onContainer = TextStyle(color: scheme.onErrorContainer);
    final fingerprint = monoTextStyle.copyWith(color: scheme.onErrorContainer);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Another device synced a different host key for '
              '${conflict.locator}. Planchette kept this device\'s key and is '
              'not using the other one. If the server\'s key really changed, '
              'trust the new one; otherwise keep yours.',
              style: onContainer,
            ),
            const SizedBox(height: 8),
            Text('This device trusts', style: onContainer),
            SelectableText(
              conflict.local.fingerprintSha256,
              style: fingerprint,
            ),
            const SizedBox(height: 4),
            Text('The other device synced', style: onContainer),
            SelectableText(
              conflict.pulled.fingerprintSha256,
              style: fingerprint,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: busy
                      ? null
                      : () => onResolve(conflict, keepLocal: true),
                  child: const Text("Keep this device's key"),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => onResolve(conflict, keepLocal: false),
                  child: const Text('Trust the new key'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
