part of 'container_details.dart';

/// How many of a container's newest log lines its diagnosis shows.
const _logTailLines = 20;

/// [child], the diagnosis (TRI-04), over [containerId]'s newest log
/// lines when [read]: one bounded read while it shows, oldest first as
/// Docker sends them. Lines show as they arrive; none show when the
/// read fails, and the Logs view says why there.
class _LogTail extends StatefulWidget {
  const _LogTail({
    required this.monitoring,
    required this.serverId,
    required this.containerId,
    required this.read,
    required this.child,
  });

  final MonitoringController monitoring;
  final String serverId;
  final String containerId;
  final bool read;
  final Widget child;

  @override
  State<_LogTail> createState() => _LogTailState();
}

class _LogTailState extends State<_LogTail> {
  LogRead? _read;

  @override
  void initState() {
    super.initState();
    if (widget.read) _open();
  }

  @override
  void didUpdateWidget(_LogTail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId == widget.serverId &&
        oldWidget.containerId == widget.containerId &&
        oldWidget.read == widget.read) {
      return;
    }

    _close();
    if (widget.read) _open();
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  void _open() {
    _read = widget.monitoring.openLogRead(
      LogStreamSpec(
        serverId: widget.serverId,
        source: ContainerLogSource(widget.containerId),
        window: _logTailLines,
        follow: false,
      ),
    )..addListener(_changed);
  }

  void _close() {
    _read
      ?..removeListener(_changed)
      ..close();
    _read = null;
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final read = _read;
    if (read == null) return widget.child;

    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final lines = [
      for (final record in read.records)
        if (record is ContainerRecord) record.text,
    ];
    final readAll = switch (read.state) {
      LogReadReported(
        status: LogStreamEnded(
          reason: LogStreamEndReason.windowFilled ||
              LogStreamEndReason.oldestReached,
        ),
      ) =>
        true,
      _ => false,
    };
    if (lines.isEmpty && !readAll) return widget.child;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        widget.child,
        _Label(l10n.dockerLogsTitle),
        if (lines.isEmpty)
          _Muted(l10n.dockerLogsEmpty)
        else
          // One text per line, selectable together.
          SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in lines)
                  Text(
                    line,
                    style: klabautermannMonoStyle.copyWith(
                      fontSize: theme.textTheme.bodySmall?.fontSize,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
