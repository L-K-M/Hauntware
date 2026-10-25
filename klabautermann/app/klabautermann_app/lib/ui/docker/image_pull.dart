import 'dart:async' show StreamSubscription, unawaited;

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show ghostFormatBinarySize;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/operations_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart' show klabautermannThemeStyle;
import '../actions/action_entry.dart';
import '../actions/action_preview.dart';

/// Opens IMG-03's pull sheet for [serverId]. The operations controller is
/// read here: the sheet's own route is outside the scope that holds it.
void openImagePull(BuildContext context, {required String serverId}) {
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
        builder: (context, scroll) => ImagePullSheet(
          operations: operations,
          serverId: serverId,
          scrollController: scroll,
        ),
      ),
    ),
  );
}

/// An image pull with its per-layer progress (03 §7.14 IMG-03): the
/// reference, planned and confirmed as any action is, then each layer the
/// daemon reports and how the pull ended. The pull is a foreground one:
/// closing the sheet stops it, which the sheet says while it runs.
class ImagePullSheet extends StatefulWidget {
  const ImagePullSheet({
    super.key,
    required this.operations,
    required this.serverId,
    this.scrollController,
  });

  final OperationsController operations;
  final String serverId;
  final ScrollController? scrollController;

  @override
  State<ImagePullSheet> createState() => _ImagePullSheetState();
}

class _ImagePullSheetState extends State<ImagePullSheet> {
  final _reference = TextEditingController();
  late final StreamSubscription<(String, RunState)> _ends;

  /// The pull this sheet started and its end, once it came.
  String? _planId;
  String? _target;
  RunState? _end;

  bool get _running => _planId != null && _end == null;

  @override
  void initState() {
    super.initState();
    widget.operations.addListener(_changed);
    _ends = widget.operations.ends.listen((end) {
      final (planId, state) = end;
      if (planId == _planId && mounted) setState(() => _end = state);
    });
  }

  void _changed() {
    if (_running && mounted) setState(() {});
  }

  @override
  void dispose() {
    // A foreground pull ends with its view (03 §7.14).
    if (_planId case final planId? when _end == null) {
      widget.operations.cancel(planId);
    }
    widget.operations.removeListener(_changed);
    unawaited(_ends.cancel());
    _reference.dispose();
    super.dispose();
  }

  Future<void> _pull() async {
    final reference = _reference.text.trim();
    if (reference.isEmpty || widget.operations.planning) return;

    await previewAndRun(
      context,
      widget.operations,
      PullImage(widget.serverId, reference: reference),
      onRun: (planId, preview) {
        if (!mounted) return;
        setState(() {
          _planId = planId;
          _target = preview.targetName;
          _end = null;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final running = _running;
    final progress = switch (_planId) {
      final planId? => widget.operations.pullOf(planId),
      null => null,
    };

    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Semantics(
          header: true,
          child: Text(l10n.dockerPullTitle, style: theme.textTheme.titleMedium),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _reference,
          enabled: !running,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: l10n.dockerPullReference,
            hintText: l10n.dockerPullReferenceHint,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: running ? null : (_) => unawaited(_pull()),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: running ? null : () => unawaited(_pull()),
              icon: const Icon(Icons.download),
              label: Text(l10n.dockerPullStart),
            ),
            if (running)
              OutlinedButton(
                onPressed: () => widget.operations.cancel(_planId!),
                child: Text(l10n.dockerPullCancel),
              ),
          ],
        ),
        if (running) ...[
          const SizedBox(height: 16),
          Text(l10n.dockerPullForeground, style: theme.textTheme.bodySmall),
        ],
        if (progress?.status case final status?) ...[
          const SizedBox(height: 12),
          Text(status, style: _mono(theme)),
        ],
        if (progress != null)
          for (final layer in progress.layers) PullLayerRow(layer: layer),
        if (running && progress == null) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
        if ((_end, _target) case (final end?, final target?)) ...[
          const SizedBox(height: 16),
          _PullResult(end: end, target: target),
        ],
      ],
    );
  }
}

TextStyle? _mono(ThemeData theme) => theme.textTheme.bodySmall?.copyWith(
  fontFamily: klabautermannThemeStyle.monoFontFamilies.first,
  fontFamilyFallback: klabautermannThemeStyle.monoFontFamilies,
);

/// One layer of a pull: its id, the daemon's status, and a bar with the
/// bytes done of the total while the daemon reports them.
class PullLayerRow extends StatelessWidget {
  const PullLayerRow({super.key, required this.layer});

  final PullLayer layer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final (current, total) = (layer.current, layer.total);
    final measured = current != null && total != null && total > 0;
    final label = switch (layer.status) {
      final status? when measured => l10n.dockerPullLayerBytes(
        status,
        ghostFormatBinarySize(current),
        ghostFormatBinarySize(total),
      ),
      final status => status,
    };

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: MergeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 4,
          children: [
            Row(
              spacing: 8,
              children: [
                Text(layer.id, style: _mono(theme)),
                if (label != null)
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
            if (measured)
              LinearProgressIndicator(value: (current / total).clamp(0, 1)),
          ],
        ),
      ),
    );
  }
}

/// How a pull ended: done, cancelled, refused, or failed with what the
/// daemon said.
class _PullResult extends StatelessWidget {
  const _PullResult({required this.end, required this.target});

  final RunState end;
  final String target;

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
      RunInProgress() => l10n.dockerPullForeground,
      RunFinished(:final finished) => switch (finished.outcome) {
        ActionOutcome.succeeded => l10n.actionSucceeded(target),
        ActionOutcome.cancelled => l10n.actionCancelled(target),
        ActionOutcome.failed => switch (finished.failure) {
          final failure? => l10n.actionFailed(target, failure.name),
          null => l10n.actionFailedPlain(target),
        },
      },
    };
    final detail = finished?.output?.stderr;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Semantics(
          liveRegion: true,
          child: Text(
            headline,
            style: theme.textTheme.titleSmall?.copyWith(
              // A pull the user stopped is no error; a refused or failed
              // one is.
              color: switch (end) {
                RunRefused() => theme.colorScheme.error,
                RunFinished(:final finished)
                    when finished.outcome == ActionOutcome.failed =>
                  theme.colorScheme.error,
                _ => null,
              },
            ),
          ),
        ),
        if (detail != null && detail.isNotEmpty)
          SelectableText(detail, style: _mono(theme)),
      ],
    );
  }
}

/// The button that opens [openImagePull], where actions on [serverId]
/// are allowed.
class ImagePullButton extends StatelessWidget {
  const ImagePullButton({super.key, required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context) => ActionEntry(
    serverId: serverId,
    point: ActionEntryPoint.imagePull,
    child: OutlinedButton.icon(
      onPressed: () => openImagePull(context, serverId: serverId),
      icon: const Icon(Icons.download),
      label: Text(AppLocalizations.of(context).dockerPullOpen),
    ),
  );
}
