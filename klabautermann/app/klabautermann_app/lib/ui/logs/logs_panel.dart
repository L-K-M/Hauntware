import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import 'log_export.dart';
import 'log_level.dart';
import 'log_notices.dart';
import 'log_pickers.dart';
import 'log_query.dart';
import 'log_search_field.dart';
import 'log_view.dart';
import 'logs_panel_controller.dart';

/// Below this width at 100 % text the panel takes the phone's layout (03
/// §10.5); the bar's controls grow with the text, and so does the width.
const double _phoneWidth = 600;

/// A filter field's width at 100 % text; it grows with the text.
const double _fieldWidth = 200;

const Map<LogSourceKind, IconData> _sourceIcons = {
  LogSourceKind.journal: Icons.article_outlined,
  LogSourceKind.kernel: Icons.memory,
  LogSourceKind.file: Icons.description_outlined,
};

/// Whether [panel]'s read ended with no entries and nothing else to say,
/// so the view says the log is empty.
bool logsPanelEndedEmpty(LogsPanelController panel) =>
    panel.logs.length == 0 &&
    panel.status is LogStreamEnded &&
    statusWord(panel) == null;

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
              compact: compact,
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
          l10n.logsPanelBootChoice(BootWord.current.name),
        null => l10n.logsPanelBootChoice(BootWord.all.name),
      };

  /// LOG-09's boot picker: every boot (the journal only), this boot, or
  /// a past one from the server's list.
  Future<void> _pickBoot() async {
    final query = _panel.query;
    final picked = await _sheet<LogBootChoice>(
      (context) => LogBootPicker(
        serverId: widget.serverId,
        boots: widget.monitoring.hostReads.queryHost(
          widget.serverId,
          const BootsQuery(),
        ),
        query: query,
      ),
    );
    if (!mounted || picked == null) return;
    _panel.apply(_panel.query.withBoot(picked.past, current: picked.current));
  }

  /// LOG-10: the held lines, redacted unless the user says otherwise.
  Future<void> _export() => showLogExport(
    context,
    monitoring: widget.monitoring,
    logs: _panel.logs,
    fileName: AppLocalizations.of(
      context,
    ).logsExportFileName(_panel.query.source.name),
  );

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
      serverId: widget.serverId,
      files: widget.monitoring.hostReads.queryHost(
        widget.serverId,
        const VarLogQuery(),
      ),
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
