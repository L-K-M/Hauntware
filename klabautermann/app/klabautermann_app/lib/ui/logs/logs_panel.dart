import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show ghostFormatBinarySize;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import 'log_export.dart';
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
  searchUnsupported,
  needsPath,
}

/// The boot picker's choices other than a past boot
/// ([AppLocalizations.logsPanelBootChoice]).
enum _BootWord { all, current }

/// The states after which reading again may help.
const _retryable = {
  _StatusWord.rejected,
  _StatusWord.missing,
  _StatusWord.denied,
  _StatusWord.failed,
};

_LiveWord _liveWord(LogsPanelController panel) {
  // A past boot has nothing new to follow.
  if (!panel.canFollow) return _LiveWord.stopped;
  if (!panel.live) return _LiveWord.paused;
  if (panel.rejected) return _LiveWord.unavailable;
  if (!panel.ready) return _LiveWord.stopped;
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
  if (!panel.ready) return _StatusWord.needsPath;
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
      // Only a container's logs end for their driver, and their view
      // names it in place of this status (ContainerLogsView).
      LogStreamEndReason.failed ||
      LogStreamEndReason.logDriverUnreadable => _StatusWord.failed,
      LogStreamEndReason.searchUnsupported => _StatusWord.searchUnsupported,
      LogStreamEndReason.windowFilled ||
      LogStreamEndReason.oldestReached ||
      LogStreamEndReason.closed => null,
    },
    null => null,
  };
}

/// Whether [panel]'s read ended with no entries and nothing else to say,
/// so the view says the log is empty.
bool logsPanelEndedEmpty(LogsPanelController panel) =>
    panel.logs.length == 0 &&
    panel.status is LogStreamEnded &&
    _statusWord(panel) == null;

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
            final journal = _panel.query.source == LogSourceKind.journal;
            final search = LogSearchField(
              search: _panel.search,
              // LOG-06: the journal can match on the server.
              onSearchServer: journal
                  ? (pattern) => _panel.apply(_panel.query.withGrep(pattern))
                  : null,
            );
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
                if (journal && _panel.query.grep.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: InputChip(
                        avatar: const Icon(Icons.travel_explore, size: 18),
                        // The pattern is shown as sent to the server.
                        label: Text(
                          l10n.logsPanelServerMatch(_panel.query.grep),
                        ),
                        deleteButtonTooltipMessage:
                            l10n.logsPanelServerMatchClear,
                        onDeleted: () =>
                            _panel.apply(_panel.query.withGrep('')),
                      ),
                    ),
                  ),
                ValueListenableBuilder(
                  valueListenable: widget.monitoring.logs.journalLimitedFor(
                    widget.serverId,
                  ),
                  builder: (context, limited, _) =>
                      switch (_panel.query.source) {
                        _ when limited != true => const SizedBox.shrink(),
                        LogSourceKind.journal => LogNotice(
                          icon: Icons.info_outline,
                          text: l10n.logsPanelJournalLimited,
                        ),
                        // The journal shows such an account no kernel
                        // messages (K04's kPanelNeeds); `dmesg` may.
                        LogSourceKind.kernel => LogNotice(
                          icon: Icons.info_outline,
                          text: l10n.logsPanelKernelLimited,
                        ),
                        // A file is read with the file's rights.
                        LogSourceKind.file => const SizedBox.shrink(),
                      },
                ),
                LogStatusNotice(panel: _panel),
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
            onBrowse: _browseFiles,
          ),
        if (query.source != LogSourceKind.file)
          OutlinedButton.icon(
            onPressed: _pickBoot,
            icon: const Icon(Icons.history),
            label: Text(_bootLabel(l10n, query)),
          ),
        LogLiveChip(panel: _panel),
        ListenableBuilder(
          listenable: _panel.logs,
          builder: (context, _) => IconButton(
            tooltip: l10n.logsExport,
            icon: const Icon(Icons.ios_share),
            onPressed: _panel.logs.length == 0 ? null : _export,
          ),
        ),
        if (!compact)
          SizedBox(
            width: MediaQuery.textScalerOf(context).scale(_fieldWidth * 2.25),
            child: search,
          ),
      ],
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
      if (logsPanelEndedEmpty(_panel))
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

  String _bootLabel(AppLocalizations l10n, LogQuery query) =>
      switch (query.pastBoot) {
        final boot? => l10n.logsPanelBootPast(-boot.offset),
        // The kernel log reads the current boot unless a past one is set.
        null
            when query.currentBootOnly ||
                query.source == LogSourceKind.kernel =>
          l10n.logsPanelBootChoice(_BootWord.current.name),
        null => l10n.logsPanelBootChoice(_BootWord.all.name),
      };

  /// LOG-09's boot picker: every boot (the journal only), this boot, or
  /// a past one from the server's list.
  Future<void> _pickBoot() async {
    final query = _panel.query;
    final picked = await _sheet<LogBootChoice>(
      (context) => LogBootPicker(
        boots: widget.monitoring.queryHost(widget.serverId, const BootsQuery()),
        query: query,
      ),
    );
    if (!mounted || picked == null) return;
    _panel.apply(_panel.query.withBoot(picked.past, current: picked.current));
  }

  /// LOG-10: the held lines, redacted unless the user says otherwise.
  Future<void> _export() {
    final l10n = AppLocalizations.of(context);
    final lines = logExportLines(_panel.logs, dropped: l10n.logDroppedLines);
    return _sheet<void>(
      (sheetContext) => LogExportSheet(
        monitoring: widget.monitoring,
        host: LogExportScope.of(context),
        lines: lines,
        fileName: l10n.logsExportFileName(_panel.query.source.name),
      ),
    );
  }

  Future<void> _editFilters() => _sheet<void>(
    (context) => _FilterForm(
      query: _panel.query,
      sheet: true,
      onApply: (query) {
        Navigator.pop(context);
        _panel.apply(query);
      },
      onBrowse: _browseFiles,
    ),
  );

  /// LOG-08's `/var/log` browser: the path picked, or null.
  Future<String?> _browseFiles() => _sheet<String>(
    (context) => LogFilePicker(
      files: widget.monitoring.queryHost(widget.serverId, const VarLogQuery()),
      selected: _panel.query.path,
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
    required this.onBrowse,
  });

  final LogQuery query;
  final bool sheet;
  final ValueChanged<LogQuery> onApply;

  /// Opens LOG-08's `/var/log` browser, completing with the path picked.
  final Future<String?> Function() onBrowse;

  @override
  State<_FilterForm> createState() => _FilterFormState();
}

class _FilterFormState extends State<_FilterForm> {
  late final _unit = TextEditingController(text: widget.query.unit);
  late final _identifier = TextEditingController(text: widget.query.identifier);
  late final _path = TextEditingController(text: widget.query.path);
  late LogPriority? _priority = widget.query.priority;
  late LogTimeRange _range = widget.query.range;

  // The boot and the server search are the bar's; the form keeps them.
  LogQuery get _draft => LogQuery(
    source: widget.query.source,
    unit: _unit.text.trim(),
    identifier: _identifier.text.trim(),
    priority: _priority,
    currentBootOnly: widget.query.currentBootOnly,
    pastBoot: widget.query.pastBoot,
    range: _range,
    grep: widget.query.grep,
    path: _path.text,
  );

  void _apply() {
    final draft = _draft;
    if (draft.ready) widget.onApply(draft);
  }

  Future<void> _browse() async {
    final path = await widget.onBrowse();
    if (!mounted || path == null) return;
    setState(() => _path.text = path);
    _apply();
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
      if (file) ...[
        sized(_pathField(l10n), factor: 2),
        OutlinedButton.icon(
          onPressed: _browse,
          icon: const Icon(Icons.folder_open),
          label: Text(l10n.logsPanelBrowseFiles),
        ),
      ] else ...[
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

/// LOG-02's Live chip over [panel]'s stream: on follows, off reads a
/// window or keeps what the follow showed. It names the stream's state
/// by word and icon, never by colour alone.
class LogLiveChip extends StatelessWidget {
  const LogLiveChip({super.key, required this.panel});

  final LogsPanelController panel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final word = _liveWord(panel);
    return FilterChip(
      selected: panel.live,
      showCheckmark: false,
      avatar: Icon(word.icon, size: 18),
      label: Text(l10n.logsPanelLiveState(word.name)),
      tooltip: panel.canFollow
          ? l10n.logsPanelLiveTooltip
          : panel.query.source == LogSourceKind.file
          ? l10n.logsPanelLiveCompressed
          : l10n.logsPanelLivePastBoot,
      onSelected: panel.canFollow ? panel.setLive : null,
    );
  }
}

/// The status line over [panel]'s stream, a live region: what the read
/// is doing or why it stopped, with any host error output and a Retry
/// where reading again may help; nothing while a follow runs.
class LogStatusNotice extends StatelessWidget {
  const LogStatusNotice({super.key, required this.panel});

  final LogsPanelController panel;

  @override
  Widget build(BuildContext context) {
    final word = _statusWord(panel);
    if (word == null) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final retry = _retryable.contains(word);
    return LogNotice(
      icon: switch (word) {
        _ when retry => Icons.error_outline,
        _StatusWord.gap => Icons.info_outline,
        _ => Icons.hourglass_empty,
      },
      text: l10n.logsPanelStatus(word.name),
      // The host's error output is server data, shown as sent.
      detail: switch (panel.status) {
        LogStreamEnded(:final detail?) => detail,
        _ => null,
      },
      action: retry
          ? TextButton(onPressed: panel.retry, child: Text(l10n.logsPanelRetry))
          : null,
      announce: true,
    );
  }
}

/// LOG-05's search field over the lines held, with case matching, LOG-06's
/// regular expressions and stepping; Enter steps to the next match. With
/// [onSearchServer], a button hands the search to the server as a
/// journalctl pattern ([serverLogPattern]).
class LogSearchField extends StatefulWidget {
  const LogSearchField({super.key, required this.search, this.onSearchServer});

  final LogSearch search;
  final ValueChanged<String>? onSearchServer;

  @override
  State<LogSearchField> createState() => _LogSearchFieldState();
}

class _LogSearchFieldState extends State<LogSearchField> {
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
        final onSearchServer = widget.onSearchServer;
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
                  errorText: search.invalidPattern
                      ? l10n.logsPanelSearchInvalid
                      : null,
                  suffixText: search.query.isEmpty || search.invalidPattern
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
            IconButton.outlined(
              isSelected: search.regex,
              icon: const Icon(Icons.data_object),
              tooltip: l10n.logsPanelSearchRegex,
              onPressed: () => search.setRegex(!search.regex),
            ),
            if (onSearchServer != null)
              IconButton(
                icon: const Icon(Icons.travel_explore),
                tooltip: l10n.logsPanelSearchServer,
                onPressed: search.query.isEmpty || search.invalidPattern
                    ? null
                    : () => onSearchServer(
                        serverLogPattern(
                          search.query,
                          regex: search.regex,
                          caseSensitive: search.caseSensitive,
                        ),
                      ),
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

/// What [LogBootPicker] chose: a [past] boot, or none, with [current]
/// for this boot rather than every boot.
typedef LogBootChoice = ({JournalBootEntry? past, bool current});

/// LOG-09's boot picker over [boots], the server's answer to a
/// [BootsQuery]: every boot (the journal only), this boot, and the past
/// ones, newest first, each with when its entries start and end. It pops
/// a [LogBootChoice].
class LogBootPicker extends StatelessWidget {
  const LogBootPicker({super.key, required this.boots, required this.query});

  final Future<HostResult> boots;
  final LogQuery query;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final journal = query.source == LogSourceKind.journal;
    final past = query.pastBoot;

    Widget choice(
      String title, {
      String? subtitle,
      required bool selected,
      required LogBootChoice value,
    }) => ListTile(
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      selected: selected,
      trailing: selected ? const Icon(Icons.check) : null,
      onTap: () => Navigator.pop(context, value),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.logsPanelBoot,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (journal)
          choice(
            l10n.logsPanelBootChoice(_BootWord.all.name),
            selected: past == null && !query.currentBootOnly,
            value: (past: null, current: false),
          ),
        choice(
          l10n.logsPanelBootChoice(_BootWord.current.name),
          selected: past == null && (query.currentBootOnly || !journal),
          value: (past: null, current: true),
        ),
        FutureBuilder(
          future: boots,
          builder: (context, snapshot) => switch (snapshot.data?.payload) {
            null => _sheetNote(context, l10n.logsPanelBootsLoading),
            JournalBoots(:final boots) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final boot
                    in boots.where((boot) => boot.offset < 0).toList()
                      ..sort((a, b) => b.offset.compareTo(a.offset)))
                  choice(
                    l10n.logsPanelBootPast(-boot.offset),
                    subtitle: _span(context, l10n, boot),
                    selected: past?.id == boot.id,
                    value: (past: boot, current: false),
                  ),
              ],
            ),
            HostQueryFailed(:final failure) => _sheetNote(
              context,
              l10n.logsPanelBootsFailed(failure.name),
            ),
            _ => _sheetNote(
              context,
              l10n.logsPanelBootsFailed(HostQueryFailure.failed.name),
            ),
          },
        ),
      ],
    );
  }

  /// When [boot]'s entries start and end, in local time; null when the
  /// server did not say.
  static String? _span(
    BuildContext context,
    AppLocalizations l10n,
    JournalBootEntry boot,
  ) {
    final first = boot.firstEntry, last = boot.lastEntry;
    if (first == null || last == null) return null;
    return l10n.logsPanelBootSpan(
      _localTime(context, l10n, first),
      _localTime(context, l10n, last),
    );
  }
}

/// LOG-08's `/var/log` browser over a [VarLogQuery]'s [files]: each
/// file's path, size and last change, with rotated archives marked
/// compressed and the files the login user may not read marked as
/// needing admin mode, in words beside the icon. A filter narrows a long
/// listing by path; picking a file pops its path.
class LogFilePicker extends StatefulWidget {
  const LogFilePicker({super.key, required this.files, required this.selected});

  final Future<HostResult> files;

  /// The path the panel reads now, marked in the list.
  final String selected;

  @override
  State<LogFilePicker> createState() => _LogFilePickerState();
}

class _LogFilePickerState extends State<LogFilePicker> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.logsPanelFiles,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _filter,
          autocorrect: false,
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            labelText: l10n.logsPanelFilesFilter,
            prefixIcon: const Icon(Icons.search),
          ),
          onChanged: (_) => setState(() {}),
        ),
        FutureBuilder(
          future: widget.files,
          builder: (context, snapshot) => switch (snapshot.data?.payload) {
            null => _sheetNote(context, l10n.logsPanelFilesLoading),
            VarLogFiles(:final files) => _list(context, l10n, files),
            HostQueryFailed(:final failure) => _sheetNote(
              context,
              l10n.logsPanelFilesFailed(failure.name),
            ),
            _ => _sheetNote(
              context,
              l10n.logsPanelFilesFailed(HostQueryFailure.failed.name),
            ),
          },
        ),
      ],
    );
  }

  Widget _list(
    BuildContext context,
    AppLocalizations l10n,
    List<LogFileEntry> files,
  ) {
    if (files.isEmpty) return _sheetNote(context, l10n.logsPanelFilesEmpty);
    final filter = _filter.text.trim().toLowerCase();
    final shown = [
      for (final file in files)
        if (file.path.toLowerCase().contains(filter)) file,
    ];
    if (shown.isEmpty) return _sheetNote(context, l10n.logsPanelFilesNoMatch);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final file in shown) _row(context, l10n, file)],
    );
  }

  Widget _row(BuildContext context, AppLocalizations l10n, LogFileEntry file) {
    final compressed = file.compression != LogCompression.none;
    final selected = file.path == widget.selected;
    return ListTile(
      leading: Icon(
        !file.readable
            ? Icons.lock_outline
            : compressed
            ? Icons.folder_zip_outlined
            : Icons.description_outlined,
      ),
      title: Text(file.path),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.logsPanelFileDetails(
              ghostFormatBinarySize(file.bytes),
              _localTime(context, l10n, file.modified),
            ),
          ),
          if (compressed) Text(l10n.logsPanelFileCompressed),
          if (!file.readable) Text(l10n.logsPanelFileUnreadable),
        ],
      ),
      selected: selected,
      trailing: selected ? const Icon(Icons.check) : null,
      onTap: () => Navigator.pop(context, file.path),
    );
  }
}

/// A picker sheet's line of state: loading, empty or failed.
Widget _sheetNote(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
);

/// [time] as a short date and a time of day, in local time.
String _localTime(BuildContext context, AppLocalizations l10n, DateTime time) {
  final localizations = MaterialLocalizations.of(context);
  final local = time.toLocal();
  return l10n.activityTime(
    localizations.formatShortDate(local),
    localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local)),
  );
}

/// A line of state above the log: an icon, the words, and optionally the
/// host's output and an action. [announce] makes it a live region, for
/// the stream's state changes (03 §10.10).
class LogNotice extends StatelessWidget {
  const LogNotice({
    super.key,
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
