/// The credential prompt Séance and Poltergeist raise when a server's
/// password or private key is not on the device.
///
/// The two apps' prompts were written separately and are not copies
/// (docs/design/ghost-servers-part1.md §1.4, §8.3), so this is one dialog
/// with the key input as its seam rather than a verbatim port. Neither
/// app's truth types cross this boundary: each app describes the prompt as
/// a [GhostCredentialRequest] and maps the [GhostCredentialReply] onto its
/// own answer type in its adapter. File access stays with the host, through
/// the picker or reader it injects, or with the host's own reader behind
/// the [GhostKeyField.passphraseOnly] form. Wording comes in through
/// [GhostCredentialStrings], the key and endpoint face as the host's
/// monospace style (§3 to §5).
library;

import 'package:flutter/material.dart';
import 'package:seance_protocol/seance_protocol.dart' show AuthMethod;

/// How the prompt takes a private key, and with it the rest of the form.
///
/// [pastedPem] and [filePath] are each one app's form as it stood before
/// the move, so each keeps its own details beyond the key input: the
/// layout, the secret fields' input flags, when the answer is enabled, how
/// an error reads and whether the verbs check that the dialog's route is
/// current. Converging them is a behaviour change for its own PR.
/// [passphraseOnly] is new, and decides each of those details itself.
enum GhostKeyField {
  /// Key text pasted into a multi-line field, or filled in from a file the
  /// host picks (`pickKeyText`). Séance's recovery form: a dialog of fixed
  /// width, the answer enabled once the secret is filled in, Enter
  /// answering from the password, and an error announced under the fields.
  pastedPem,

  /// The path of an identity file, which the host reads on submit
  /// (`readKeyFile`). Poltergeist's connect-time form: a scrollable dialog,
  /// suggestions and IME learning off in the secret fields, Enter answering
  /// from the password or passphrase, a spinner while the file is read, and
  /// verbs that act only while the dialog's route is current.
  filePath,

  /// A known identity file, shown by its path
  /// ([GhostCredentialRequest.initialKeyPath]), and only its passphrase
  /// asked for. The host reads the file itself, so no key text crosses into
  /// the dialog or its reply ([GhostKeyPassphraseReply]); no injector is
  /// taken. Klabautermann's form, where the engine reads key files: a
  /// scrollable dialog, suggestions and IME learning off in the secret
  /// field, no reveal toggle (as in the other forms), the answer enabled and
  /// Enter answering only once the secret is typed (a key that has no
  /// passphrase never needs this prompt), and verbs that act only while the
  /// dialog's route is current. A password prompt in this mode is the same
  /// form with a password field.
  passphraseOnly,
}

/// What the prompt asks for, and about which server.
final class GhostCredentialRequest {
  const GhostCredentialRequest({
    required this.authMethod,
    required this.endpointLabel,
    required this.keyField,
    this.username,
    this.host,
    this.port,
    this.initialKeyPath,
    this.offerVaultSave = false,
    this.vaultUnavailable = false,
  }) : assert((host == null) == (port == null), 'host and port go together');

  /// The server's configured method: [AuthMethod.privateKey] asks for a key
  /// and its passphrase, any other method for a password. Neither app
  /// raises the prompt for agent authentication.
  final AuthMethod authMethod;

  /// The server as the title names it.
  final String endpointLabel;

  /// How a private key is entered.
  final GhostKeyField keyField;

  /// The endpoint line under the title, shown when [host] is set: the
  /// account where the host knows it, the host as configured and the port.
  final String? username;
  final String? host;
  final int? port;

  /// The identity file path a [GhostKeyField.filePath] field starts with,
  /// or the one a [GhostKeyField.passphraseOnly] key prompt shows, where it
  /// is required.
  final String? initialKeyPath;

  /// Whether to offer keeping the answer in the host's vault
  /// ([GhostCredentialReply.saveToVault]). Never offered while
  /// [vaultUnavailable].
  final bool offerVaultSave;

  /// Whether the host's vault could not be read. A banner says so, the
  /// save offer is withheld, and manual entry stays open.
  final bool vaultUnavailable;
}

/// What the user answered: exactly one secret shape. Each host maps it onto
/// its own answer type.
sealed class GhostCredentialReply {
  const GhostCredentialReply({required this.saveToVault});

  /// Whether the user asked to keep the answer in the host's vault. Only
  /// ever true when the request offered it.
  final bool saveToVault;
}

/// The server's password.
final class GhostPasswordReply extends GhostCredentialReply {
  const GhostPasswordReply(this.password, {super.saveToVault = false});

  final String password;
}

/// The private key's text, pasted, picked or read from the identity file,
/// and its passphrase. Never the answer to a [GhostKeyField.passphraseOnly]
/// prompt.
final class GhostPrivateKeyReply extends GhostCredentialReply {
  const GhostPrivateKeyReply(
    this.privateKeyPem, {
    this.keyPassphrase,
    super.saveToVault = false,
  });

  final String privateKeyPem;

  /// The typed passphrase; null when none was typed, never empty.
  final String? keyPassphrase;
}

/// The passphrase alone, for the identity file a
/// [GhostKeyField.passphraseOnly] prompt showed. The host knows the file and
/// reads it itself; no key text rides this reply.
final class GhostKeyPassphraseReply extends GhostCredentialReply {
  const GhostKeyPassphraseReply(this.keyPassphrase, {super.saveToVault = false})
    : assert(keyPassphrase != '', 'the prompt answers only once typed');

  /// The typed passphrase, never empty.
  final String keyPassphrase;
}

/// The prompt's words, as one bag. The defaults are Séance's, so Séance
/// passes nothing; a host with localized copy passes its own. The members
/// only the [GhostKeyField.filePath] and [GhostKeyField.passphraseOnly]
/// forms or the vault offer use default to plain English, since Séance has
/// no words for them.
final class GhostCredentialStrings {
  const GhostCredentialStrings({
    this.passwordTitle = _passwordTitle,
    this.privateKeyTitle = _privateKeyTitle,
    this.keyPassphraseTitle = _keyPassphraseTitle,
    this.explanation =
        'Saved on this device, in its encrypted vault, and used for '
        'this server from now on.',
    this.endpoint = _endpoint,
    this.vaultUnavailable =
        'Saved secrets are unavailable. You can still enter the secret '
        'below.',
    this.passwordField = 'Password',
    this.chooseKeyFile = 'Choose key file…',
    this.keyPemField = 'Private key (PEM)',
    this.keyPemHint = _opensshPemHeader,
    this.keyFileField = 'Key file',
    this.keyFileRequired = 'Choose a key file.',
    this.keyFileError = _keyFileError,
    this.passphraseField = 'Key passphrase (if it has one)',
    this.keyPassphraseField = 'Passphrase',
    this.saveInVault = 'Save in vault',
    this.cancel = 'Cancel',
    this.connect = 'Save and connect',
  });

  /// The titles over a password, a private-key and a
  /// [GhostKeyField.passphraseOnly] key prompt, from the request's
  /// [GhostCredentialRequest.endpointLabel].
  final String Function(String label) passwordTitle;
  final String Function(String label) privateKeyTitle;
  final String Function(String label) keyPassphraseTitle;

  /// The line under the title saying what happens to the answer; null for
  /// none.
  final String? explanation;

  /// The endpoint line, from the username where there is one, the host as
  /// configured (no IPv6 brackets) and the port.
  final String Function(String? username, String host, int port) endpoint;

  /// The banner shown when the host's vault could not be read.
  final String vaultUnavailable;

  /// The password field's label.
  final String passwordField;

  /// The [GhostKeyField.pastedPem] form's file button, and its key field's
  /// label and hint.
  final String chooseKeyFile;
  final String keyPemField;
  final String keyPemHint;

  /// The [GhostKeyField.filePath] form's path label, which also labels the
  /// path a [GhostKeyField.passphraseOnly] prompt shows, and the error for
  /// an empty path.
  final String keyFileField;
  final String keyFileRequired;

  /// The error for key material that could not be read: `error` is what
  /// the host's picker or reader threw. The host decides what of it may be
  /// shown; the default shows a [FormatException]'s message, which
  /// Séance's picker words for the user, and nothing of any other error.
  final String Function(Object error) keyFileError;

  /// The passphrase field's label where a passphrase is optional.
  final String passphraseField;

  /// The [GhostKeyField.passphraseOnly] form's passphrase label, where the
  /// passphrase is the whole answer.
  final String keyPassphraseField;

  /// The vault offer's label.
  final String saveInVault;

  /// The verbs that decline and answer.
  final String cancel;
  final String connect;
}

String _passwordTitle(String label) => 'Password for $label';

String _privateKeyTitle(String label) => 'Private key for $label';

String _keyPassphraseTitle(String label) => 'Key passphrase for $label';

String _endpoint(String? username, String host, int port) =>
    username == null ? '$host:$port' : '$username@$host:$port';

// Split so the package carries no private-key header
// (scripts/assert-private-keys-scoped.sh); the hint reads as one line.
const _opensshPemHeader =
    '-----BEGIN OPENSSH'
    ' PRIVATE KEY-----';

String _keyFileError(Object error) =>
    error is FormatException ? error.message : 'That file could not be opened.';

/// Asks for the credential [request] describes: the server's password, its
/// private key and passphrase, or a known key's passphrase alone. Null when
/// the user cancels.
///
/// The injector matching [GhostCredentialRequest.keyField] is required:
/// [GhostKeyField.pastedPem] fills its key field through [pickKeyText],
/// which answers the picked file's text or null for a cancelled pick;
/// [GhostKeyField.filePath] reads the typed path through [readKeyFile]. A
/// missing one throws [ArgumentError] before the dialog opens; the other is
/// ignored. Either may throw: the dialog stays open and shows
/// [GhostCredentialStrings.keyFileError].
///
/// [GhostKeyField.passphraseOnly] takes neither: the host reads the key, so
/// passing either throws [ArgumentError], as does a key prompt without a
/// [GhostCredentialRequest.initialKeyPath] to show.
///
/// [monoStyle] is the host's monospace stack for the key text and the
/// endpoint line; the dialog sets the size. [dialogKey] keys the dialog, so
/// a host that withdraws a prompt can find its route. [barrierDismissible]
/// lets a tap outside the dialog cancel it; Séance passes true, as its
/// prompt always closed that way.
Future<GhostCredentialReply?> showGhostCredentialDialog(
  BuildContext context,
  GhostCredentialRequest request, {
  GhostCredentialStrings strings = const GhostCredentialStrings(),
  Future<String?> Function()? pickKeyText,
  Future<String> Function(String path)? readKeyFile,
  required TextStyle monoStyle,
  GlobalKey? dialogKey,
  bool barrierDismissible = false,
}) {
  final missingInjector = switch (request.keyField) {
    GhostKeyField.pastedPem => pickKeyText == null ? 'pickKeyText' : null,
    GhostKeyField.filePath => readKeyFile == null ? 'readKeyFile' : null,
    GhostKeyField.passphraseOnly => null,
  };
  if (missingInjector != null) {
    throw ArgumentError.value(
      null,
      missingInjector,
      '${request.keyField} needs it to take a private key',
    );
  }

  if (request.keyField == GhostKeyField.passphraseOnly) {
    // Rejected rather than ignored: a host that hands this form a picker or
    // reader expects key text back, and this form never takes any.
    final unwantedInjector = pickKeyText != null
        ? 'pickKeyText'
        : readKeyFile != null
        ? 'readKeyFile'
        : null;
    if (unwantedInjector != null) {
      throw ArgumentError(
        '${request.keyField} reads no key; the host does',
        unwantedInjector,
      );
    }

    final keyPath = request.initialKeyPath;
    if (request.authMethod == AuthMethod.privateKey &&
        (keyPath == null || keyPath.isEmpty)) {
      throw ArgumentError.value(
        keyPath,
        'initialKeyPath',
        '${request.keyField} shows the key it asks about',
      );
    }
  }

  return showDialog<GhostCredentialReply>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (_) => _CredentialDialog(
      key: dialogKey,
      request: request,
      strings: strings,
      pickKeyText: pickKeyText,
      readKeyFile: readKeyFile,
      monoStyle: monoStyle,
    ),
  );
}

class _CredentialDialog extends StatefulWidget {
  const _CredentialDialog({
    super.key,
    required this.request,
    required this.strings,
    required this.pickKeyText,
    required this.readKeyFile,
    required this.monoStyle,
  });

  final GhostCredentialRequest request;
  final GhostCredentialStrings strings;

  /// Set for [GhostKeyField.pastedPem], [readKeyFile] for
  /// [GhostKeyField.filePath], neither for [GhostKeyField.passphraseOnly];
  /// [showGhostCredentialDialog] checks them.
  final Future<String?> Function()? pickKeyText;
  final Future<String> Function(String path)? readKeyFile;

  final TextStyle monoStyle;

  @override
  State<_CredentialDialog> createState() => _CredentialDialogState();
}

class _CredentialDialogState extends State<_CredentialDialog> {
  /// The password, the pasted key's text, or the passphrase alone.
  final _secret = TextEditingController();
  late final _keyPath = TextEditingController(
    text: widget.request.initialKeyPath ?? '',
  );
  final _passphrase = TextEditingController();
  bool _saveToVault = false;

  /// Whether a [GhostKeyField.filePath] read is in flight.
  bool _readingKey = false;
  String? _error;

  bool get _isKey => widget.request.authMethod == AuthMethod.privateKey;

  bool get _isCurrentRoute => ModalRoute.of(context)?.isCurrent == true;

  @override
  void dispose() {
    _secret.dispose();
    _keyPath.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  GhostCredentialReply _reply(String secret) => _isKey
      ? GhostPrivateKeyReply(
          secret,
          keyPassphrase: _passphrase.text.isEmpty ? null : _passphrase.text,
          saveToVault: _saveToVault,
        )
      : GhostPasswordReply(secret, saveToVault: _saveToVault);

  void _cancel() {
    // Séance's form never checked its route before cancelling.
    final checksRoute = switch (widget.request.keyField) {
      GhostKeyField.pastedPem => false,
      GhostKeyField.filePath || GhostKeyField.passphraseOnly => true,
    };
    if (checksRoute && !_isCurrentRoute) return;

    Navigator.pop(context);
  }

  Future<void> _chooseKeyFile() async {
    try {
      final text = await widget.pickKeyText!();
      if (text == null || !mounted) return;
      setState(() {
        _secret.text = text;
        _error = null;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = widget.strings.keyFileError(error));
    }
  }

  void _savePasted() {
    final secret = _secret.text;
    if (secret.isEmpty) return;
    Navigator.pop<GhostCredentialReply>(context, _reply(secret));
  }

  Future<void> _submitPath() async {
    if (_readingKey || !_isCurrentRoute) return;

    if (!_isKey) {
      Navigator.pop<GhostCredentialReply>(context, _reply(_secret.text));
      return;
    }

    final path = _keyPath.text.trim();
    if (path.isEmpty) {
      setState(() => _error = widget.strings.keyFileRequired);
      return;
    }

    setState(() {
      _readingKey = true;
      _error = null;
    });
    final String pem;
    try {
      pem = await widget.readKeyFile!(path);
    } on Object catch (error) {
      if (!mounted || !_isCurrentRoute) return;
      setState(() {
        _readingKey = false;
        _error = widget.strings.keyFileError(error);
      });
      return;
    }
    // The await window is exactly when a dismissal can pop this route; a
    // pop from a non-current route would dismiss whatever stacked on top
    // instead. Pop only while this dialog is still the top route.
    if (!mounted || !_isCurrentRoute) return;
    Navigator.pop<GhostCredentialReply>(context, _reply(pem));
  }

  void _submitSecretOnly() {
    final secret = _secret.text;
    if (secret.isEmpty || !_isCurrentRoute) return;

    Navigator.pop<GhostCredentialReply>(
      context,
      _isKey
          ? GhostKeyPassphraseReply(secret, saveToVault: _saveToVault)
          : GhostPasswordReply(secret, saveToVault: _saveToVault),
    );
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final strings = widget.strings;
    final scheme = Theme.of(context).colorScheme;
    final mono = widget.monoStyle.copyWith(fontSize: 12);
    final host = request.host;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (strings.explanation case final explanation?) Text(explanation),
        if (host != null)
          SelectableText(
            strings.endpoint(request.username, host, request.port!),
            style: mono,
          ),
        if (request.vaultUnavailable) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              strings.vaultUnavailable,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
        const SizedBox(height: 12),
        ...switch (request.keyField) {
          GhostKeyField.pastedPem => _pastedFields(mono, scheme),
          GhostKeyField.filePath => _pathFields(scheme),
          GhostKeyField.passphraseOnly => _passphraseOnlyFields(mono),
        },
        if (request.offerVaultSave && !request.vaultUnavailable)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _saveToVault,
            onChanged: (value) => setState(() {
              _saveToVault = value ?? false;
            }),
            title: Text(strings.saveInVault),
          ),
      ],
    );
    final title = Text(switch ((_isKey, request.keyField)) {
      (false, _) => strings.passwordTitle(request.endpointLabel),
      (true, GhostKeyField.pastedPem || GhostKeyField.filePath) =>
        strings.privateKeyTitle(request.endpointLabel),
      (true, GhostKeyField.passphraseOnly) => strings.keyPassphraseTitle(
        request.endpointLabel,
      ),
    });
    final cancel = TextButton(onPressed: _cancel, child: Text(strings.cancel));

    return switch (request.keyField) {
      GhostKeyField.pastedPem => AlertDialog(
        title: title,
        // Room for a pasted key; the fields scroll inside when height is
        // scarce.
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(child: content),
        ),
        actions: [
          cancel,
          FilledButton(
            key: const ValueKey('credential.save'),
            onPressed: _secret.text.isEmpty ? null : _savePasted,
            child: Text(strings.connect),
          ),
        ],
      ),
      GhostKeyField.filePath => AlertDialog(
        scrollable: true,
        title: title,
        content: content,
        actions: [
          cancel,
          FilledButton(
            key: const ValueKey('credential.save'),
            onPressed: _readingKey ? null : _submitPath,
            child: _readingKey
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(strings.connect),
          ),
        ],
      ),
      GhostKeyField.passphraseOnly => AlertDialog(
        scrollable: true,
        title: title,
        content: content,
        actions: [
          cancel,
          FilledButton(
            key: const ValueKey('credential.save'),
            onPressed: _secret.text.isEmpty ? null : _submitSecretOnly,
            child: Text(strings.connect),
          ),
        ],
      ),
    };
  }

  List<Widget> _pastedFields(TextStyle mono, ColorScheme scheme) {
    final strings = widget.strings;
    final error = _error;
    return [
      if (_isKey) ...[
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            key: const ValueKey('credential.chooseFile'),
            onPressed: _chooseKeyFile,
            icon: const Icon(Icons.file_open_outlined),
            label: Text(strings.chooseKeyFile),
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
          style: mono,
          decoration: InputDecoration(
            labelText: strings.keyPemField,
            hintText: strings.keyPemHint,
          ),
          onChanged: (_) => setState(() {}),
        ),
        TextField(
          key: const ValueKey('credential.passphrase'),
          controller: _passphrase,
          obscureText: true,
          decoration: InputDecoration(labelText: strings.passphraseField),
        ),
      ] else
        TextField(
          key: const ValueKey('credential.password'),
          controller: _secret,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(labelText: strings.passwordField),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _savePasted(),
        ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Semantics(
            liveRegion: true,
            child: Text(error, style: TextStyle(color: scheme.error)),
          ),
        ),
    ];
  }

  List<Widget> _pathFields(ColorScheme scheme) {
    final strings = widget.strings;
    final error = _error;
    return [
      if (_isKey) ...[
        TextField(
          key: const ValueKey('credential.keyFile'),
          controller: _keyPath,
          autofocus: true,
          onChanged: (_) {
            if (_error == null) return;
            setState(() => _error = null);
          },
          decoration: InputDecoration(labelText: strings.keyFileField),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('credential.passphrase'),
          controller: _passphrase,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          onSubmitted: (_) => _submitPath(),
          decoration: InputDecoration(labelText: strings.passphraseField),
        ),
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(error, style: TextStyle(color: scheme.error)),
        ],
      ] else
        TextField(
          key: const ValueKey('credential.password'),
          controller: _secret,
          autofocus: true,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          onSubmitted: (_) => _submitPath(),
          decoration: InputDecoration(labelText: strings.passwordField),
        ),
    ];
  }

  List<Widget> _passphraseOnlyFields(TextStyle mono) {
    final strings = widget.strings;
    return [
      if (_isKey) ...[
        InputDecorator(
          key: const ValueKey('credential.keyPath'),
          decoration: InputDecoration(labelText: strings.keyFileField),
          child: SelectableText(widget.request.initialKeyPath!, style: mono),
        ),
        const SizedBox(height: 8),
      ],
      TextField(
        key: ValueKey(_isKey ? 'credential.passphrase' : 'credential.password'),
        controller: _secret,
        autofocus: true,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submitSecretOnly(),
        decoration: InputDecoration(
          labelText: _isKey
              ? strings.keyPassphraseField
              : strings.passwordField,
        ),
      ),
    ];
  }
}
