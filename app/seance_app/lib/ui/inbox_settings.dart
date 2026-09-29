import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seance_core/seance_core.dart';

import '../services/settings_backend.dart';
import 'settings_layout.dart';

/// Settings > Inbox: the producers (bots, scripts) connected to the command
/// inbox. See docs/INBOX.md.
class InboxSettings extends StatefulWidget {
  const InboxSettings({super.key, required this.backend});

  final SettingsBackend backend;

  @override
  State<InboxSettings> createState() => _InboxSettingsState();
}

class _InboxSettingsState extends State<InboxSettings> {
  InboxAppsView? _view;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    try {
      final view = await widget.backend.inboxApps();
      if (!mounted) return;
      setState(() {
        _view = view;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  /// Runs [action] with the buttons disabled, and reports a failure inline.
  Future<T?> _run<T>(Future<T> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      return await action();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
      await _reload();
    }
  }

  Future<void> _add() async {
    final view = _view;
    if (view == null) return;
    final draft = await showDialog<InboxAppDraft>(
      context: context,
      builder: (_) => _AppDialog(servers: view.servers),
    );
    if (draft == null || !mounted) return;
    final pairing = await _run(() => widget.backend.addInboxApp(draft));
    if (pairing == null || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PairingDialog(pairing: pairing, appName: draft.name),
    );
  }

  Future<void> _edit(InboxAppSummary app) async {
    final view = _view;
    if (view == null) return;
    final draft = await showDialog<InboxAppDraft>(
      context: context,
      builder: (_) => _AppDialog(servers: view.servers, existing: app),
    );
    if (draft == null || !mounted) return;
    await _run(() => widget.backend.updateInboxApp(app.id, draft));
  }

  Future<void> _remove(InboxAppSummary app) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove "${app.name}"?'),
        content: const Text(
          'Its pairing string stops working, proposals it sent that you '
          'have not handled are deleted, and your other devices forget it. '
          'To connect it again, add it again and hand it the new pairing '
          'string.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(() => widget.backend.removeInboxApp(app.id));
  }

  String _scope(InboxAppSummary app, List<InboxServerChoice> servers) {
    if (app.allowedServerIds.isEmpty) return 'Any server';
    final labels = [
      for (final s in servers)
        if (app.allowedServerIds.contains(s.id)) s.label,
    ];
    if (labels.isEmpty) return 'No server (the allowed ones were deleted)';
    return labels.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final view = _view;
    return SettingsPage(
      storageKey: const PageStorageKey('inbox-settings'),
      children: [
        const SettingsSectionHeader(
          'Command inbox',
          helpTitle: 'How the inbox works',
          help:
              'A connected app can propose commands for your servers. It '
              'cannot run anything: each proposal waits in Séance until you '
              'review it and run it yourself, or dismiss it. Proposals are '
              'encrypted with a key only the app and your vault hold, so the '
              'sync server can neither read nor forge them.',
        ),
        const Text(
          'Connect a bot or script so it can propose commands. You review '
          'every proposal and decide whether to run it.',
        ),
        const SizedBox(height: 12),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        if (view == null)
          const Center(child: CircularProgressIndicator())
        else if (!view.syncConfigured)
          const Text(
            'Set up sync first: the inbox uses your sync server.',
          )
        else ...[
          for (final app in view.apps)
            ListTile(
              key: ValueKey('inbox.app.${app.id}'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.smart_toy_outlined),
              title: Text(app.name),
              subtitle: Text(
                app.refused == 0
                    ? _scope(app, view.servers)
                    : '${_scope(app, view.servers)}\n'
                          '${app.refused} proposal${app.refused == 1 ? '' : 's'} '
                          'could not be opened. Check the app uses its '
                          'current pairing string.',
              ),
              isThreeLine: app.refused != 0,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Edit',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: _busy ? null : () => _edit(app),
                  ),
                  IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _busy ? null : () => _remove(app),
                  ),
                ],
              ),
            ),
          if (view.apps.isEmpty)
            Text('No apps connected.', style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              key: const ValueKey('inbox.add'),
              onPressed: _busy ? null : _add,
              icon: const Icon(Icons.add),
              label: const Text('Connect an app'),
            ),
          ),
        ],
      ],
    );
  }
}

/// Name and target servers, for a new app or an edit.
class _AppDialog extends StatefulWidget {
  const _AppDialog({required this.servers, this.existing});

  final List<InboxServerChoice> servers;
  final InboxAppSummary? existing;

  @override
  State<_AppDialog> createState() => _AppDialogState();
}

class _AppDialogState extends State<_AppDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late bool _anyServer = widget.existing?.allowedServerIds.isEmpty ?? true;
  late final Set<String> _allowed = {...?widget.existing?.allowedServerIds};

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _valid {
    final name = _name.text.trim();
    return name.isNotEmpty &&
        name.length <= kInboxMaxNameChars &&
        (_anyServer || _allowed.isNotEmpty);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Connect an app' : 'Edit app'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('inbox.app.name'),
              controller: _name,
              autofocus: true,
              maxLength: kInboxMaxNameChars,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. bots on bene-dev',
              ),
              onChanged: (_) => setState(() {}),
            ),
            SwitchListTile(
              key: const ValueKey('inbox.app.any'),
              contentPadding: EdgeInsets.zero,
              title: const Text('May target any server'),
              subtitle: const Text(
                'Otherwise, only the servers you pick. A proposal for any '
                'other server can be read but not run.',
              ),
              value: _anyServer,
              onChanged: (v) => setState(() => _anyServer = v),
            ),
            if (!_anyServer)
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final s in widget.servers)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(s.label),
                        value: _allowed.contains(s.id),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _allowed.add(s.id);
                          } else {
                            _allowed.remove(s.id);
                          }
                        }),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('inbox.app.save'),
          onPressed: _valid
              ? () => Navigator.pop(
                  context,
                  InboxAppDraft(
                    name: _name.text.trim(),
                    allowedServerIds: _anyServer
                        ? const []
                        : [
                            for (final s in widget.servers)
                              if (_allowed.contains(s.id)) s.id,
                          ],
                  ),
                )
              : null,
          child: Text(widget.existing == null ? 'Connect' : 'Save'),
        ),
      ],
    );
  }
}

/// Instructions for the agent, to paste into its configuration beside the
/// pairing string (which goes into an environment variable, not the text).
String inboxAgentInstructions(String docsUrl) =>
    'You can propose shell commands for me to review in my SSH client, '
    'Séance. You cannot run them: I read each proposal and decide whether '
    'to run it. The pairing string is in the environment variable '
    'SEANCE_INBOX. It is a secret: never print, log or commit it, and never '
    'put it in a proposal. How to send a proposal, including a reference '
    'client to download, is described at $docsUrl. Name the target with '
    '--host, using the server name as it appears in Séance, and always say '
    'why in --reason.';

/// Shows the pairing string once, with the instructions for the agent.
class _PairingDialog extends StatefulWidget {
  const _PairingDialog({required this.pairing, required this.appName});

  final String pairing;
  final String appName;

  @override
  State<_PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<_PairingDialog> {
  String? _copied;

  Future<void> _copy(String what, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) setState(() => _copied = what);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final docsUrl = InboxPairing.decode(widget.pairing).docsUrl;
    final instructions = inboxAgentInstructions(docsUrl);
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 12);
    return AlertDialog(
      title: Text('Connected "${widget.appName}"'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Pairing string. It is shown only once, and it is a '
                'credential: give it to the app, for example as the '
                'SEANCE_INBOX environment variable, and nowhere else.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              SelectableText(
                widget.pairing,
                key: const ValueKey('inbox.pairing'),
                style: mono,
              ),
              TextButton.icon(
                onPressed: () => _copy('pairing', widget.pairing),
                icon: const Icon(Icons.copy, size: 16),
                label: Text(
                  _copied == 'pairing' ? 'Copied' : 'Copy pairing string',
                ),
              ),
              const Divider(),
              Text(
                'Instructions for the agent:',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              SelectableText(instructions),
              TextButton.icon(
                onPressed: () => _copy('instructions', instructions),
                icon: const Icon(Icons.copy, size: 16),
                label: Text(
                  _copied == 'instructions' ? 'Copied' : 'Copy instructions',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('inbox.pairing.done'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
