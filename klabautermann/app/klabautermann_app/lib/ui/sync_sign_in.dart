import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/sync_controller.dart';
import '../l10n/app_localizations.dart';

const double _dialogMaxWidth = 480;

/// The sync control's action (the rail's chip, the phone's button): the
/// sign-in when [SyncController.needsSignIn], otherwise one round, whose
/// failure is told in a top toast. A round that succeeds shows itself in
/// the fleet.
Future<void> runSyncAction(BuildContext context, SyncController sync) async {
  if (sync.busy) return;
  if (sync.needsSignIn) return showSyncSignIn(context, sync);

  final overlay = Overlay.of(context, rootOverlay: true);
  final l10n = AppLocalizations.of(context);
  final status = await sync.syncNow();
  if (!overlay.mounted) return;
  if (status.failure case final failure?) {
    showTopToast(overlay, message: syncFailureMessage(l10n, failure));
  } else if (status.passphraseUnverified) {
    showTopToast(overlay, message: l10n.syncPassphraseUnverified);
  }
}

/// The sync control's tooltip.
String syncActionTooltip(AppLocalizations l10n, SyncController sync) =>
    switch (sync.account) {
      final account? when !sync.needsSignIn => l10n.syncNowTooltip(
        account.username,
        Uri.tryParse(account.baseUrl)?.host ?? account.baseUrl,
      ),
      _ => l10n.syncSignInTooltip,
    };

/// Opens the sign-in of 03 §4.3 steps 1 and 2 over [context].
Future<void> showSyncSignIn(BuildContext context, SyncController sync) =>
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _dialogMaxWidth),
          child: SyncSignInDialog(sync: sync),
        ),
      ),
    );

/// The user-facing sentence for a sync [failure].
String syncFailureMessage(AppLocalizations l10n, SyncFailure failure) =>
    switch (failure) {
      SyncFailure.directoryShared => l10n.syncFailedDirectoryShared,
      SyncFailure.noDeviceId => l10n.syncFailedNoDeviceId,
      SyncFailure.notEnrolled => l10n.syncSignInTooltip,
      SyncFailure.otherAccount => l10n.syncFailedOtherAccount,
      SyncFailure.invalidRequest => l10n.syncValidationServerAddress,
      SyncFailure.kdfDowngrade => l10n.syncFailedKdfDowngrade,
      SyncFailure.credentialsRejected => l10n.syncFailedCredentials,
      SyncFailure.sessionRejected => l10n.syncFailedSession,
      SyncFailure.unreachable => l10n.syncFailedUnreachable,
      SyncFailure.serverError => l10n.syncFailedServer,
      SyncFailure.keystoreUnavailable => l10n.syncFailedKeystore,
      SyncFailure.storeUnavailable => l10n.syncFailedStore,
      SyncFailure.other => l10n.syncFailed,
    };

/// The sentence for a field the suite's enrollment rule refuses.
String _issueMessage(AppLocalizations l10n, SyncEnrollmentIssue issue) =>
    switch (issue) {
      SyncEnrollmentIssue.invalidServerUrl => l10n.syncValidationServerAddress,
      SyncEnrollmentIssue.credentialsInUrl => l10n.syncValidationUrlCredentials,
      SyncEnrollmentIssue.missingUsername => l10n.syncValidationAccountName,
      SyncEnrollmentIssue.missingPassword => l10n.syncValidationPassword,
      // A sign-in has no confirmation field; the rule asks for one only
      // when registering, which Klabautermann never does.
      SyncEnrollmentIssue.missingEncryptionPassphrase ||
      SyncEnrollmentIssue.missingConfirmation ||
      SyncEnrollmentIssue.confirmationMismatch => l10n.syncValidationPassphrase,
    };

enum _Step { account, confirm }

/// The sign-in sheet (03 §4.3): step 1 explains where the list comes from
/// and takes the Séance account, step 2 asks the fleet assertion and makes
/// the disclosures before anything is sent. Nothing reaches the engine
/// until the user confirms, so no record is pulled before the assertion.
class SyncSignInDialog extends StatefulWidget {
  const SyncSignInDialog({super.key, required this.sync});

  final SyncController sync;

  @override
  State<SyncSignInDialog> createState() => _SyncSignInDialogState();
}

class _SyncSignInDialogState extends State<SyncSignInDialog> {
  late final _baseUrl = TextEditingController(
    text: widget.sync.account?.baseUrl,
  );
  late final _username = TextEditingController(
    text: widget.sync.account?.username,
  );
  final _password = TextEditingController();
  final _passphrase = TextEditingController();

  _Step _step = _Step.account;
  bool _fleetAsserted = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _baseUrl.dispose();
    _username.dispose();
    _password.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  void _continue() {
    final issue = validateSyncEnrollment(
      mode: SyncEnrollmentMode.login,
      baseUrl: _baseUrl.text,
      username: _username.text,
      password: _password.text,
      encryptionPassphrase: _passphrase.text,
    );
    setState(() {
      _error = issue == null
          ? null
          : _issueMessage(AppLocalizations.of(context), issue);
      if (issue == null) _step = _Step.confirm;
    });
  }

  Future<void> _signIn() async {
    final l10n = AppLocalizations.of(context);
    final overlay = Overlay.of(context, rootOverlay: true);
    setState(() {
      _busy = true;
      _error = null;
    });
    final status = await widget.sync.signIn(
      baseUrl: _baseUrl.text,
      username: _username.text,
      password: _password.text,
      encryptionPassphrase: _passphrase.text,
    );
    if (!mounted) return;

    if (status.failure case final failure?) {
      setState(() {
        _busy = false;
        _error = syncFailureMessage(l10n, failure);
      });
      return;
    }
    Navigator.of(context).pop();
    showTopToast(
      overlay,
      message: status.passphraseUnverified
          ? l10n.syncPassphraseUnverified
          : l10n.syncSignedIn,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final material = MaterialLocalizations.of(context);
    final theme = Theme.of(context);
    final error = _error;
    final account = _step == _Step.account;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            header: true,
            child: Text(
              account ? l10n.syncSignInTitle : l10n.syncConfirmTitle,
              style: theme.textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: 12),
          if (account) ..._accountStep(l10n) else ..._confirmStep(l10n),
          if (error != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                error,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          OverflowBar(
            alignment: MainAxisAlignment.end,
            spacing: 8,
            children: [
              if (account)
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(material.cancelButtonLabel),
                )
              else
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _step = _Step.account;
                          _error = null;
                        }),
                  child: Text(material.backButtonTooltip),
                ),
              if (account)
                FilledButton(
                  onPressed: _continue,
                  child: Text(material.continueButtonLabel),
                )
              else
                FilledButton(
                  onPressed: _fleetAsserted && !_busy ? _signIn : null,
                  child: Text(l10n.syncSignInAction),
                ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _accountStep(AppLocalizations l10n) => [
    Text(l10n.syncSignInBody),
    const SizedBox(height: 16),
    TextField(
      controller: _baseUrl,
      autofocus: true,
      keyboardType: TextInputType.url,
      autocorrect: false,
      decoration: InputDecoration(labelText: l10n.syncServerAddress),
    ),
    TextField(
      controller: _username,
      autocorrect: false,
      decoration: InputDecoration(labelText: l10n.syncAccountName),
    ),
    TextField(
      controller: _password,
      obscureText: true,
      decoration: InputDecoration(labelText: l10n.syncPassword),
    ),
    TextField(
      controller: _passphrase,
      obscureText: true,
      decoration: InputDecoration(
        labelText: l10n.syncPassphrase,
        helperText: l10n.syncPassphraseHelper,
      ),
      onSubmitted: (_) => _continue(),
    ),
  ];

  List<Widget> _confirmStep(AppLocalizations l10n) => [
    CheckboxListTile(
      value: _fleetAsserted,
      onChanged: _busy
          ? null
          : (value) => setState(() => _fleetAsserted = value ?? false),
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(l10n.syncFleetAssertion),
      subtitle: Text(l10n.syncFleetAssertionDetail),
    ),
    const SizedBox(height: 8),
    Text(l10n.syncDisclosureAccountKey),
    const SizedBox(height: 8),
    Text(l10n.syncDisclosure),
    if (_busy) ...[const SizedBox(height: 16), const LinearProgressIndicator()],
  ];
}
