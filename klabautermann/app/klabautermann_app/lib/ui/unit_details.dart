import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show ghostFormatBinarySize;
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:planchette_editor/planchette_editor.dart'
    show EditorController, PlanchetteEditor;

import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'processes_panel.dart' show kRevealDuration;

/// Below this width the unit file takes a page of its own, as on phones
/// (03 §10.5).
const double _pageBelowWidth = 600;

/// The largest the desktop's unit file dialog grows.
const Size _dialogSize = Size(900, 680);

/// The display path the unit file view highlights as an INI file.
const String _unitFileDisplayPath = 'unit.service';

/// What a [UnitQueryFailure] says, in the user's words.
String unitQueryFailureText(AppLocalizations l10n, UnitQueryFailed failed) =>
    l10n.unitQueryFailed(failed.failure.name);

/// SVC-08's resources of [unit] on its page (03 §7.5; M5 plan M27a): its
/// memory, CPU time, tasks, restarts, main PID and since when it is
/// active, as labelled facts after [leading], the unit's states, in one
/// wrap, so the page's logs keep their room (03 §10.5). They are read
/// when the page opens and again whenever [revision], the unit's states,
/// changes, as after a restart.
class UnitResourcesView extends StatefulWidget {
  const UnitResourcesView({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.unit,
    required this.leading,
    this.revision,
    this.scope = UnitScope.system,
  });

  final MonitoringController monitoring;
  final String serverId;
  final String unit;
  final List<Widget> leading;
  final Object? revision;
  final UnitScope scope;

  @override
  State<UnitResourcesView> createState() => _UnitResourcesViewState();
}

class _UnitResourcesViewState extends State<UnitResourcesView> {
  /// The engine's latest answer; null while it is read.
  UnitPayload? _answer;

  /// Counts reads, so an answer a newer read replaced is dropped.
  int _reads = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  @override
  void didUpdateWidget(UnitResourcesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.unit != widget.unit ||
        oldWidget.serverId != widget.serverId ||
        oldWidget.revision != widget.revision ||
        oldWidget.scope != widget.scope) {
      unawaited(_read());
    }
  }

  Future<void> _read() async {
    final read = ++_reads;
    final result = await widget.monitoring.queryUnit(
      widget.serverId,
      UnitResourcesQuery(widget.unit, scope: widget.scope),
    );
    if (!mounted || read != _reads) return;
    setState(() => _answer = result.payload);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    Widget fact(String label, String value) => MergeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(value),
        ],
      ),
    );

    return Wrap(
      spacing: 24,
      runSpacing: 4,
      children: [
        ...widget.leading,
        ...switch (_answer) {
          null => const <Widget>[],
          UnitResourcesPayload(:final resources) => [
            for (final (label, value) in _rows(context, l10n, resources))
              fact(label, value),
          ],
          final UnitQueryFailed failed => [
            Text(unitQueryFailureText(l10n, failed)),
          ],
          _ => const <Widget>[],
        },
      ],
    );
  }

  List<(String, String)> _rows(
    BuildContext context,
    AppLocalizations l10n,
    UnitResources resources,
  ) {
    final localizations = MaterialLocalizations.of(context);
    final unknown = l10n.chartUnknownValue;
    final since = resources.activeSince?.toLocal();
    final cpu = resources.cpu;
    return [
      (
        l10n.unitResourcesMemory,
        switch (resources.memoryBytes) {
          final bytes? => ghostFormatBinarySize(bytes),
          null => unknown,
        },
      ),
      (
        l10n.unitResourcesCpu,
        cpu == null
            ? unknown
            : l10n.unitResourcesCpuSeconds(
                (cpu.inMilliseconds / 1000).toStringAsFixed(1),
              ),
      ),
      (l10n.unitResourcesTasks, resources.tasks?.toString() ?? unknown),
      (l10n.unitResourcesRestarts, resources.restarts?.toString() ?? unknown),
      (l10n.unitResourcesMainPid, resources.mainPid?.toString() ?? unknown),
      (
        l10n.unitResourcesActiveSince,
        since == null
            ? unknown
            : l10n.activityTime(
                localizations.formatShortDate(since),
                localizations.formatTimeOfDay(TimeOfDay.fromDateTime(since)),
              ),
      ),
    ];
  }
}

/// Opens [unit]'s file and drop-ins (SVC-07, `systemctl cat`) read-only:
/// a dialog on wide windows, a page of its own on phones.
Future<void> openUnitFile(
  BuildContext context, {
  required MonitoringController monitoring,
  required String serverId,
  required String unit,
  required UnitScope scope,
}) {
  final l10n = AppLocalizations.of(context);
  final view = UnitFileView(
    monitoring: monitoring,
    serverId: serverId,
    unit: unit,
    scope: scope,
  );
  if (MediaQuery.sizeOf(context).width < _pageBelowWidth) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: Text(l10n.unitFileTitle(unit))),
          body: SafeArea(
            child: Padding(padding: const EdgeInsets.all(16), child: view),
          ),
        ),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      child: SizedBox.fromSize(
        size: _dialogSize,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        l10n.unitFileTitle(unit),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.unitFileClose,
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              Expanded(child: view),
            ],
          ),
        ),
      ),
    ),
  );
}

/// [unit]'s file as the engine read and masked it (03 §8.9): every
/// `Environment=` value and the secrets of `Exec*=` lines show masked,
/// in Planchette's editor with editing locked. "Reveal values" shows
/// them for [kRevealDuration]; the revealed text lives in this view's
/// state only and is masked again when its time is up, when the app
/// turns inactive and when the view closes.
class UnitFileView extends StatefulWidget {
  const UnitFileView({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.unit,
    this.scope = UnitScope.system,
  });

  final MonitoringController monitoring;
  final String serverId;
  final String unit;
  final UnitScope scope;

  @override
  State<UnitFileView> createState() => _UnitFileViewState();
}

class _UnitFileViewState extends State<UnitFileView> {
  late final AppLifecycleListener _lifecycle;
  UnitPayload? _answer;
  EditorController? _editor;
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
    _editor?.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    final result = await widget.monitoring.queryUnit(
      widget.serverId,
      UnitFileQuery(widget.unit, scope: widget.scope),
    );
    if (!mounted) return;
    setState(() {
      _answer = result.payload;
      _show(revealed: false);
    });
  }

  void _show({required bool revealed}) {
    final before = _editor;
    _editor = switch (_answer) {
      UnitFilePayload(:final text) => EditorController(
        displayPath: _unitFileDisplayPath,
        initialText: [
          for (final span in text)
            revealed ? span.reveal() ?? span.display : span.display,
        ].join(),
      )..setEditingLocked(true),
      _ => null,
    };
    if (before != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => before.dispose());
    }
  }

  void _toggleReveal() {
    if (_reveal != null) {
      _mask();
      return;
    }
    setState(() {
      _reveal = Timer(kRevealDuration, _mask);
      _show(revealed: true);
    });
  }

  void _mask() {
    final timer = _reveal;
    if (timer == null || !mounted) return;
    timer.cancel();
    setState(() {
      _reveal = null;
      _show(revealed: false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final answer = _answer;
    if (answer == null) return Text(l10n.unitFileReading);
    if (answer is UnitQueryFailed) {
      return Text(unitQueryFailureText(l10n, answer));
    }
    final editor = _editor;
    if (answer is! UnitFilePayload || editor == null) {
      return Text(l10n.unitQueryFailed(UnitQueryFailure.failed.name));
    }

    final masked = answer.text.where((span) => span.isMasked).length;
    final revealed = _reveal != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        if (masked > 0)
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                l10n.unitFileMasked(masked, kRevealDuration.inSeconds),
                style: theme.textTheme.bodySmall,
              ),
              TextButton.icon(
                onPressed: _toggleReveal,
                icon: Icon(
                  revealed
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                label: Text(revealed ? l10n.unitFileHide : l10n.unitFileReveal),
              ),
            ],
          ),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Semantics(
                container: true,
                label: l10n.unitFileEditorLabel(widget.unit),
                child: PlanchetteEditor(
                  key: ObjectKey(editor),
                  controller: editor,
                  editingLocked: true,
                  showStatus: false,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
