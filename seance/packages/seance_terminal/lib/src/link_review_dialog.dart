import 'package:flutter/material.dart';
import 'package:ghost_fonts/ghost_fonts.dart'
    show ghostMonoFontFamilies, ghostMonoFontFamily;

/// What [TerminalLinkReviewDialog] says. The defaults are English; an app
/// with its own strings (Klabautermann's ARB) passes them.
@immutable
class TerminalLinkReviewStrings {
  const TerminalLinkReviewStrings({
    this.title = 'Open this link?',
    this.explanation =
        'The text you chose does not show where this link goes. Open it '
        'only if you trust this site.',
    this.open = 'Open',
    this.cancel = 'Cancel',
  });

  final String title;

  /// Why the dialog asks: the link's text is not its target.
  final String explanation;

  final String open;
  final String cancel;
}

/// Asks before a terminal hyperlink whose text hides its target opens
/// (`TerminalView.onHiddenLinkTap`): shows the host it leads to and the
/// full URL, then Open or Cancel.
///
/// The URL is shown as [Uri.toString] prints it. [Uri] percent-encodes
/// non-ASCII characters, so a right-to-left override or an invisible
/// character in the target shows as an escape rather than disguising it.
class TerminalLinkReviewDialog extends StatelessWidget {
  const TerminalLinkReviewDialog({
    super.key,
    required this.uri,
    this.strings = const TerminalLinkReviewStrings(),
  });

  final Uri uri;
  final TerminalLinkReviewStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final host = uri.host;
    return AlertDialog(
      title: Text(strings.title),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(strings.explanation),
            if (host.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(host, style: theme.textTheme.titleMedium),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SelectableText(
                uri.toString(),
                // The family's shared monospace stack: a bare 'monospace'
                // resolves only on Android and Linux.
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: ghostMonoFontFamily,
                  fontFamilyFallback: ghostMonoFontFamilies,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        // Cancel holds the initial focus, so Enter takes the safe answer.
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context, false),
          child: Text(strings.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(strings.open),
        ),
      ],
    );
  }
}

/// Shows [TerminalLinkReviewDialog] for [uri] over [context]. True when the
/// user chose Open; a dismissed dialog opens nothing.
Future<bool> showTerminalLinkReview(
  BuildContext context,
  Uri uri, {
  TerminalLinkReviewStrings strings = const TerminalLinkReviewStrings(),
}) async {
  final open = await showDialog<bool>(
    context: context,
    builder: (context) => TerminalLinkReviewDialog(uri: uri, strings: strings),
  );
  return open ?? false;
}
