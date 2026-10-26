import 'dart:async' show Timer, unawaited;

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show ghostFormatBinarySize;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/docker_controller.dart';
import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../processes_panel.dart' show kRevealDuration;
import 'containers_panel.dart' show DockerNotice;
import 'images_view.dart';

/// Opens [image]'s history (03 §7.14 IMG-04) in a sheet over the Images
/// sub-tab, on the desktop as on a phone.
void openImageHistory(
  BuildContext context, {
  required MonitoringController monitoring,
  required String serverId,
  required ImageSummary image,
}) {
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
        builder: (context, scroll) => ImageHistorySheet(
          docker: monitoring.docker,
          serverId: serverId,
          image: image,
          scrollController: scroll,
        ),
      ),
    ),
  );
}

/// An image's layers, newest first as the daemon lists them, each with
/// the instruction that made it, when, its size, its comment and the
/// tags it carries.
///
/// An instruction can hold a build argument's value, so the engine masks
/// it as a command line (03 §8.9), and "Reveal values" shows the masked
/// values for [kRevealDuration]. The revealed text lives in this sheet's
/// state only: it is masked again when its time is up, when the app
/// turns inactive (before an app switcher's snapshot), and when the
/// sheet closes, and nothing sends, stores or logs it (SAF-07).
class ImageHistorySheet extends StatefulWidget {
  const ImageHistorySheet({
    super.key,
    required this.docker,
    required this.serverId,
    required this.image,
    this.scrollController,
  });

  final DockerController docker;
  final String serverId;

  /// The image as it was listed when the sheet opened.
  final ImageSummary image;

  final ScrollController? scrollController;

  @override
  State<ImageHistorySheet> createState() => _ImageHistorySheetState();
}

class _ImageHistorySheetState extends State<ImageHistorySheet> {
  late final AppLifecycleListener _lifecycle;

  /// The engine's answer; null while it is read.
  DockerPayload? _answer;

  /// Counts reads, so only the latest answer shows.
  int _reads = 0;

  /// Masks the revealed values when their time is up; null while
  /// masked.
  Timer? _reveal;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onInactive: _mask);
    unawaited(_read());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _reveal?.cancel();
    super.dispose();
  }

  Future<void> _read() async {
    final read = ++_reads;
    setState(() => _answer = null);

    // By id, which names this image whatever its tags became since.
    final answer = await widget.docker.readImageHistory(
      widget.serverId,
      widget.image.id,
    );
    if (!mounted || read != _reads) return;

    setState(() => _answer = answer);
  }

  void _toggleReveal() {
    if (_reveal != null) {
      _mask();
      return;
    }

    setState(() => _reveal = Timer(kRevealDuration, _mask));
  }

  void _mask() {
    final timer = _reveal;
    if (timer == null || !mounted) return;

    timer.cancel();
    setState(() => _reveal = null);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final tags = imageTagsOf(widget.image);
    final name = tags.isEmpty
        ? shortImageId(widget.image.id)
        : imageTagsText(tags);
    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Semantics(
          header: true,
          child: Text(
            l10n.dockerImageHistoryTitle(name),
            style: theme.textTheme.titleLarge,
          ),
        ),
        const SizedBox(height: 12),
        ..._body(context, l10n),
      ],
    );
  }

  List<Widget> _body(BuildContext context, AppLocalizations l10n) {
    final retry = TextButton(onPressed: _read, child: Text(l10n.dockerRetry));
    switch (_answer) {
      case null:
        return [
          DockerNotice(
            icon: Icons.hourglass_empty,
            text: l10n.dockerImageHistoryReading,
          ),
        ];
      case DockerQueryFailed(:final failure, :final detail):
        return [
          DockerNotice(
            icon: Icons.error_outline,
            text: l10n.dockerImageHistoryFailed(failure.name),
            detail: detail,
            action: retry,
          ),
        ];
      case DockerImageHistoryPayload(:final layers) when layers.isEmpty:
        return [
          DockerNotice(
            icon: Icons.layers_clear_outlined,
            text: l10n.dockerImageHistoryEmpty,
          ),
        ];
      case DockerImageHistoryPayload(:final layers):
        final masked = layers.where((layer) => layer.createdBy.isMasked);
        final revealed = _reveal != null;
        return [
          if (masked.isNotEmpty) ...[
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  l10n.dockerImageHistoryMasked(
                    masked.length,
                    kRevealDuration.inSeconds,
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                TextButton.icon(
                  onPressed: _toggleReveal,
                  icon: Icon(
                    revealed
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  label: Text(
                    revealed
                        ? l10n.dockerStackFileHide
                        : l10n.dockerStackFileReveal,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          for (final (index, layer) in layers.indexed) ...[
            if (index > 0) const Divider(height: 1),
            ImageLayerRow(layer: layer, revealed: revealed),
          ],
        ];
      case _:
        // No other payload answers a history read; one would be a read
        // that went wrong.
        return [
          DockerNotice(
            icon: Icons.error_outline,
            text: l10n.dockerImageHistoryFailed(
              DockerQueryFailure.daemonError.name,
            ),
            action: retry,
          ),
        ];
    }
  }
}

/// One layer of an image's history: its instruction, masked unless
/// [revealed], over its figures.
class ImageLayerRow extends StatelessWidget {
  const ImageLayerRow({super.key, required this.layer, required this.revealed});

  final ImageLayer layer;
  final bool revealed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final createdBy = layer.createdBy;
    final instruction = revealed
        ? createdBy.reveal() ?? createdBy.display
        : createdBy.display;
    final facts = [
      if (layer.created case final created?)
        (l10n.dockerImagesColumnCreated, l10n.dockerImagesDate(created)),
      if (layer.size case final size?)
        (l10n.dockerImagesColumnSize, ghostFormatBinarySize(size)),
      if (layer.id case final id?)
        (l10n.dockerImagesColumnId, shortImageId(id)),
      if (layer.tags.isNotEmpty)
        (l10n.dockerImagesColumnTags, imageTagsText(layer.tags)),
      if (layer.comment case final comment?)
        (l10n.dockerImageHistoryComment, comment),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          if (instruction.isEmpty)
            Text(
              l10n.dockerImageHistoryNoInstruction,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            SelectableText(
              instruction,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: klabautermannThemeStyle.monoFontFamilies.first,
                fontFamilyFallback: klabautermannThemeStyle.monoFontFamilies
                    .skip(1)
                    .toList(growable: false),
              ),
            ),
          Wrap(
            spacing: 16,
            runSpacing: 2,
            children: [
              for (final (label, value) in facts)
                Text(
                  l10n.dockerImagesFact(label, value),
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
