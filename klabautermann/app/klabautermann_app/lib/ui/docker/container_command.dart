import 'dart:async' show StreamSubscription, unawaited;

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/operations_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart' show klabautermannThemeStyle;
import '../actions/action_entry.dart';
import '../actions/action_preview.dart';
import 'containers_view.dart' show containerNameOf;

/// Opens CTX-08's one-off command sheet for [container] on [serverId].
/// The operations controller is read here: the sheet's own route is
/// outside the scope that holds it.
void openContainerCommand(
  BuildContext context, {
  required String serverId,
  required ContainerSummary container,
}) {
  final operations = OperationsScope.maybeOf(context);
  if (operations == null) return;
  unawaited(
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.3,
        maxChildSize: 1,
        builder: (context, scroll) => ContainerCommandSheet(
          operations: operations,
          serverId: serverId,
          container: container,
          scrollController: scroll,
        ),
      ),
    ),
  );
}

/// A one-off command in [container] without a TTY (03 §7.13, CTX-08):
/// the command and the user to run it as, planned and confirmed as any
/// action is, then its output and exit code.
class ContainerCommandSheet extends StatefulWidget {
  const ContainerCommandSheet({
    super.key,
    required this.operations,
    required this.serverId,
    required this.container,
    this.scrollController,
  });

  final OperationsController operations;
  final String serverId;
  final ContainerSummary container;
  final ScrollController? scrollController;

  @override
  State<ContainerCommandSheet> createState() => _ContainerCommandSheetState();
}

class _ContainerCommandSheetState extends State<ContainerCommandSheet> {
  final _command = TextEditingController();
  final _user = TextEditingController();
  late final StreamSubscription<(String, RunState)> _ends;
  bool _unparsed = false;

  /// The run this sheet started and its end, once it came.
  String? _planId;
  RunState? _end;

  @override
  void initState() {
    super.initState();
    _ends = widget.operations.ends.listen((end) {
      final (planId, state) = end;
      if (planId == _planId && mounted) setState(() => _end = state);
    });
  }

  @override
  void dispose() {
    unawaited(_ends.cancel());
    _command.dispose();
    _user.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final argv = splitCommandWords(_command.text);
    setState(() => _unparsed = argv == null);
    if (argv == null || widget.operations.planning) return;

    final user = _user.text.trim();
    await previewAndRun(
      context,
      widget.operations,
      ContainerExec(
        widget.serverId,
        containerId: widget.container.id,
        argv: argv,
        user: user.isEmpty ? null : user,
      ),
      onRun: (planId, _) {
        if (mounted) {
          setState(() {
            _planId = planId;
            _end = null;
          });
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final running = _planId != null && _end == null;
    final mono = TextStyle(
      fontFamily: klabautermannThemeStyle.monoFontFamilies.first,
      fontFamilyFallback: klabautermannThemeStyle.monoFontFamilies,
    );

    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Semantics(
          header: true,
          child: Text(
            l10n.dockerCommandTitle(containerNameOf(widget.container)),
            style: theme.textTheme.titleMedium,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _command,
          onChanged: (_) {
            if (_unparsed) setState(() => _unparsed = false);
          },
          autocorrect: false,
          enableSuggestions: false,
          style: mono,
          decoration: InputDecoration(
            labelText: l10n.dockerCommandLabel,
            helperText: l10n.dockerCommandHelper,
            helperMaxLines: 3,
            errorText: _unparsed ? l10n.dockerCommandUnparsed : null,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: running ? null : (_) => unawaited(_run()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _user,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: l10n.dockerShellUserLabel,
            hintText: l10n.dockerShellUserHint,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.icon(
            onPressed: running ? null : () => unawaited(_run()),
            icon: const Icon(Icons.play_arrow),
            label: Text(l10n.dockerCommandRun),
          ),
        ),
        if (running) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(l10n.dockerCommandRunning),
        ],
        if (_end case final end?) ...[
          const SizedBox(height: 16),
          _CommandResult(
            end: end,
            target: containerNameOf(widget.container),
            mono: mono,
          ),
        ],
      ],
    );
  }
}

/// How a one-off command ended: its exit code and output, or why it did
/// not run.
class _CommandResult extends StatelessWidget {
  const _CommandResult({
    required this.end,
    required this.target,
    required this.mono,
  });

  final RunState end;
  final String target;
  final TextStyle mono;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final finished = switch (end) {
      RunFinished(:final finished) => finished,
      _ => null,
    };
    final headline = switch (end) {
      RunRefused(:final reason) => l10n.actionRefused(reason.name),
      RunInProgress() => l10n.dockerCommandRunning,
      RunFinished(:final finished) => switch (finished.exitCode) {
        final code? => l10n.dockerShellExitCode(code),
        null => switch (finished.outcome) {
          ActionOutcome.succeeded => l10n.actionSucceeded(target),
          ActionOutcome.cancelled => l10n.actionCancelled(target),
          ActionOutcome.failed => switch (finished.failure) {
            final failure? => l10n.actionFailed(target, failure.name),
            null => l10n.actionFailedPlain(target),
          },
        },
      },
    };
    final output = finished?.output;

    Widget block(String label, String text) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Text(label, style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: SelectableText(text, style: mono),
          ),
        ),
      ],
    );

    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            headline,
            style: theme.textTheme.titleSmall?.copyWith(
              color:
                  end is RunInProgress ||
                      finished?.exitCode == 0 ||
                      (finished?.exitCode == null &&
                          finished?.outcome == ActionOutcome.succeeded)
                  ? null
                  : theme.colorScheme.error,
            ),
          ),
          if (output != null) ...[
            if (output.stdout.isEmpty && output.stderr.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(l10n.dockerCommandNoOutput),
              ),
            if (output.stdout.isNotEmpty)
              block(l10n.dockerCommandStdout, output.stdout),
            if (output.stderr.isNotEmpty)
              block(l10n.dockerCommandStderr, output.stderr),
            if (output.truncated)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  l10n.dockerCommandTruncated,
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// The button that opens [openContainerCommand], where actions on
/// [serverId] are allowed.
class ContainerCommandButton extends StatelessWidget {
  const ContainerCommandButton({
    super.key,
    required this.serverId,
    required this.container,
  });

  final String serverId;
  final ContainerSummary container;

  @override
  Widget build(BuildContext context) => ActionEntry(
    serverId: serverId,
    point: ActionEntryPoint.containerCommand,
    child: IconButton(
      tooltip: AppLocalizations.of(context).dockerCommandOpen,
      icon: const Icon(Icons.play_circle_outline),
      onPressed: () => openContainerCommand(
        context,
        serverId: serverId,
        container: container,
      ),
    ),
  );
}
