import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_servers/ghost_servers.dart'
    show
        GhostCredentialRequest,
        GhostCredentialStrings,
        GhostHostKeyPrompt,
        GhostHostKeyStrings,
        GhostKeyboardInteractiveStrings,
        GhostKeyField,
        GhostKeyboardPrompt,
        GhostPasswordReply,
        showGhostCredentialDialog,
        showGhostHostKeyDialog,
        showGhostKeyboardInteractiveDialog;
import 'package:klabautermann_core/klabautermann_core.dart'
    show
        AuthMethod,
        CredentialPromptRequest,
        ElevationPromptRequest,
        HostKeyPromptRequest,
        KeyboardInteractivePromptRequest,
        Prompt,
        PromptAnswer,
        PromptCancelAnswer,
        PromptResponsesAnswer,
        PromptSecretAnswer,
        PromptTrustAnswer;

import '../../controllers/prompt_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import 'elevation_dialog.dart';

/// Shows the engine's prompts through `ghost_servers`' dialogs (D8; 03
/// §10.1, version 3 M2 prompts) and answers each with what the user chose.
/// Only [PromptController.current] is shown, so the next prompt waits.
///
/// - A first-seen host key is the first-use review, answered with
///   [PromptTrustAnswer]. A changed key blocks the link (03 §4.6); the
///   user's next connect to the blocked server asks again with the pinned
///   key, which the changed-key review shows beside the new one (D61).
/// - Keyboard-interactive questions are answered with
///   [PromptResponsesAnswer] in question order, or [PromptCancelAnswer]
///   on Cancel.
/// - Admin mode's sudo password (SAF-02) is answered with
///   [PromptSecretAnswer], null on Cancel.
/// - A login password the vault lacks (03 §4.5) is answered with
///   [PromptSecretAnswer], null on Cancel, whose `save` keeps it in the
///   vault when the prompt offered that and the user ticked it.
///
/// A prompt the engine withdraws closes its dialog without an answer. Each
/// dialog is keyed, so only its own route goes, even under another route.
/// What a closed dialog returns is never sent: [PromptController.answer]
/// sends nothing for a prompt no longer open, which it checks once the
/// dialog's await has returned.
class PromptHost extends StatefulWidget {
  const PromptHost({
    super.key,
    required this.prompts,
    this.labelOf,
    required this.child,
  });

  final PromptController prompts;

  /// A fleet server's name, which the password prompt's title shows; the
  /// prompt's host stands in without it.
  final String Function(String serverId)? labelOf;
  final Widget child;

  @override
  State<PromptHost> createState() => _PromptHostState();
}

/// The prompt whose dialog is up, and the key its route is found by.
final class _ShownPrompt {
  _ShownPrompt(this.prompt);

  final Prompt prompt;
  final GlobalKey dialogKey = GlobalKey();

  /// Whether a close waits for the frame that builds the dialog.
  bool closeScheduled = false;
}

class _PromptHostState extends State<PromptHost> {
  _ShownPrompt? _shown;

  /// Set while [_pump] runs: an answer it sends notifies again, and the
  /// running pass moves on to the next prompt itself.
  bool _pumping = false;

  @override
  void initState() {
    super.initState();
    widget.prompts.addListener(_pump);
    // A prompt already waiting is shown once the navigator is built.
    WidgetsBinding.instance.addPostFrameCallback((_) => _pump());
  }

  @override
  void didUpdateWidget(PromptHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(
      widget.prompts == oldWidget.prompts,
      'new controllers come with a new tree (KlabautermannApp, D44)',
    );
  }

  @override
  void dispose() {
    widget.prompts.removeListener(_pump);
    super.dispose();
  }

  /// Brings the dialogs in line with the queue: closes the shown dialog
  /// once its prompt is no longer open, or shows the current prompt while
  /// no dialog is up.
  void _pump() {
    if (_pumping || !mounted) return;

    _pumping = true;
    try {
      while (true) {
        final shown = _shown;
        if (shown != null) {
          if (!widget.prompts.isOpen(shown.prompt.promptId)) _close(shown);
          return;
        }

        final current = widget.prompts.current;
        if (current == null) return;
        if (_show(current)) return;
      }
    } finally {
      _pumping = false;
    }
  }

  /// Shows [prompt]'s dialog and returns true, or answers the prompt
  /// without one and returns false.
  bool _show(Prompt prompt) {
    final l10n = AppLocalizations.of(context);
    switch (prompt.request) {
      case final HostKeyPromptRequest request:
        unawaited(
          _ask(prompt, const PromptTrustAnswer(false), (dialogKey) async {
            // A pinned key makes it the changed-key review (D61), which
            // only the user's connect to a blocked server raises.
            final trusted = await showGhostHostKeyDialog(
              context,
              GhostHostKeyPrompt(
                host: prompt.host,
                port: prompt.port,
                keyType: request.keyType,
                fingerprintSha256: request.fingerprintSha256,
                pinnedFingerprintSha256: request.pinnedFingerprintSha256,
                pinnedKeyType: request.pinnedKeyType,
              ),
              strings: _hostKeyStrings(l10n),
              dialogKey: dialogKey,
              monoStyle: _monoStyle,
            );
            return PromptTrustAnswer(trusted);
          }),
        );
        return true;
      case final KeyboardInteractivePromptRequest request:
        unawaited(
          _ask(prompt, const PromptCancelAnswer(), (dialogKey) async {
            final responses = await showGhostKeyboardInteractiveDialog(
              context,
              GhostKeyboardPrompt(
                username: request.user,
                host: prompt.host,
                port: prompt.port,
                name: request.name,
                instruction: request.instruction,
                prompts: request.questions,
              ),
              strings: _keyboardStrings(l10n),
              dialogKey: dialogKey,
            );
            // The dialog cancels with no responses. The engine answers a
            // round without questions itself (03 §10.1), so an empty list
            // is a cancel whenever there are questions.
            return responses.isEmpty && request.questions.isNotEmpty
                ? const PromptCancelAnswer()
                : PromptResponsesAnswer(responses);
          }),
        );
        return true;
      case final ElevationPromptRequest request:
        unawaited(
          _ask(prompt, const PromptSecretAnswer(null), (dialogKey) async {
            final password = await showElevationPasswordDialog(
              context,
              user: request.user,
              host: _endpointHost(prompt.host),
              retry: request.retry,
              dialogKey: dialogKey,
            );
            return PromptSecretAnswer(password);
          }),
        );
        return true;
      case final CredentialPromptRequest request:
        unawaited(
          _ask(prompt, const PromptSecretAnswer(null), (dialogKey) async {
            final reply = await showGhostCredentialDialog(
              context,
              GhostCredentialRequest(
                authMethod: AuthMethod.password,
                endpointLabel:
                    widget.labelOf?.call(prompt.serverId) ??
                    _endpointHost(prompt.host),
                keyField: GhostKeyField.passphraseOnly,
                username: request.user,
                host: prompt.host,
                port: prompt.port,
                offerVaultSave: request.canSave,
              ),
              strings: _credentialStrings(l10n, canSave: request.canSave),
              monoStyle: _monoStyle,
              dialogKey: dialogKey,
            );
            return switch (reply) {
              // Kept only when the engine offered to keep it.
              GhostPasswordReply(:final password, :final saveToVault) =>
                PromptSecretAnswer(
                  password,
                  save: request.canSave && saveToVault,
                ),
              _ => const PromptSecretAnswer(null),
            };
          }),
        );
        return true;
    }
  }

  /// Shows [prompt]'s dialog through [dialog] and sends what it returns,
  /// or [refusal] if the dialog fails, then moves on to the next prompt.
  Future<void> _ask(
    Prompt prompt,
    PromptAnswer refusal,
    Future<PromptAnswer> Function(GlobalKey dialogKey) dialog,
  ) async {
    final shown = _ShownPrompt(prompt);
    _shown = shown;
    PromptAnswer answer;
    try {
      answer = await dialog(shown.dialogKey);
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          context: ErrorDescription('while showing an engine prompt'),
        ),
      );
      // A broken dialog declines, so the attempt does not wait out the
      // expiry and the queue moves on.
      answer = refusal;
    }
    if (!mounted) return;

    _shown = null;
    // The re-check after the await: a prompt withdrawn while its dialog
    // was up, or while it closed, takes no answer, and this sends none.
    widget.prompts.answer(prompt.promptId, answer);
    _pump();
  }

  /// Removes [shown]'s dialog route, which then returns its cancel value.
  void _close(_ShownPrompt shown) {
    final dialogContext = shown.dialogKey.currentContext;
    if (dialogContext == null) {
      // showDialog pushes its route before the dialog builds: a prompt
      // withdrawn in that turn closes after the frame that builds it.
      if (shown.closeScheduled) return;
      shown.closeScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        shown.closeScheduled = false;
        if (mounted && identical(_shown, shown)) _close(shown);
      });
      return;
    }

    // A popped or removed route is no longer active, so closing twice
    // does nothing.
    final route = ModalRoute.of(dialogContext);
    if (route == null || !route.isActive) return;

    // Only this prompt's route goes, even under another route, which a
    // pop would take instead.
    final navigator = Navigator.of(dialogContext);
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The host-key review's words in ARB, for the first-use review and the
/// changed-key one.
GhostHostKeyStrings _hostKeyStrings(AppLocalizations l10n) =>
    GhostHostKeyStrings(
      unknownTitle: l10n.hostKeyUnknownTitle,
      changedTitle: l10n.hostKeyChangedTitle,
      changedWarning: l10n.hostKeyChangedWarning,
      endpoint: (host, port) => l10n.promptEndpoint(_endpointHost(host), port),
      fingerprintLabel: l10n.hostKeyFingerprintLabel,
      newKeyLabel: l10n.hostKeyNewKeyLabel,
      previousLabel: l10n.hostKeyPreviousLabel,
      cancel: l10n.hostKeyCancel,
      trustConnect: l10n.hostKeyTrustConnect,
      trustNewKey: l10n.hostKeyTrustNewKey,
    );

/// The keyboard-interactive dialog's words in ARB. The dialog brackets a
/// bare IPv6 host before the endpoint line sees it.
GhostKeyboardInteractiveStrings _keyboardStrings(AppLocalizations l10n) =>
    GhostKeyboardInteractiveStrings(
      title: l10n.keyboardTitle,
      requestFrom: l10n.keyboardRequestFrom,
      serverMessage: l10n.keyboardServerMessage,
      endpoint: (user, host, port) => user == null
          ? l10n.promptEndpoint(host, port)
          : l10n.promptEndpointWithUser(user, host, port),
      showAnswer: l10n.keyboardShowAnswer,
      hideAnswer: l10n.keyboardHideAnswer,
      cancel: l10n.keyboardCancel,
      submit: l10n.keyboardSubmit,
    );

/// The login password dialog's words in ARB. Only the password form of
/// `ghost_servers`' dialog shows, so the key fields keep their defaults;
/// the line about saving shows only where the prompt offers to save.
GhostCredentialStrings _credentialStrings(
  AppLocalizations l10n, {
  required bool canSave,
}) => GhostCredentialStrings(
  passwordTitle: l10n.credentialTitle,
  explanation: canSave ? l10n.credentialExplanation : null,
  endpoint: (user, host, port) => user == null
      ? l10n.promptEndpoint(_endpointHost(host), port)
      : l10n.promptEndpointWithUser(user, _endpointHost(host), port),
  passwordField: l10n.credentialPassword,
  saveInVault: l10n.credentialSaveInVault,
  cancel: l10n.credentialCancel,
  connect: l10n.credentialConnect,
);

/// The host as the host-key review's endpoint line shows it: a bare IPv6
/// address gains brackets, so its colons cannot be read as the port's, as
/// on the fleet rows and the keyboard-interactive dialog.
String _endpointHost(String host) =>
    host.contains(':') && !host.startsWith('[') ? '[$host]' : host;

/// The key type and fingerprint's face (P10).
final TextStyle _monoStyle = klabautermannMonoStyle;
