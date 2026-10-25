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

/// An image pull (03 §7.14 IMG-03, REG-01): the reference and the route,
/// planned and confirmed as any action is. Through the engine the sheet
/// shows each layer the daemon reports, and closing it stops the pull;
/// the host's own `docker pull` uses the host's registry logins, in the
/// foreground with its output at the end, or detached to outlive the
/// sheet.
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
  PullRoute _route = PullRoute.engine;

  /// The pull this sheet started, the route it took, and its end, once
  /// it came.
  String? _planId;
  PullRoute? _ranVia;
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
    // An engine pull ends with its view (03 §7.14).
    if (_planId case final planId?
        when _end == null && _ranVia == PullRoute.engine) {
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

    final via = _route;
    await previewAndRun(
      context,
      widget.operations,
      PullImage(widget.serverId, reference: reference, via: via),
      onRun: (planId, preview) {
        if (!mounted) return;
        setState(() {
          _planId = planId;
          _ranVia = via;
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
        const SizedBox(height: 12),
        SegmentedButton<PullRoute>(
          segments: [
            for (final route in PullRoute.values)
              ButtonSegment(
                value: route,
                label: Text(l10n.dockerPullRoute(route.name)),
              ),
          ],
          selected: {_route},
          onSelectionChanged: running
              ? null
              : (chosen) => setState(() => _route = chosen.single),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.dockerPullRouteNote(_route.name),
          style: theme.textTheme.bodySmall,
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
            if (running && _ranVia == PullRoute.engine)
              OutlinedButton(
                onPressed: () => widget.operations.cancel(_planId!),
                child: Text(l10n.dockerPullCancel),
              ),
          ],
        ),
        if (running) ...[
          const SizedBox(height: 16),
          Text(
            l10n.dockerPullRunning(_ranVia!.name),
            style: theme.textTheme.bodySmall,
          ),
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
          _PullResult(end: end, target: target, via: _ranVia!),
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
  const _PullResult({
    required this.end,
    required this.target,
    required this.via,
  });

  final RunState end;
  final String target;
  final PullRoute via;

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
      RunInProgress() => l10n.dockerPullRunning(via.name),
      RunFinished(:final finished) => switch (finished.outcome) {
        // A detached pull only started: its log follows it (03 §7.17).
        ActionOutcome.succeeded when finished.operationId != null =>
          l10n.dockerPullDetached(target),
        ActionOutcome.succeeded => l10n.actionSucceeded(target),
        ActionOutcome.cancelled => l10n.actionCancelled(target),
        ActionOutcome.failed => switch (finished.failure) {
          final failure? => l10n.actionFailed(target, failure.name),
          null => l10n.actionFailedPlain(target),
        },
      },
    };
    // The host's docker pull prints its progress on stdout and its
    // error on stderr; the engine's error comes as stderr.
    final output = finished?.output;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Semantics(
          liveRegion: true,
          child: Text(
            headline,
            style: theme.textTheme.titleSmall?.copyWith(
              color: finished?.outcome == ActionOutcome.succeeded
                  ? null
                  : theme.colorScheme.error,
            ),
          ),
        ),
        for (final text in [?output?.stdout, ?output?.stderr])
          if (text.isNotEmpty) SelectableText(text, style: _mono(theme)),
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
