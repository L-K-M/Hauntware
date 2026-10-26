import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show ghostFormatBinarySize;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'system_panel.dart' show PanelNotice, PanelSection, SystemSection;

/// DSK-05's part of a mount's details: the source it is mounted from and
/// its options, which the `fs` stream does not carry, read once the
/// details open. [fact] draws a label over its value as the sheet's
/// other facts do.
class MountOptions extends StatefulWidget {
  const MountOptions({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.mountPoint,
    required this.fact,
  });

  final MonitoringController monitoring;
  final String serverId;
  final String mountPoint;
  final Widget Function(String label, String value) fact;

  @override
  State<MountOptions> createState() => _MountOptionsState();
}

class _MountOptionsState extends State<MountOptions> {
  HostPayload? _read;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final result = await widget.monitoring.queryHost(
      widget.serverId,
      const MountsQuery(),
    );
    if (mounted) setState(() => _read = result.payload);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    switch (_read) {
      case null:
        return PanelNotice(
          icon: Icons.hourglass_empty,
          text: l10n.systemMountReading,
        );
      case HostQueryFailed(:final failure, :final detail):
        return PanelNotice(
          icon: Icons.error_outline,
          text: l10n.systemMountFailed(failure.name),
          detail: detail,
        );
      case Mounts(:final read):
        final mount = read.mountAt(widget.mountPoint);
        if (mount == null) {
          return PanelNotice(
            icon: Icons.info_outline,
            text: l10n.systemMountGone,
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            if (mount.readOnly)
              PanelNotice(
                icon: Icons.lock_outline,
                text: l10n.systemMountReadOnly,
              ),
            if (mount.source.isNotEmpty)
              widget.fact(l10n.systemMountSource, mount.source),
            if (mount.options.isNotEmpty)
              widget.fact(l10n.systemMountOptions, mount.options.join(', ')),
          ],
        );
      case _:
        return PanelNotice(
          icon: Icons.error_outline,
          text: l10n.systemMountFailed(HostQueryFailure.failed.name),
        );
    }
  }
}

/// DSK-14's section of the System tab: the swap partitions and files, how
/// much of each is used and their priority. It reads when it shows and on
/// request; a server switch reads the new server's.
class SwapSection extends StatefulWidget {
  const SwapSection({
    super.key,
    required this.monitoring,
    required this.serverId,
  });

  final MonitoringController monitoring;
  final String serverId;

  @override
  State<SwapSection> createState() => _SwapSectionState();
}

class _SwapSectionState extends State<SwapSection> {
  HostPayload? _read;
  bool _reading = false;

  /// Bumped per read, so only the newest answer lands.
  int _ticket = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(SwapSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId == widget.serverId &&
        oldWidget.monitoring == widget.monitoring) {
      return;
    }
    _read = null;
    unawaited(_load());
  }

  Future<void> _load() async {
    final ticket = ++_ticket;
    if (mounted) setState(() => _reading = true);
    final result = await widget.monitoring.queryHost(
      widget.serverId,
      const MountsQuery(),
    );
    if (!mounted || ticket != _ticket) return;
    setState(() {
      _read = result.payload;
      _reading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PanelSection(
      key: const ValueKey(SystemSection.swap),
      title: l10n.systemSwapTitle,
      children: [
        ..._lines(l10n),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton(
            onPressed: _reading ? null : () => unawaited(_load()),
            child: Text(l10n.systemSwapReadAgain),
          ),
        ),
      ],
    );
  }

  List<Widget> _lines(AppLocalizations l10n) => switch (_read) {
    null => [
      PanelNotice(icon: Icons.hourglass_empty, text: l10n.systemSwapReading),
    ],
    HostQueryFailed(:final failure, :final detail) => [
      PanelNotice(
        icon: Icons.error_outline,
        text: l10n.systemSwapFailed(failure.name),
        detail: detail,
      ),
    ],
    Mounts(:final read) when read.swaps.isEmpty => [
      PanelNotice(icon: Icons.info_outline, text: l10n.systemSwapNone),
    ],
    Mounts(:final read) => [
      // Used first at the top, as the kernel picks them.
      for (final swap
          in read.swaps.toList()
            ..sort((a, b) => b.priority.compareTo(a.priority)))
        _SwapLine(swap: swap),
    ],
    _ => [
      PanelNotice(
        icon: Icons.error_outline,
        text: l10n.systemSwapFailed(HostQueryFailure.failed.name),
      ),
    ],
  };
}

/// One swap device: its path, what it is, how much is used and its
/// priority, read as one node.
class _SwapLine extends StatelessWidget {
  const _SwapLine({required this.swap});

  final SwapDevice swap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 2,
        children: [
          Text(swap.path, style: theme.textTheme.bodyLarge),
          Text(
            l10n.systemSwapUsage(
              ghostFormatBinarySize(swap.usedBytes),
              ghostFormatBinarySize(swap.sizeBytes),
            ),
          ),
          Text(
            l10n.systemSwapDetail(swap.kind.name, swap.priority),
            style: muted,
          ),
        ],
      ),
    );
  }
}
