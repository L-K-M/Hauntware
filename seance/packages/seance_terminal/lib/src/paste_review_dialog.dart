import 'package:flutter/material.dart';

import 'paste_policy.dart';

/// What [TerminalPasteReviewDialog] says. The defaults are English; an app
/// with its own strings (Klabautermann's ARB) passes them.
@immutable
class TerminalPasteReviewStrings {
  const TerminalPasteReviewStrings({
    this.title = _englishTitle,
    this.findings =
        'Some of these lines look dangerous. Each line runs as you paste it.',
    this.unchecked =
        'These lines could not be checked. Each line runs as you paste it.',
    this.unbracketed =
        'This shell runs each line as it arrives. Check them before you '
        'paste.',
    this.finding = _englishFinding,
    this.pasteAll = 'Paste all',
    this.firstLineOnly = 'First line only',
    this.cancel = 'Cancel',
  });

  /// The title for a paste of this many lines.
  final String Function(int lineCount) title;

  /// Above the findings, when the linter flagged some.
  final String findings;

  /// In their place, when the linter could not check the text.
  final String unchecked;

  /// In their place, when the linter found nothing but the remote has
  /// bracketed paste off.
  final String unbracketed;

  /// One finding: its line, counted from 1, and what it does.
  final String Function(int line, String explanation) finding;

  final String pasteAll;
  final String firstLineOnly;
  final String cancel;

  static String _englishTitle(int lineCount) =>
      lineCount == 1 ? 'Paste 1 line?' : 'Paste $lineCount lines?';

  static String _englishFinding(int line, String explanation) =>
      'Line $line: $explanation';
}

/// Asks about a multi-line paste the linter flagged, could not check, or
/// that the remote would run line by line ([TerminalPastePolicy.confirm]):
/// paste everything, the first line only, or nothing.
class TerminalPasteReviewDialog extends StatelessWidget {
  const TerminalPasteReviewDialog({
    super.key,
    required this.review,
    this.strings = const TerminalPasteReviewStrings(),
  });

  final TerminalPasteReview review;
  final TerminalPasteReviewStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final findings = review.findings;
    return AlertDialog(
      title: Text(strings.title(review.lineCount)),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(switch (findings) {
              null => strings.unchecked,
              [] => strings.unbracketed,
              _ => strings.findings,
            }),
            for (final finding in findings ?? const <TerminalPasteFinding>[])
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  strings.finding(finding.line, finding.explanation),
                  style: TextStyle(
                    color: finding.severity == TerminalPasteSeverity.critical
                        ? theme.colorScheme.error
                        : null,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, TerminalPasteChoice.cancel),
          child: Text(strings.cancel),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, TerminalPasteChoice.firstLineOnly),
          child: Text(strings.firstLineOnly),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, TerminalPasteChoice.pasteAll),
          child: Text(strings.pasteAll),
        ),
      ],
    );
  }
}

/// Shows [TerminalPasteReviewDialog] over [context]; a dismissed dialog
/// pastes nothing.
Future<TerminalPasteChoice> showTerminalPasteReview(
  BuildContext context,
  TerminalPasteReview review, {
  TerminalPasteReviewStrings strings = const TerminalPasteReviewStrings(),
}) async {
  final choice = await showDialog<TerminalPasteChoice>(
    context: context,
    builder: (context) =>
        TerminalPasteReviewDialog(review: review, strings: strings),
  );
  return choice ?? TerminalPasteChoice.cancel;
}
