/// The trust-on-first-use host-key prompt Séance and Poltergeist raise
/// before they connect: a review of a host's first key, or a hard block on
/// a key that no longer matches the pinned one.
///
/// Neither app's truth types cross this boundary. Séance's
/// `HostKeyDecision` lives in `seance_core` and Poltergeist's
/// `HostKeyPromptData` in its engine protocol, so each app maps its own
/// onto [GhostHostKeyPrompt] in its adapter. Wording comes in through
/// [GhostHostKeyStrings], the fingerprint face as the host's monospace
/// style (docs/design/ghost-servers-part1.md §3 to §5).
library;

import 'package:flutter/material.dart';

/// What the prompt shows: the endpoint, the key it presented, and the
/// fingerprint pinned for that endpoint when there is one.
final class GhostHostKeyPrompt {
  const GhostHostKeyPrompt({
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprintSha256,
    this.pinnedFingerprintSha256,
    this.pinnedKeyType,
  });

  final String host;
  final int port;

  /// The presented key's algorithm, such as `ssh-ed25519`.
  final String keyType;

  /// The presented key's `SHA256:...` fingerprint.
  final String fingerprintSha256;

  /// The pinned key's fingerprint. Set, it makes this the changed-key
  /// review ([isChanged]).
  final String? pinnedFingerprintSha256;

  /// The pinned key's algorithm, where the host knows it. The review
  /// labels the pinned fingerprint with [keyType] when this is null:
  /// Séance passes its pinned key's type, Poltergeist's engine payload
  /// carries none.
  final String? pinnedKeyType;

  /// Whether this is the changed-key review rather than a first use.
  ///
  /// A pinned fingerprint means a changed key only because trusted
  /// decisions never reach the dialog: `seance_core`'s host-key check
  /// connects without asking when the presented key matches the pinned
  /// one, and a first use has no pin (docs/design/ghost-servers-part1.md
  /// §7.2). A caller that ever prompts for a key matching its pin must
  /// leave [pinnedFingerprintSha256] null.
  bool get isChanged => pinnedFingerprintSha256 != null;
}

/// The prompt's words, as one bag. The defaults are Séance's, so Séance
/// passes nothing; a host with localized copy passes its own.
final class GhostHostKeyStrings {
  const GhostHostKeyStrings({
    this.unknownTitle = 'Unknown host key',
    this.changedTitle = 'HOST KEY CHANGED',
    this.changedWarning = _changedWarning,
    this.endpoint = _endpoint,
    this.fingerprintLabel = 'Fingerprint',
    this.newKeyLabel = 'New key',
    this.previousLabel = 'Previously trusted',
    this.cancel = 'Cancel',
    this.trustConnect = 'Trust and connect',
    this.trustNewKey = 'Trust the new key',
  });

  /// The first-use title.
  final String unknownTitle;

  /// The changed-key title.
  final String changedTitle;

  /// The changed-key warning about `host`.
  final String Function(String host) changedWarning;

  /// The endpoint line, from the host as configured (no IPv6 brackets) and
  /// the port.
  final String Function(String host, int port) endpoint;

  /// The label over a first use's fingerprint.
  final String fingerprintLabel;

  /// The labels over a changed key's presented and pinned fingerprints.
  final String newKeyLabel;
  final String previousLabel;

  /// The verb that declines.
  final String cancel;

  /// The verbs that trust a first-use key and a changed key.
  final String trustConnect;
  final String trustNewKey;
}

String _changedWarning(String host) =>
    'The key for $host does not match the '
    'one you previously trusted. This can mean a man-in-the-middle '
    'attack. Only continue if you know why the key changed.';

String _endpoint(String host, int port) => '$host:$port';

/// Shows the trust-on-first-use prompt. On a *changed* key this is a hard,
/// visually alarming block that requires explicit re-pinning — never a
/// one-click dismiss. Returns true to trust (and pin) the presented key.
///
/// [monoStyle] is the host's monospace stack for the key type and
/// fingerprint; the dialog sets the size. [dialogKey] keys the dialog, so a
/// host that withdraws a prompt can find its route.
Future<bool> showGhostHostKeyDialog(
  BuildContext context,
  GhostHostKeyPrompt prompt, {
  GhostHostKeyStrings strings = const GhostHostKeyStrings(),
  GlobalKey? dialogKey,
  required TextStyle monoStyle,
}) async {
  final changed = prompt.isChanged;
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      // Only the dialog's own route may be popped: a rapid second activation
      // during the exit animation — or a callback from a dialog obscured by a
      // newer route — would otherwise pop whatever sits below instead.
      void close(bool accepted) {
        if (ModalRoute.of(context)?.isCurrent != true) return;
        Navigator.pop(context, accepted);
      }

      return AlertDialog(
        key: dialogKey,
        // The changed-key review (warning + two fingerprints) must stay
        // reachable when height is scarce — small windows, split screens, or
        // accessibility text scaling — instead of overflowing the dialog.
        scrollable: true,
        icon: Icon(
          changed ? Icons.gpp_bad : Icons.verified_user_outlined,
          color: changed ? scheme.error : null,
        ),
        title: Text(changed ? strings.changedTitle : strings.unknownTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (changed)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  strings.changedWarning(prompt.host),
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
            Text(strings.endpoint(prompt.host, prompt.port)),
            const SizedBox(height: 8),
            _Fingerprint(
              label: changed ? strings.newKeyLabel : strings.fingerprintLabel,
              type: prompt.keyType,
              value: prompt.fingerprintSha256,
              monoStyle: monoStyle,
            ),
            if (changed) ...[
              const SizedBox(height: 8),
              _Fingerprint(
                label: strings.previousLabel,
                type: prompt.pinnedKeyType ?? prompt.keyType,
                value: prompt.pinnedFingerprintSha256!,
                monoStyle: monoStyle,
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => close(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            style: changed
                ? FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  )
                : null,
            onPressed: () => close(true),
            child: Text(changed ? strings.trustNewKey : strings.trustConnect),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

class _Fingerprint extends StatelessWidget {
  final String label;
  final String type;
  final String value;
  final TextStyle monoStyle;

  const _Fingerprint({
    required this.label,
    required this.type,
    required this.value,
    required this.monoStyle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        SelectableText(
          '$type\n$value',
          style: monoStyle.copyWith(fontSize: 12),
        ),
      ],
    );
  }
}
