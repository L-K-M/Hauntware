import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToastIn;

/// The log view's words. The defaults are Séance's; a host with localized
/// copy passes its own.
final class GhostConnectionLogStrings {
  const GhostConnectionLogStrings({
    this.title = 'Connection log',
    this.copy = 'Copy',
    this.copied = 'Log copied',
    this.copyFailed = 'Could not copy the log',
    this.empty = '(no log captured)',
  });

  final String title;
  final String copy;

  /// The toasts after a copy that landed and one that failed.
  final String copied;
  final String copyFailed;

  /// Shown in place of an empty transcript.
  final String empty;
}

/// A collapsible view of a raw SSH connection transcript, with a copy button
/// (docs/design/ghost-servers-part1.md, section 5).
///
/// Takes the text rather than a session so every place that shows a
/// transcript (a failed terminal tab, the server editor's connection test, a
/// connection status panel) reads the same, including the empty placeholder
/// and the copy affordance people reach for when they are about to paste it
/// into a bug report.
///
/// Redaction is the producer's contract, not this widget's: [text] is copied
/// and rendered verbatim, so anything a person typed into an auth prompt (a
/// password, a key passphrase, a keyboard-interactive answer) must never
/// have reached it. `SshConnectionLog` is where that is enforced, at capture
/// rather than at render, precisely so every view of a transcript inherits it
/// without knowing to. That is also why this takes a `String` and nothing
/// richer.
class GhostConnectionLogView extends StatelessWidget {
  const GhostConnectionLogView({
    super.key,
    required this.text,
    required this.monoStyle,
    this.strings = const GhostConnectionLogStrings(),
    this.reverse = false,
    this.onCopy,
    this.onCopyError,
  });

  final String text;

  /// The host's fixed-width face; the transcript draws it at 12 points.
  final TextStyle monoStyle;

  final GhostConnectionLogStrings strings;

  /// Whether the transcript scrolls from its end, newest line in view
  /// (Poltergeist's status panel), with no horizontal scroll.
  final bool reverse;

  /// Replaces the default copy (to the clipboard, then a toast saying how it
  /// went) when set.
  final Future<void> Function()? onCopy;

  /// Told why a default copy failed, for the report that follows the toast.
  final void Function(Object error, StackTrace stackTrace)? onCopyError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = SelectableText(
      text.isEmpty ? strings.empty : text,
      // Fixed-width on every platform: a transcript whose columns do not
      // line up is the thing this view exists to avoid.
      style: monoStyle.copyWith(fontSize: 12, height: 1.4),
    );
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(strings.title),
        childrenPadding: EdgeInsets.zero,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: text.isEmpty ? null : (onCopy ?? () => _copy(context)),
              icon: const Icon(Icons.copy, size: 16),
              label: Text(strings.copy),
            ),
          ),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 260),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: reverse
                ? SingleChildScrollView(reverse: true, child: shown)
                : SingleChildScrollView(
                    // Horizontally too: a transcript carries long unbreakable
                    // runs (algorithm lists, base64 key material) that
                    // soft-wrap nowhere, and on a narrow layout their tails
                    // painted past the card with no way to reach them, the
                    // part a bug report needs.
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: shown,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// Awaited, and the toast is gated on the result landing while this is
  /// still on screen: saying "copied" for a write that failed sends someone
  /// to paste an empty bug report.
  Future<void> _copy(BuildContext context) async {
    // The write can fail (no clipboard on the platform, a plugin that is not
    // there), and an unhandled async error is not a report of that.
    var copied = true;
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (error, stackTrace) {
      // The toast says it failed; this says why.
      onCopyError?.call(error, stackTrace);
      copied = false;
    }
    if (context.mounted) {
      showTopToastIn(
        context,
        message: copied ? strings.copied : strings.copyFailed,
      );
    }
  }
}
