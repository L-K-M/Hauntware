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
  }) : assert(
         pinnedFingerprintSha256 != fingerprintSha256,
         'A key matching its pin is trusted and never prompts',
       );

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
  /// shows the pinned fingerprint without a type when this is null, since
  /// the presented key's type may not be the pinned one: Séance passes
  /// its pinned key's type, Poltergeist's engine payload carries none.
  final String? pinnedKeyType;

  /// Whether this is the changed-key review rather than a first use.
  ///
  /// A pinned fingerprint means a changed key only because trusted
  /// decisions never reach the dialog: `seance_core`'s host-key check
  /// connects without asking when the presented key matches the pinned
  /// one, and a first use has no pin (docs/design/ghost-servers-part1.md
  /// §7.2). A pin equal to the presented fingerprint is a caller bug and
  /// fails the constructor's assertion.
  bool get isChanged => pinnedFingerprintSha256 != null;
}

/// The prompt's words, as one bag. The defaults are Séance's, so Séance
/// passes nothing; a host with localized copy passes its own.
final class GhostHostKeyStrings {
  const GhostHostKeyStrings({
    this.unknownTitle = 'Unknown host key',
    this.changedTitle = 'HOST KEY CHANGED',
    this.changedWarning = _changedWarning,
    this.changedReviewInstruction = _changedReviewInstruction,
    this.keyTypeChanged = _keyTypeChanged,
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

  /// The instruction that explains why trust starts disabled.
  final String changedReviewInstruction;

  /// The notice shown when both key algorithms are known and differ.
  final String Function(String previous, String presented) keyTypeChanged;

  /// The endpoint line, from the host (a bare IPv6 address already
  /// bracketed) and the port.
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

const _changedReviewInstruction =
    'Review the new and previously trusted fingerprints, then read the '
    'warning below.';

String _keyTypeChanged(String previous, String presented) =>
    'Key algorithm changed from $previous to $presented.';

String _endpoint(String host, int port) => '$host:$port';

/// The host as the endpoint line shows it: a bare IPv6 address gains
/// brackets, so its colons cannot be read as the port separator.
String _displayHost(String host) =>
    host.contains(':') && !(host.startsWith('[') && host.endsWith(']'))
    ? '[$host]'
    : host;

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
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _HostKeyDialog(
      prompt: prompt,
      strings: strings,
      dialogKey: dialogKey,
      monoStyle: monoStyle,
    ),
  );
  return result ?? false;
}

class _HostKeyDialog extends StatefulWidget {
  const _HostKeyDialog({
    required this.prompt,
    required this.strings,
    required this.dialogKey,
    required this.monoStyle,
  });

  final GhostHostKeyPrompt prompt;
  final GhostHostKeyStrings strings;
  final GlobalKey? dialogKey;
  final TextStyle monoStyle;

  @override
  State<_HostKeyDialog> createState() => _HostKeyDialogState();
}

class _HostKeyDialogState extends State<_HostKeyDialog> {
  static const _endTolerance = 1.0;

  late bool _reviewed = !widget.prompt.isChanged;
  bool _reviewScheduled = false;

  void _considerReviewComplete(ScrollMetrics metrics) {
    if (_reviewed || metrics.extentAfter > _endTolerance) return;
    if (_reviewScheduled) return;

    // Scroll notifications arrive after layout. Update in the following frame
    // so a dialog that already fits can enable trust without mutating its tree
    // during layout, and reaching the end while scrolling latches the review.
    _reviewScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reviewScheduled = false;
      if (!mounted || _reviewed) return;
      setState(() => _reviewed = true);
    });
  }

  void _close(bool accepted) {
    if (accepted && widget.prompt.isChanged && !_reviewed) return;
    // Only the dialog's own route may be popped: a rapid second activation
    // during the exit animation — or a callback from a dialog obscured by a
    // newer route — would otherwise pop whatever sits below instead.
    if (ModalRoute.of(context)?.isCurrent != true) return;
    Navigator.pop(context, accepted);
  }

  @override
  Widget build(BuildContext context) {
    final prompt = widget.prompt;
    final strings = widget.strings;
    final changed = prompt.isChanged;
    final scheme = Theme.of(context).colorScheme;
    final previousType = prompt.pinnedKeyType;
    final algorithmChanged =
        changed && previousType != null && previousType != prompt.keyType;

    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 &&
            axisDirectionToAxis(notification.metrics.axisDirection) ==
                Axis.vertical) {
          _considerReviewComplete(notification.metrics);
        }
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.depth == 0 &&
              axisDirectionToAxis(notification.metrics.axisDirection) ==
                  Axis.vertical) {
            _considerReviewComplete(notification.metrics);
          }
          return false;
        },
        child: AlertDialog(
          key: widget.dialogKey,
          // The changed-key review must stay reachable when height is scarce
          // instead of overflowing the dialog. Its pinned actions remain in
          // place while the review itself scrolls.
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
              Text(strings.endpoint(_displayHost(prompt.host), prompt.port)),
              if (changed) ...[
                const SizedBox(height: 8),
                Text(strings.changedReviewInstruction),
              ],
              const SizedBox(height: 8),
              _Fingerprint(
                label: changed ? strings.newKeyLabel : strings.fingerprintLabel,
                type: prompt.keyType,
                value: prompt.fingerprintSha256,
                monoStyle: widget.monoStyle,
              ),
              if (changed) ...[
                const SizedBox(height: 8),
                _Fingerprint(
                  label: strings.previousLabel,
                  type: previousType,
                  value: prompt.pinnedFingerprintSha256!,
                  monoStyle: widget.monoStyle,
                ),
                if (algorithmChanged) ...[
                  const SizedBox(height: 12),
                  Text(
                    strings.keyTypeChanged(previousType, prompt.keyType),
                    style: TextStyle(
                      color: scheme.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(top: 12),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    strings.changedWarning(prompt.host),
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => _close(false),
              child: Text(strings.cancel),
            ),
            FilledButton(
              style: changed
                  ? FilledButton.styleFrom(
                      backgroundColor: scheme.error,
                      foregroundColor: scheme.onError,
                    )
                  : null,
              onPressed: !changed || _reviewed ? () => _close(true) : null,
              child: Text(changed ? strings.trustNewKey : strings.trustConnect),
            ),
          ],
        ),
      ),
    );
  }
}

class _Fingerprint extends StatelessWidget {
  final String label;

  /// Null when the host does not know the key's algorithm.
  final String? type;
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
          type == null ? value : '$type\n$value',
          style: monoStyle.copyWith(fontSize: 12),
        ),
      ],
    );
  }
}
