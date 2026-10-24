import 'package:flutter/foundation.dart';
import 'package:seance_core/seance_core.dart' show PasteSanitizer;

import 'xterm_engine.dart';

/// How much a [TerminalPasteFinding] should worry the user.
enum TerminalPasteSeverity { warning, critical }

/// One thing the host's inspector found in a multi-line paste.
@immutable
final class TerminalPasteFinding {
  const TerminalPasteFinding({
    required this.severity,
    required this.line,
    required this.explanation,
  });

  final TerminalPasteSeverity severity;

  /// The 1-based line of the paste the finding is about.
  final int line;

  /// What the inspector says about it, in the host's words.
  final String explanation;
}

/// A multi-line paste the user is asked about.
@immutable
final class TerminalPasteReview {
  const TerminalPasteReview({
    required this.text,
    required this.lineCount,
    required this.findings,
  });

  final String text;
  final int lineCount;

  /// Null when the inspector failed: unknown, not clean.
  final List<TerminalPasteFinding>? findings;
}

/// The user's answer to a [TerminalPasteReview].
enum TerminalPasteChoice { pasteAll, firstLineOnly, cancel }

/// Pastes text into a terminal so that a line break never runs a command
/// the user has not seen (docs/design/seance-terminal.md 3.3).
///
/// Text without a line break is cleaned of control characters and pasted:
/// it runs only on the user's own Enter, so it is not inspected. Text
/// with line breaks goes to [inspect] first; with no findings it is
/// pasted line by line, cleaned, joined with `\n`. Findings, or an
/// [inspect] that fails, ask [confirm], whose answer pastes everything,
/// the first line only, or nothing. Cleaning each line removes ESC, so a
/// paste cannot end bracketed paste early.
final class TerminalPastePolicy {
  const TerminalPastePolicy({required this.inspect, required this.confirm});

  /// Lints multi-line text; the host fills it.
  final Future<List<TerminalPasteFinding>> Function(String text) inspect;

  /// Asks the user; called only for a multi-line paste with findings, or
  /// when [inspect] failed.
  final Future<TerminalPasteChoice> Function(TerminalPasteReview review)
  confirm;

  static final RegExp _lineBreak = RegExp(r'\r\n|\r|\n');

  /// Pastes [text] into [engine] by the rules above.
  Future<void> paste(XtermTerminalEngine engine, String text) async {
    if (text.isEmpty) return;
    if (!text.contains('\n') && !text.contains('\r')) {
      engine.terminal.paste(PasteSanitizer.sanitize(text));
      return;
    }

    final lines = text.split(_lineBreak);
    List<TerminalPasteFinding>? findings;
    try {
      findings = await inspect(text);
    } on Object {
      findings = null;
    }

    var choice = TerminalPasteChoice.pasteAll;
    if (findings == null || findings.isNotEmpty) {
      choice = await confirm(
        TerminalPasteReview(
          text: text,
          // Text ending in a line break splits into a last empty line.
          lineCount: lines.last.isEmpty ? lines.length - 1 : lines.length,
          findings: findings == null ? null : List.unmodifiable(findings),
        ),
      );
    }

    switch (choice) {
      case TerminalPasteChoice.pasteAll:
        engine.terminal.paste(lines.map(PasteSanitizer.sanitize).join('\n'));
      case TerminalPasteChoice.firstLineOnly:
        engine.terminal.paste(PasteSanitizer.sanitizeFirstLine(text));
      case TerminalPasteChoice.cancel:
        return;
    }
  }
}
