import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/operations_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';

/// JOB-19's output (03 §7.7): how the cron line's run [planId] ended and
/// what it printed, redacted and capped by the engine, in a bottom sheet
/// that waits for the run's end. [title] is the target the preview named.
Future<void> showCronRunOutput(
  BuildContext context, {
  required OperationsController operations,
  required String planId,
  required String title,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.6,
    minChildSize: 0.3,
    maxChildSize: 1,
    builder: (context, scroll) => ListenableBuilder(
      listenable: operations,
      builder: (context, _) => CronRunOutput(
        state: operations.runOf(planId),
        title: title,
        scroll: scroll,
      ),
    ),
  ),
);

/// A cron run's [state] and output; nothing animates while it runs
/// (A11Y-11).
class CronRunOutput extends StatelessWidget {
  const CronRunOutput({
    super.key,
    required this.state,
    required this.title,
    this.scroll,
  });

  final RunState? state;
  final String title;
  final ScrollController? scroll;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(
      fontFamily: klabautermannThemeStyle.monoFontFamilies.first,
      fontFamilyFallback: klabautermannThemeStyle.monoFontFamilies
          .skip(1)
          .toList(growable: false),
    );
    final (status, output) = switch (state) {
      RunFinished(:final finished) => (
        switch ((finished.outcome, finished.failure, finished.exitCode)) {
          (ActionOutcome.succeeded, _, _) => l10n.jobsCronRunSucceeded,
          (_, ActionFailure.stepFailed, final code?) => l10n.jobsCronRunExited(
            code,
          ),
          (_, final failure, _) => l10n.actionFailed(
            title,
            (failure ?? ActionFailure.stepFailed).name,
          ),
        },
        finished.output,
      ),
      RunRefused(:final reason) => (l10n.actionRefused(reason.name), null),
      RunInProgress() || null => (l10n.jobsCronRunRunning, null),
    };
    final printed = [
      if (output != null && output.stdout.isNotEmpty) output.stdout,
      if (output != null && output.stderr.isNotEmpty) output.stderr,
    ];
    return ListView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      children: [
        Semantics(
          header: true,
          child: Text(title, style: theme.textTheme.titleMedium),
        ),
        const SizedBox(height: 8),
        Semantics(liveRegion: true, child: Text(status)),
        if (state is RunFinished) ...[
          const SizedBox(height: 16),
          if (printed.isEmpty) Text(l10n.jobsCronRunNoOutput),
          for (final text in printed)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SelectableText(text, style: mono),
            ),
          if (output?.truncated ?? false)
            Text(
              l10n.jobsCronRunTruncated,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ],
    );
  }
}
