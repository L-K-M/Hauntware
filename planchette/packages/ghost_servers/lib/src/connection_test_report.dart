import 'package:flutter/material.dart';

import 'connection_log_view.dart';

/// What a "Test connection" attempt found, as the host's connection test
/// reports it (docs/design/ghost-servers-part1.md, section 3): field for
/// field the core's `ConnectionTestResult`.
final class GhostTestReport {
  const GhostTestReport({
    required this.ok,
    required this.summary,
    required this.log,
    this.notes = const [],
  });

  final bool ok;
  final String summary;

  /// Caveats on [summary], shown whatever the outcome.
  final List<String> notes;

  /// The redacted transcript.
  final String log;
}

/// The report's spoken outcomes. The defaults are Séance's.
final class GhostConnectionTestStrings {
  const GhostConnectionTestStrings({
    this.succeeded = 'Connection test succeeded',
    this.failed = 'Connection test failed',
  });

  final String succeeded;
  final String failed;
}

/// What a "Test connection" attempt found, as the server editor shows it.
///
/// Public and standalone so a widget test can assert what each outcome reads
/// like without standing up an editor. The failure path matters most: it is
/// met when something is already wrong, so it has to say *what* rather than
/// only that the test failed, and it shows the same summary a real failed
/// connection does, from the same source, so the two can never disagree
/// about one host.
class GhostConnectionTestReport extends StatelessWidget {
  const GhostConnectionTestReport({
    super.key,
    required this.report,
    required this.monoStyle,
    this.strings = const GhostConnectionTestStrings(),
    this.logStrings = const GhostConnectionLogStrings(),
    this.onCopyError,
  });

  final GhostTestReport report;

  /// The transcript's fixed-width face.
  final TextStyle monoStyle;

  final GhostConnectionTestStrings strings;
  final GhostConnectionLogStrings logStrings;

  /// Told why copying the transcript failed.
  final void Function(Object error, StackTrace stackTrace)? onCopyError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = report.ok ? scheme.primary : scheme.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              report.ok ? Icons.check_circle_outline : Icons.error_outline,
              size: 18,
              color: accent,
              // The colours differ by hue alone, which is the one difference
              // some readers do not get; the icon is named so the outcome is
              // also spoken.
              semanticLabel: report.ok ? strings.succeeded : strings.failed,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                report.summary,
                style: theme.textTheme.bodyMedium?.copyWith(color: accent),
              ),
            ),
          ],
        ),
        for (final note in report.notes) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 26),
            child: SelectableText(
              note,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
        const SizedBox(height: 4),
        GhostConnectionLogView(
          text: report.log,
          monoStyle: monoStyle,
          strings: logStrings,
          onCopyError: onCopyError,
        ),
      ],
    );
  }
}
