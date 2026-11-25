import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show ghostFormatBinarySize;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../l10n/app_localizations.dart';
import '../hand_off_actions.dart'
    show FileHandOff, FolderHandOffs, folderHandOffsShown;
import '../time_display.dart';
import 'log_query.dart';

/// The boot picker's choices other than a past boot
/// ([AppLocalizations.logsPanelBootChoice]).
enum BootWord { all, current }

/// What [LogBootPicker] chose: a [past] boot, or none, with [current]
/// for this boot rather than every boot.
typedef LogBootChoice = ({JournalBootEntry? past, bool current});

/// LOG-09's boot picker over [boots], the server's answer to a
/// [BootsQuery]: every boot (the journal only), this boot, and the past
/// ones, newest first, each with when its entries start and end. It pops
/// a [LogBootChoice].
class LogBootPicker extends StatelessWidget {
  const LogBootPicker({
    super.key,
    required this.serverId,
    required this.boots,
    required this.query,
  });

  final String serverId;

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
            l10n.logsPanelBootChoice(BootWord.all.name),
            selected: past == null && !query.currentBootOnly,
            value: (past: null, current: false),
          ),
        choice(
          l10n.logsPanelBootChoice(BootWord.current.name),
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
                    subtitle: _span(context, l10n, serverId, boot),
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

  /// When [boot]'s entries start and end, as the time display shows
  /// [serverId]'s times; null when the server did not say.
  static String? _span(
    BuildContext context,
    AppLocalizations l10n,
    String serverId,
    JournalBootEntry boot,
  ) {
    final first = boot.firstEntry, last = boot.lastEntry;
    if (first == null || last == null) return null;
    return l10n.logsPanelBootSpan(
      serverTimeText(context, l10n, serverId, first),
      serverTimeText(context, l10n, serverId, last),
    );
  }
}

/// LOG-08's `/var/log` browser over a [VarLogQuery]'s [files]: each
/// file's path, size and last change, with rotated archives marked
/// compressed and the files the login user may not read marked as
/// needing admin mode, in words beside the icon. A filter narrows a long
/// listing by path; picking a file pops its path. The folder opens in
/// Séance and Poltergeist, and each file in Poltergeist, where they take
/// links (X-04, X-10).
class LogFilePicker extends StatefulWidget {
  const LogFilePicker({
    super.key,
    required this.serverId,
    required this.files,
    required this.selected,
  });

  final String serverId;
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
        if (folderHandOffsShown(
          context,
          serverId: widget.serverId,
          folder: _varLog,
        ))
          FolderHandOffs(serverId: widget.serverId, folder: _varLog),
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
              serverTimeText(context, l10n, widget.serverId, file.modified),
            ),
          ),
          if (compressed) Text(l10n.logsPanelFileCompressed),
          if (!file.readable) Text(l10n.logsPanelFileUnreadable),
        ],
      ),
      selected: selected,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected) const Icon(Icons.check),
          FileHandOff(serverId: widget.serverId, path: file.path),
        ],
      ),
      onTap: () => Navigator.pop(context, file.path),
    );
  }
}

/// The folder LOG-08 browses.
const _varLog = '/var/log';

/// A picker sheet's line of state: loading, empty or failed.
Widget _sheetNote(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
);

/// [time], which [serverId] reported, as a short date and a time of day
/// as the time display shows it (A11Y-07).
String serverTimeText(
  BuildContext context,
  AppLocalizations l10n,
  String serverId,
  DateTime time,
) {
  final localizations = MaterialLocalizations.of(context);
  final local = displayTime(context, serverId, time);
  return l10n.activityTime(
    localizations.formatShortDate(local),
    localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local)),
  );
}
