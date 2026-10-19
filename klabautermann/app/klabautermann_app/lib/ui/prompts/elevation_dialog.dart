import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// The admin-mode password dialog (03 §8.2, SAF-02): the sudo password
/// for [user] on [host], returned when the user turns admin mode on, or
/// null on Cancel. [retry] says the previous one was refused. It offers
/// no "remember" (v1.x): the engine holds the password in memory for the
/// admin window only. [dialogKey] lets the prompt host close it when the
/// engine withdraws the prompt.
Future<String?> showElevationPasswordDialog(
  BuildContext context, {
  required String user,
  required String host,
  required bool retry,
  required GlobalKey dialogKey,
}) => showDialog<String>(
  context: context,
  barrierDismissible: false,
  builder: (context) =>
      _ElevationDialog(key: dialogKey, user: user, host: host, retry: retry),
);

class _ElevationDialog extends StatefulWidget {
  const _ElevationDialog({
    super.key,
    required this.user,
    required this.host,
    required this.retry,
  });

  final String user;
  final String host;
  final bool retry;

  @override
  State<_ElevationDialog> createState() => _ElevationDialogState();
}

class _ElevationDialogState extends State<_ElevationDialog> {
  final _password = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (_password.text.isEmpty) return;
    Navigator.of(context).pop(_password.text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(l10n.elevationTitle(widget.host)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Text(l10n.elevationDetail(widget.user)),
          if (widget.retry)
            Text(
              l10n.elevationRetry,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          TextField(
            controller: _password,
            autofocus: true,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            decoration: InputDecoration(labelText: l10n.elevationPassword),
            onSubmitted: (_) => _submit(),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.elevationCancel),
        ),
        FilledButton(
          onPressed: _password.text.isEmpty ? null : _submit,
          child: Text(l10n.elevationTurnOn),
        ),
      ],
    );
  }
}
