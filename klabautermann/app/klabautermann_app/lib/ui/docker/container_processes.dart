import 'dart:async' show Timer, unawaited;

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show ghostFormatBinarySize;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/docker_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../processes_panel.dart' show kRevealDuration;
import 'containers_panel.dart' show DockerNotice;

/// The `ps` column whose value is resident memory in KiB, which the
/// section shows as a size.
const _residentTitle = 'RSS';

/// CTR-10's processes of a running container, read when it shows, when
/// the container starts and on request: each process's command line,
/// masked as Processes masks one (03 §8.9), over the other columns `ps`
/// printed (PID, user, CPU share, memory, age; the daemon's own columns
/// on Windows).
///
/// "Reveal values" shows the masked values for [kRevealDuration]; they
/// are masked again when the time is up, when the app turns inactive,
/// when a read starts and when the section goes, and nothing sends,
/// stores or logs them (SAF-07).
class ContainerProcessesSection extends StatefulWidget {
  const ContainerProcessesSection({
    super.key,
    required this.docker,
    required this.serverId,
    required this.containerId,
    required this.up,
  });

  final DockerController docker;
  final String serverId;
  final String containerId;

  /// Whether the container runs, as the latest list says; a stopped one
  /// has no processes to read.
  final bool up;

  @override
  State<ContainerProcessesSection> createState() =>
      _ContainerProcessesSectionState();
}

class _ContainerProcessesSectionState extends State<ContainerProcessesSection> {
  late final AppLifecycleListener _lifecycle;

  /// The engine's answer; null while it is read or the container is
  /// stopped.
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
    if (widget.up) unawaited(_read());
  }

  @override
  void didUpdateWidget(ContainerProcessesSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final same =
        oldWidget.serverId == widget.serverId &&
        oldWidget.containerId == widget.containerId &&
        oldWidget.docker == widget.docker;
    if (same && oldWidget.up == widget.up) return;

    // Another container, or this one started or stopped: what showed no
    // longer holds, and nothing revealed carries over.
    _reveal?.cancel();
    _reveal = null;
    _reads++;
    _answer = null;
    if (widget.up) unawaited(_read());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _reveal?.cancel();
    super.dispose();
  }

  Future<void> _read() async {
    final read = ++_reads;
    // A fresh read starts masked: nothing revealed carries over to it.
    _reveal?.cancel();
    _reveal = null;
    if (_answer != null) setState(() => _answer = null);

    final answer = await widget.docker.readContainerTop(
      widget.serverId,
      widget.containerId,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Semantics(
          container: true,
          header: true,
          child: Text(
            l10n.dockerProcessesTitle,
            style: theme.textTheme.titleSmall,
          ),
        ),
        ..._body(context, l10n),
      ],
    );
  }

  List<Widget> _body(BuildContext context, AppLocalizations l10n) {
    if (!widget.up) {
      return [
        DockerNotice(
          icon: Icons.stop_circle_outlined,
          text: l10n.dockerProcessesStopped,
        ),
      ];
    }

    final readAgain = TextButton(
      onPressed: _read,
      child: Text(l10n.dockerProcessesReadAgain),
    );
    switch (_answer) {
      case null:
        return [
          DockerNotice(
            icon: Icons.hourglass_empty,
            text: l10n.dockerProcessesReading,
          ),
        ];
      case DockerQueryFailed(:final failure, :final detail):
        return [
          DockerNotice(
            icon: Icons.error_outline,
            text: l10n.dockerProcessesFailed(failure.name),
            detail: detail,
            action: readAgain,
          ),
        ];
      case DockerContainerTopPayload(:final processes) when processes.isEmpty:
        return [
          DockerNotice(
            icon: Icons.inbox_outlined,
            text: l10n.dockerProcessesNone,
            action: readAgain,
          ),
        ];
      case DockerContainerTopPayload(
        :final titles,
        :final processes,
        :final commandColumn,
      ):
        final masked = processes.where(
          (row) => row.any((cell) => cell.isMasked),
        );
        final revealed = _reveal != null;
        return [
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                l10n.dockerProcessesCount(processes.length),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (masked.isNotEmpty)
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
              readAgain,
            ],
          ),
          for (final (index, row) in processes.indexed) ...[
            if (index > 0) const Divider(height: 1),
            ContainerProcessRow(
              titles: titles,
              row: row,
              commandColumn: commandColumn,
              revealed: revealed,
            ),
          ],
        ];
      case _:
        // No other payload answers a top read; one would be a read that
        // went wrong.
        return [
          DockerNotice(
            icon: Icons.error_outline,
            text: l10n.dockerProcessesFailed(
              DockerQueryFailure.daemonError.name,
            ),
            action: readAgain,
          ),
        ];
    }
  }
}

/// One process: its command line, masked unless [revealed], over the
/// other columns as `ps` named them.
class ContainerProcessRow extends StatelessWidget {
  const ContainerProcessRow({
    super.key,
    required this.titles,
    required this.row,
    required this.commandColumn,
    required this.revealed,
  });

  final List<String> titles;
  final List<MaskedValue> row;
  final int? commandColumn;
  final bool revealed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final commandAt = commandColumn;
    final command = commandAt == null ? null : row[commandAt];
    final commandText = command == null
        ? null
        : revealed
        ? command.reveal() ?? command.display
        : command.display;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          if (commandText != null && commandText.isNotEmpty)
            SelectableText(
              commandText,
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
              for (final (index, title) in titles.indexed)
                if (index != commandAt)
                  Text(
                    l10n.dockerImagesFact(title, _cell(title, row[index])),
                    style: theme.textTheme.bodySmall,
                  ),
            ],
          ),
        ],
      ),
    );
  }

  /// [cell] under [title]: resident memory as a size, the rest as `ps`
  /// printed it.
  static String _cell(String title, MaskedValue cell) {
    final text = cell.display;
    if (title.toUpperCase() != _residentTitle) return text;

    final kibibytes = int.tryParse(text);
    return kibibytes == null ? text : ghostFormatBinarySize(kibibytes * 1024);
  }
}
