part of 'overview_panel.dart';

/// The server's Docker lists and disk use as the Overview reads them
/// (OV-02, OV-05).
final class _Docker {
  _Docker(DockerController docker, String serverId)
    : endpoint = docker.endpointFor(serverId),
      containers = docker.containersFor(serverId),
      images = docker.imagesFor(serverId),
      diskUse = docker.diskUseFor(serverId);

  final ValueListenable<DockerEndpointState?> endpoint;
  final ValueListenable<DockerContainerList> containers;
  final ValueListenable<DockerImageList> images;
  final ValueListenable<DockerDiskUse> diskUse;

  List<Listenable> get all => [endpoint, containers, images, diskUse];

  bool get ready => endpoint.value?.phase == DockerEndpointPhase.ready;

  /// Whether the server has shown a Docker endpoint: it is ready, or
  /// lists from one are held. A server without Docker never gets one,
  /// and the Overview names no Docker card or container for it.
  bool get shown => ready || containers.value.containers != null;

  /// Whether the lists held are no longer followed: the endpoint is not
  /// ready, so nothing reads them again.
  bool get stale => !ready;
}

/// Holds the server's summary watch while the Overview [visible]
/// ([DockerController.watchSummary]); the controller sends it once the
/// endpoint is ready.
class _DockerSummaryWatch extends StatefulWidget {
  const _DockerSummaryWatch({
    required this.docker,
    required this.serverId,
    required this.visible,
    required this.child,
  });

  final DockerController docker;
  final String serverId;
  final bool visible;
  final Widget child;

  @override
  State<_DockerSummaryWatch> createState() => _DockerSummaryWatchState();
}

class _DockerSummaryWatchState extends State<_DockerSummaryWatch> {
  /// The server [DockerController.watchSummary] was told of, if any.
  String? _held;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_DockerSummaryWatch oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(
      widget.docker == oldWidget.docker,
      'new controllers come with a new tree (KlabautermannApp, D44)',
    );
    _sync();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  void _sync() {
    final wanted = widget.visible ? widget.serverId : null;
    if (_held == wanted) return;
    _release();
    if (wanted == null) return;

    widget.docker.watchSummary(wanted);
    _held = wanted;
  }

  void _release() {
    final held = _held;
    if (held == null) return;

    _held = null;
    widget.docker.unwatchSummary(held);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// OV-05's Docker summary (03 §7.1): container counts as `docker info`
/// splits them and the image counts from the watched lists, and the
/// reclaimable space from `/system/df`, measured only when asked since
/// it is slow on large hosts. Once the endpoint is not ready, the last
/// figures grey under the time they were read.
class _DockerCard extends StatelessWidget {
  const _DockerCard({
    required this.docker,
    required this.controller,
    required this.serverId,
  });

  final _Docker docker;
  final DockerController controller;
  final String serverId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final stale = docker.stale;
    final containerList = docker.containers.value;
    final imageList = docker.images.value;
    final containers = containerList.containers;
    final images = imageList.images;
    final failure = containerList.failure ?? imageList.failure;
    final readAt = [
      ?containerList.at,
      ?imageList.at,
    ].fold<DateTime?>(null, (a, b) => a == null || b.isBefore(a) ? b : a);
    final diskUse = docker.diskUse.value;
    final summary = containers == null
        ? null
        : dockerSummary(containers, images ?? const [], diskUse.df);
    String count(int value) => l10n.overviewDockerCount(value);
    String? imageCount(int value) => images == null ? null : count(value);

    return PanelSection(
      title: l10n.overviewDockerTitle,
      children: [
        if (stale && readAt != null)
          PanelNotice(
            icon: Icons.history,
            text: l10n.overviewDockerStale(
              displayTime(context, serverId, readAt),
            ),
          ),
        if (failure != null) ...[
          PanelNotice(
            icon: Icons.error_outline,
            text: l10n.overviewDockerListFailed(failure.failure.name),
            detail: failure.detail,
          ),
          if (docker.ready)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () => controller.retrySummary(serverId),
                child: Text(l10n.dockerRetry),
              ),
            ),
        ] else if (summary == null || images == null)
          PanelNotice(
            icon: Icons.hourglass_empty,
            text: l10n.overviewDockerReading,
          ),
        if (summary != null) ...[
          _Facts(
            stale: stale,
            facts: [
              (l10n.overviewDockerRunning, count(summary.running)),
              (l10n.overviewDockerPaused, count(summary.paused)),
              (l10n.overviewDockerStopped, count(summary.stopped)),
              (l10n.overviewDockerUnhealthy, count(summary.unhealthy)),
            ],
          ),
          _Facts(
            stale: stale,
            facts: [
              (l10n.overviewDockerImages, imageCount(summary.images)),
              (l10n.overviewDockerImagesInUse, imageCount(summary.imagesInUse)),
              (l10n.overviewDockerDangling, imageCount(summary.danglingImages)),
            ],
          ),
        ],
        ..._diskUse(context, l10n, diskUse, stale: stale, muted: muted),
      ],
    );
  }

  /// The reclaimable space, when it was measured, and the action that
  /// measures it, with its progress or why it failed.
  List<Widget> _diskUse(
    BuildContext context,
    AppLocalizations l10n,
    DockerDiskUse diskUse, {
    required bool stale,
    required Color muted,
  }) {
    final theme = Theme.of(context);
    final df = diskUse.df;
    final at = diskUse.at;
    final failure = diskUse.failure;
    final note = theme.textTheme.bodySmall?.copyWith(color: muted);
    return [
      _Facts(
        stale: stale,
        facts: [
          (
            l10n.overviewDockerReclaimable,
            df == null
                ? l10n.overviewDockerNotMeasured
                : _Cards._bytes(l10n, df.reclaimable),
          ),
        ],
      ),
      if (df != null && at != null)
        Text(
          l10n.overviewDockerMeasured(displayTime(context, serverId, at)),
          style: note,
        ),
      if (diskUse.inFlight)
        MergeSemantics(
          child: Row(
            spacing: 8,
            children: [
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              Expanded(child: Text(l10n.overviewDockerMeasuring)),
            ],
          ),
        )
      else if (failure != null)
        PanelNotice(
          icon: Icons.error_outline,
          text: l10n.overviewDockerMeasureFailed(failure.failure.name),
          detail: failure.detail,
        )
      else if (df == null)
        Text(l10n.overviewDockerMeasureNote, style: note),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: docker.ready && !diskUse.inFlight
              ? () => controller.measureDiskUse(serverId)
              : null,
          icon: const Icon(Icons.data_usage),
          label: Text(
            df == null
                ? l10n.overviewDockerMeasure
                : l10n.overviewDockerMeasureAgain,
          ),
        ),
      ),
    ];
  }
}
