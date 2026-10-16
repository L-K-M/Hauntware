import 'dart:async';

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import 'log_level.dart';
import 'log_query.dart';
import 'log_search.dart';
import 'log_view.dart';
import 'logs_panel_controller.dart';

/// Below this width at 100 % text the panel takes the phone's layout (03
/// §10.5); the bar's controls grow with the text, and so does the width.
const double _phoneWidth = 600;

/// A filter field's width at 100 % text; it grows with the text.
const double _fieldWidth = 200;

/// How long the search waits for typing to pause: a new query searches
/// every line held ([LogSearch]).
const Duration _searchDebounce = Duration(milliseconds: 200);

const Map<LogSourceKind, IconData> _sourceIcons = {
  LogSourceKind.journal: Icons.article_outlined,
  LogSourceKind.kernel: Icons.memory,
  LogSourceKind.file: Icons.description_outlined,
};

/// What LOG-02's chip says, each with its own icon so the state is never
/// told by colour alone.
enum _LiveWord {
  live(Icons.fiber_manual_record),
  connecting(Icons.sync),
  disconnected(Icons.link_off),
  paused(Icons.pause_circle_outline),
  stopped(Icons.stop_circle_outlined),
  unavailable(Icons.block);

  const _LiveWord(this.icon);

  final IconData icon;
}

/// What the status line says ([AppLocalizations.logsPanelStatus]).
enum _StatusWord {
  opening,
  waitingLink,
  waitingChannel,
  waitingBackground,
  gap,
  loading,
  invalid,
  missing,
  denied,
  failed,
  rejected,
  needsPath,
}

/// The states after which reading again may help.
const _retryable = {
  _StatusWord.rejected,
  _StatusWord.missing,
  _StatusWord.denied,
  _StatusWord.failed,
};

_LiveWord _liveWord(LogsPanelController panel) {
  if (!panel.live) return _LiveWord.paused;
  if (panel.rejected) return _LiveWord.unavailable;
  if (!panel.query.ready) return _LiveWord.stopped;
  return switch (panel.status) {
    LogStreamRunning() => _LiveWord.live,
    LogStreamWaiting(reason: LogStreamWaitReason.link) =>
      _LiveWord.disconnected,
    LogStreamWaiting(reason: LogStreamWaitReason.background) =>
      _LiveWord.paused,
    LogStreamWaiting() || null => _LiveWord.connecting,
    LogStreamEnded() => _LiveWord.stopped,
  };
}

_StatusWord? _statusWord(LogsPanelController panel) {
  if (!panel.query.ready) return _StatusWord.needsPath;
  if (panel.rejected) return _StatusWord.rejected;
  if (panel.opening) return _StatusWord.opening;
  return switch (panel.status) {
    LogStreamWaiting(:final reason) => switch (reason) {
      LogStreamWaitReason.link => _StatusWord.waitingLink,
      LogStreamWaitReason.channel => _StatusWord.waitingChannel,
      LogStreamWaitReason.background => _StatusWord.waitingBackground,
    },
    // A follow without a cursor started again after it waited (LOG-22).
    LogStreamRunning(continuity: LogContinuity.gap) when panel.live =>
      _StatusWord.gap,
    LogStreamRunning() => panel.live ? null : _StatusWord.loading,
    LogStreamEnded(:final reason) => switch (reason) {
      LogStreamEndReason.invalid => _StatusWord.invalid,
      LogStreamEndReason.missing => _StatusWord.missing,
      LogStreamEndReason.denied => _StatusWord.denied,
      LogStreamEndReason.failed => _StatusWord.failed,
      LogStreamEndReason.windowFilled ||
      LogStreamEndReason.oldestReached ||
      LogStreamEndReason.closed => null,
    },
    null => null,
  };
}

/// The Logs panel (03 §10.4, §10.8): a filter bar with the source picker
/// (journal, kernel, file), LOG-01's journal filters or LOG-22's path
/// field, LOG-02's Live chip and LOG-05's search over the [LogView], with
/// LOG-04's notice when the server shows the user only their own journal
/// entries. On phones the source and filters open bottom sheets.
///
/// Its stream is open only while [visible]; another [serverId] starts the
/// panel afresh.
class LogsPanel extends StatefulWidget {
  const LogsPanel({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.visible,
  });

  final MonitoringController monitoring;
  final String serverId;
  final bool visible;

  @override
  State<LogsPanel> createState() => _LogsPanelState();
}

class _LogsPanelState extends State<LogsPanel> {
  late LogsPanelController _panel = _start();

  LogsPanelController _start() => LogsPanelController(
    streams: widget.monitoring.logs,
    serverId: widget.serverId,
  )..setVisible(widget.visible);

  @override
  void didUpdateWidget(LogsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.serverId != oldWidget.serverId ||
        widget.monitoring != oldWidget.monitoring) {
      _panel.dispose();
      _panel = _start();
    }
    _panel.setVisible(widget.visible);
  }

  @override
  void dispose() {
    _panel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    // A new controller gets new fields, drafts and search text.
    return KeyedSubtree(
      key: ObjectKey(_panel),
      child: ListenableBuilder(
        listenable: _panel,
        builder: (context, _) => LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < scaler.scale(_phoneWidth);
            final search = _SearchField(search: _panel.search);
            final header = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: _bar(l10n, compact: compact, search: search),
                ),
                if (compact)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: search,
                  ),
                ValueListenableBuilder(
                  valueListenable: widget.monitoring.logs.journalLimitedFor(
                    widget.serverId,
                  ),
                  builder: (context, limited, _) =>
                      switch (_panel.query.source) {
                        _ when limited != true => const SizedBox.shrink(),
                        LogSourceKind.journal => _Notice(
                          icon: Icons.info_outline,
                          text: l10n.logsPanelJournalLimited,
                        ),
                        // The journal shows such an account no kernel
                        // messages (K04's kPanelNeeds); `dmesg` may.
                        LogSourceKind.kernel => _Notice(
                          icon: Icons.info_outline,
                          text: l10n.logsPanelKernelLimited,
                        ),
                        // A file is read with the file's rights.
                        LogSourceKind.file => const SizedBox.shrink(),
                      },
                ),
                ?_status(l10n),
              ],
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Large text on a small phone: the header scrolls within
                // half the panel, so the log keeps the other half.
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight / 2,
                  ),
                  child: SingleChildScrollView(child: header),
                ),
                Expanded(child: _logView(l10n)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _bar(
    AppLocalizations l10n, {
    required bool compact,
    required Widget search,
  }) {
    final query = _panel.query;
    final word = _liveWord(_panel);
    final filters = query.source != LogSourceKind.kernel;
    return Wrap(
      spacing: compact ? 8 : 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (compact)
          Tooltip(
            message: l10n.logsPanelSource,
            child: OutlinedButton.icon(
              onPressed: _pickSource,
              icon: Icon(_sourceIcons[query.source]),
              label: Text(l10n.logsPanelSourceName(query.source.name)),
            ),
          )
        else
          Semantics(
            container: true,
            label: l10n.logsPanelSource,
            child: SegmentedButton<LogSourceKind>(
              segments: [
                for (final source in LogSourceKind.values)
                  ButtonSegment(
                    value: source,
                    icon: Icon(_sourceIcons[source]),
                    label: Text(l10n.logsPanelSourceName(source.name)),
                  ),
              ],
              selected: {query.source},
              onSelectionChanged: (selected) =>
                  _panel.apply(query.withSource(selected.single)),
            ),
          ),
        if (filters && compact)
          OutlinedButton.icon(
            onPressed: _editFilters,
            icon: const Icon(Icons.filter_list),
            label: Text(l10n.logsPanelFilters(query.filterCount)),
          )
        else if (filters)
          _FilterForm(
            // Only a new source resets the fields; after Apply the drafts
            // already match, and a new form would drop the focus.
            key: ValueKey(query.source),
            query: query,
            sheet: false,
            onApply: _panel.apply,
          ),
        FilterChip(
          selected: _panel.live,
          showCheckmark: false,
          avatar: Icon(word.icon, size: 18),
          label: Text(l10n.logsPanelLiveState(word.name)),
          tooltip: l10n.logsPanelLiveTooltip,
          onSelected: _panel.setLive,
        ),
        if (!compact)
          SizedBox(
            width: MediaQuery.textScalerOf(context).scale(_fieldWidth * 1.75),
            child: search,
          ),
      ],
    );
  }

  Widget? _status(AppLocalizations l10n) {
    final word = _statusWord(_panel);
    if (word == null) return null;

    final retry = _retryable.contains(word);
    return _Notice(
      icon: switch (word) {
        _ when retry => Icons.error_outline,
        _StatusWord.gap => Icons.info_outline,
        _ => Icons.hourglass_empty,
      },
      text: l10n.logsPanelStatus(word.name),
      // The host's error output is server data, shown as sent.
      detail: switch (_panel.status) {
        LogStreamEnded(:final detail?) => detail,
        _ => null,
      },
      action: retry
          ? TextButton(
              onPressed: _panel.retry,
              child: Text(l10n.logsPanelRetry),
            )
          : null,
      announce: true,
    );
  }

  Widget _logView(AppLocalizations l10n) => Stack(
    fit: StackFit.expand,
    children: [
      LogView(
        controller: _panel.logs,
        search: _panel.search,
        levelOf: LogLevel.ofJournalLine,
      ),
      if (_panel.logs.length == 0 &&
          _panel.status is LogStreamEnded &&
          _statusWord(_panel) == null)
        ValueListenableBuilder(
          valueListenable: widget.monitoring.logs.journalLimitedFor(
            widget.serverId,
          ),
          builder: (context, limited, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                _emptyText(l10n, limited: limited == true),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
    ],
  );

  String _emptyText(AppLocalizations l10n, {required bool limited}) {
    final query = _panel.query;
    if (query.source == LogSourceKind.journal && query.filterCount > 0) {
      return l10n.logsPanelEmptyFiltered;
    }
    // LOG-04: the server may hold entries this account cannot read.
    if (limited && query.source != LogSourceKind.file) {
      return l10n.logsPanelEmptyLimited;
    }
    return l10n.logsPanelEmpty;
  }

  Future<T?> _sheet<T>(Widget Function(BuildContext context) body) =>
      showModalBottomSheet<T>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              16 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SingleChildScrollView(child: body(context)),
          ),
        ),
      );

  Future<void> _pickSource() async {
    final l10n = AppLocalizations.of(context);
    final current = _panel.query.source;
    final picked = await _sheet<LogSourceKind>(
      (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.logsPanelSource,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          for (final source in LogSourceKind.values)
            ListTile(
              leading: Icon(_sourceIcons[source]),
              title: Text(l10n.logsPanelSourceName(source.name)),
              selected: source == current,
              trailing: source == current ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, source),
            ),
        ],
      ),
    );
    if (!mounted || picked == null || picked == _panel.query.source) return;
    _panel.apply(_panel.query.withSource(picked));
  }

  Future<void> _editFilters() => _sheet<void>(
    (context) => _FilterForm(
      query: _panel.query,
      sheet: true,
      onApply: (query) {
        Navigator.pop(context);
        _panel.apply(query);
      },
    ),
  );
}

/// LOG-01's journal filters or LOG-22's path field, edited as a draft
/// until Apply (or Enter in a field) reads the log with them: in a row on
/// wide layouts, or a column in the phone's sheet.
class _FilterForm extends StatefulWidget {
  const _FilterForm({
    super.key,
    required this.query,
    required this.sheet,
    required this.onApply,
  });

  final LogQuery query;
  final bool sheet;
  final ValueChanged<LogQuery> onApply;

  @override
  State<_FilterForm> createState() => _FilterFormState();
}

class _FilterFormState extends State<_FilterForm> {
  late final _unit = TextEditingController(text: widget.query.unit);
  late final _identifier = TextEditingController(text: widget.query.identifier);
  late final _path = TextEditingController(text: widget.query.path);
  late LogPriority? _priority = widget.query.priority;
  late bool _boot = widget.query.currentBootOnly;
  late LogTimeRange _range = widget.query.range;

  LogQuery get _draft => LogQuery(
    source: widget.query.source,
    unit: _unit.text.trim(),
    identifier: _identifier.text.trim(),
    priority: _priority,
    currentBootOnly: _boot,
    range: _range,
    path: _path.text,
  );

  void _apply() {
    final draft = _draft;
    if (draft.ready) widget.onApply(draft);
  }

  @override
  void dispose() {
    _unit.dispose();
    _identifier.dispose();
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final width = MediaQuery.textScalerOf(context).scale(_fieldWidth);
    final file = widget.query.source == LogSourceKind.file;

    // Fields keep their width in a row and fill the sheet.
    Widget sized(Widget field, {double factor = 1}) =>
        widget.sheet ? field : SizedBox(width: width * factor, child: field);

    final fields = <Widget>[
      if (file)
        sized(_pathField(l10n), factor: 2)
      else ...[
        sized(_textField(_unit, l10n.logsPanelUnit)),
        sized(_textField(_identifier, l10n.logsPanelIdentifier)),
        sized(
          DropdownButtonFormField<LogPriority?>(
            initialValue: _priority,
            isExpanded: true,
            decoration: _decoration(l10n.logsPanelPriority),
            onChanged: (priority) => setState(() => _priority = priority),
            items: [
              DropdownMenuItem(child: Text(l10n.logsPanelPriorityAny)),
              for (final priority in LogPriority.values)
                DropdownMenuItem(
                  value: priority,
                  child: Text(l10n.logsPanelPriorityLevel(priority.name)),
                ),
            ],
          ),
        ),
        sized(
          DropdownButtonFormField<LogTimeRange>(
            initialValue: _range,
            isExpanded: true,
            decoration: _decoration(l10n.logsPanelTimeRange),
            onChanged: (range) => setState(() => _range = range!),
            items: [
              for (final range in LogTimeRange.values)
                DropdownMenuItem(
                  value: range,
                  child: Text(l10n.logsPanelTimeRangeOption(range.name)),
                ),
            ],
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          widthFactor: 1,
          child: FilterChip(
            label: Text(l10n.logsPanelCurrentBoot),
            selected: _boot,
            onSelected: (boot) => setState(() => _boot = boot),
          ),
        ),
      ],
      FilledButton.tonal(
        onPressed: _draft.ready ? _apply : null,
        child: Text(l10n.logsPanelApply),
      ),
    ];

    if (!widget.sheet) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: fields,
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final field in fields)
          Padding(padding: const EdgeInsets.only(bottom: 12), child: field),
      ],
    );
  }

  InputDecoration _decoration(String label, {String? hint}) => InputDecoration(
    isDense: true,
    border: const OutlineInputBorder(),
    labelText: label,
    hintText: hint,
  );

  Widget _textField(TextEditingController controller, String label) =>
      TextField(
        controller: controller,
        autocorrect: false,
        decoration: _decoration(label),
        // Enter applies and keeps the focus in the field.
        onEditingComplete: () {},
        onSubmitted: (_) => _apply(),
      );

  Widget _pathField(AppLocalizations l10n) {
    final problem = logPathProblem(_path.text);
    return TextField(
      controller: _path,
      autocorrect: false,
      onChanged: (_) => setState(() {}),
      onEditingComplete: () {},
      onSubmitted: (_) => _apply(),
      decoration: _decoration(l10n.logsPanelPath, hint: l10n.logsPanelPathHint)
          .copyWith(
            errorText: problem == null || problem == LogPathProblem.empty
                ? null
                : l10n.logsPanelPathProblem(problem.name),
            errorMaxLines: 3,
            suffixIcon: PopupMenuButton<String>(
              tooltip: l10n.logsPanelCommonPaths,
              icon: const Icon(Icons.arrow_drop_down),
              onSelected: (path) {
                _path.text = path;
                _apply();
              },
              itemBuilder: (context) => [
                for (final path in kCommonLogPaths)
                  PopupMenuItem(value: path, child: Text(path)),
              ],
            ),
          ),
    );
  }
}

/// LOG-05's search field over the lines held, with case matching and
/// stepping; Enter steps to the next match.
class _SearchField extends StatefulWidget {
  const _SearchField({required this.search});

  final LogSearch search;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  late final _text = TextEditingController(text: widget.search.query);
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: widget.search,
      builder: (context, _) {
        final search = widget.search;
        final steppable = search.total > 0;
        return Row(
          children: [
            Expanded(
              child: TextField(
                controller: _text,
                autocorrect: false,
                textInputAction: TextInputAction.search,
                onChanged: (query) {
                  _debounce?.cancel();
                  _debounce = Timer(
                    _searchDebounce,
                    () => search.setQuery(query),
                  );
                },
                // Enter steps on and keeps the focus for the next step.
                onEditingComplete: () {},
                onSubmitted: (query) {
                  _debounce?.cancel();
                  search
                    ..setQuery(query)
                    ..next();
                },
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.search),
                  // A label, not a hint, so the field keeps its name for
                  // screen readers once it holds text.
                  labelText: l10n.logsPanelSearchLabel,
                  suffixText: search.query.isEmpty
                      ? null
                      : switch (search.currentNumber) {
                          final number? => l10n.logsPanelSearchPosition(
                            number,
                            search.total,
                          ),
                          null => l10n.logsPanelSearchMatches(search.total),
                        },
                ),
              ),
            ),
            // Outlined when off and filled when on, so the state shows by
            // more than colour (03 §10.10).
            IconButton.outlined(
              isSelected: search.caseSensitive,
              icon: const Icon(Icons.text_fields),
              tooltip: l10n.logsPanelSearchCase,
              onPressed: () => search.setCaseSensitive(!search.caseSensitive),
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_up),
              tooltip: l10n.logsPanelSearchPrevious,
              onPressed: steppable ? search.previous : null,
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down),
              tooltip: l10n.logsPanelSearchNext,
              onPressed: steppable ? search.next : null,
            ),
          ],
        );
      },
    );
  }
}

/// A line of state above the log: an icon, the words, and optionally the
/// host's output and an action. [announce] makes it a live region, for
/// the stream's state changes (03 §10.10).
class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.text,
    this.detail,
    this.action,
    this.announce = false,
  });

  final IconData icon;
  final String text;
  final String? detail;
  final Widget? action;
  final bool announce;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      liveRegion: announce,
      container: true,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: colors.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(text, style: theme.textTheme.bodyMedium),
                  if (detail case final detail?)
                    Text(
                      detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            ?action,
          ],
        ),
      ),
    );
  }
}
