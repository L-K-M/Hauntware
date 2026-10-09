import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../services/missing_credential.dart';
import '../services/private_key_file.dart';

const _mono = TextStyle(fontFamily: 'monospace', fontSize: 12);

/// Asks for the credential a tab could not find on this device (CRED-05's
/// inline prompt): the server's password, or its private key. Null when the
/// user cancels. [pickKeyText] reads a key file; a test supplies its own.
Future<MissingCredential?> showMissingCredentialDialog(
  BuildContext context, {
  required String serverLabel,
  required AuthMethod authMethod,
  Future<String?> Function() pickKeyText = pickPrivateKeyText,
}) => showDialog<MissingCredential>(
  context: context,
  builder: (_) => _CredentialDialog(
    serverLabel: serverLabel,
    authMethod: authMethod,
    pickKeyText: pickKeyText,
  ),
);

class _CredentialDialog extends StatefulWidget {
  const _CredentialDialog({
    required this.serverLabel,
    required this.authMethod,
    required this.pickKeyText,
  });

  final String serverLabel;
  final AuthMethod authMethod;
  final Future<String?> Function() pickKeyText;

  @override
  State<_CredentialDialog> createState() => _CredentialDialogState();
}

class _CredentialDialogState extends State<_CredentialDialog> {
  final _secret = TextEditingController();
  final _passphrase = TextEditingController();
  String? _error;

  bool get _isKey => widget.authMethod == AuthMethod.privateKey;

  @override
  void dispose() {
    _secret.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _chooseFile() async {
    try {
      final text = await widget.pickKeyText();
      if (text == null || !mounted) return;
      setState(() {
        _secret.text = text;
        _error = null;
      });
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'That file could not be opened.');
    }
  }

  void _save() {
    final secret = _secret.text;
    if (secret.isEmpty) return;
    final passphrase = _passphrase.text;
    Navigator.pop<MissingCredential>(
      context,
      _isKey
          ? MissingPrivateKey(
              secret,
              passphrase: passphrase.isEmpty ? null : passphrase,
            )
          : MissingPassword(secret),
    );
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return AlertDialog(
      title: Text(
        _isKey
            ? 'Private key for ${widget.serverLabel}'
            : 'Password for ${widget.serverLabel}',
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Saved on this device, in its encrypted vault, and used for '
                'this server from now on.',
              ),
              const SizedBox(height: 12),
              if (_isKey) ...[
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: OutlinedButton.icon(
                    key: const ValueKey('credential.chooseFile'),
                    onPressed: _chooseFile,
                    icon: const Icon(Icons.file_open_outlined),
                    label: const Text('Choose key file…'),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('credential.key'),
                  controller: _secret,
                  minLines: 4,
                  maxLines: 8,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: _mono,
                  decoration: const InputDecoration(
                    labelText: 'Private key (PEM)',
                    hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                TextField(
                  key: const ValueKey('credential.passphrase'),
                  controller: _passphrase,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Key passphrase (if it has one)',
                  ),
                ),
              ] else
                TextField(
                  key: const ValueKey('credential.password'),
                  controller: _secret,
                  obscureText: true,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Password'),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _save(),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('credential.save'),
          onPressed: _secret.text.isEmpty ? null : _save,
          child: const Text('Save and connect'),
        ),
      ],
    );
  }
}
