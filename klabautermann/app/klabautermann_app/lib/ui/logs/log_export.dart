import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import 'log_view_controller.dart';

/// Where LOG-10's export goes besides the clipboard: a file the user
/// names, or the platform's share sheet. A host service, so tests, and
/// platforms without a share sheet, stand in for the plugins.
abstract interface class LogExportHost {
  /// Whether this platform has a share sheet to hand a file to.
  bool get canShare;

  /// Asks where to save [bytes] as [fileName] and writes them there;
  /// false when the user cancelled.
  Future<bool> save(String fileName, Uint8List bytes);

  /// Hands [bytes] as [fileName] to the share sheet, anchored at [origin]
  /// where the platform needs one (an iPad's popover).
  Future<void> share(String fileName, Uint8List bytes, {Rect? origin});
}

/// Marks an export file as remote-sourced and owner-only, best effort:
/// neither a failed mode change nor a failed mark may report a save that
/// wrote the file as failed (P1-03a).
Future<void> markSavedExport(String path, DownloadProvenance provenance) async {
  try {
    restrictFileToOwner(File(path));
  } on Object catch (error) {
    debugPrint('Could not restrict a saved export to the owner: $error');
  }
  try {
    await provenance.markDownloaded(path);
  } on Object {
    // markDownloaded logs its own failures; a mark never fails a save.
  }
}

/// The local path behind a saved export, or null when the platform's
/// picker handed back a document URI with no path to mark (Android's
/// `content://`, whose provider owns the file).
String? savedExportPath(Uri saved) =>
    saved.isScheme('file') ? saved.toFilePath() : null;

/// Writes [bytes] as [fileName] under a fresh temporary directory, marked
/// and owner-only like a saved export, so the share sheet hands on a file
/// the OS treats as untrusted (P1-03a). The caller owns the directory only
/// after staging succeeds; failed staging cleans it up.
Future<File> stageMarkedExport(
  String fileName,
  Uint8List bytes,
  DownloadProvenance provenance,
) async {
  final root = await getTemporaryDirectory();
  final directory = await root.createTemp('klabautermann-export-');
  try {
    final file = File('${directory.path}${Platform.pathSeparator}$fileName');
    await file.writeAsBytes(bytes, flush: true);
    await markSavedExport(file.path, provenance);
    return file;
  } catch (_) {
    await _deleteStagedExport(directory);
    rethrow;
  }
}

Future<void> _deleteStagedExport(Directory directory) async {
  try {
    if (await directory.exists()) await directory.delete(recursive: true);
  } catch (_) {
    // Temporary exports are also subject to normal OS cache eviction.
  }
}

/// [LogExportHost] over `file_picker`'s save dialog and `share_plus`.
final class PluginLogExportHost implements LogExportHost {
  PluginLogExportHost({
    DownloadProvenance? provenance,
    this.stagedRetention = const Duration(hours: 1),
  }) : provenance = provenance ?? DownloadProvenance(agent: 'Klabautermann');

  /// Stamps what this host writes; injectable for tests.
  final DownloadProvenance provenance;

  /// How long a shared staged export stays on disk so the sheet can read it.
  final Duration stagedRetention;

  @override
  bool get canShare => Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  @override
  Future<bool> save(String fileName, Uint8List bytes) async {
    // The app is not sandboxed on macOS (03 §10.2), so it holds none of
    // the user-selected-file entitlements the plugin otherwise demands.
    if (Platform.isMacOS) await FilePicker.skipEntitlementsChecks();
    final saved = await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      mimeType: 'text/plain',
    );
    if (saved == null) return false;
    final path = savedExportPath(saved);
    if (path != null) await markSavedExport(path, provenance);
    return true;
  }

  @override
  Future<void> share(String fileName, Uint8List bytes, {Rect? origin}) async {
    final file = await stageMarkedExport(fileName, bytes, provenance);
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/plain')],
          fileNameOverrides: [fileName],
          sharePositionOrigin: origin,
        ),
      );
      final directory = file.parent;
      Timer(stagedRetention, () {
        unawaited(_deleteStagedExport(directory));
      });
    } catch (_) {
      await _deleteStagedExport(file.parent);
      rethrow;
    }
  }
}

/// Puts a [LogExportHost] in place of the plugins' for the subtree.
class LogExportScope extends InheritedWidget {
  const LogExportScope({super.key, required this.host, required super.child});

  final LogExportHost host;

  /// The host in scope, or the plugins' when none is.
  static LogExportHost of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LogExportScope>()?.host ??
      PluginLogExportHost();

  @override
  bool updateShouldNotify(LogExportScope oldWidget) => oldWidget.host != host;
}

/// What LOG-10 exports of [logs]: each held row as the view shows it, a
/// journal row with its time, unit and PID and a container row with its
/// time and stream, without SGR escapes; dropped lines say how many in
/// [dropped]'s words.
List<String> logExportLines(
  LogViewController logs, {
  required String Function(int count) dropped,
}) => [
  for (var i = 0; i < logs.length; i++)
    switch (logs[i]) {
      final LogLine line => logs.rowText(line),
      LogDroppedLines(:final count) => dropped(count),
    },
];

/// Where an export goes.
enum LogExportTarget { copy, save, share }

/// Opens LOG-10's export sheet over the rows [logs] holds, as a bottom
/// sheet: the Logs panel's export, and a container's (CTX-06).
Future<void> showLogExport(
  BuildContext context, {
  required MonitoringController monitoring,
  required LogViewController logs,
  required String fileName,
}) {
  final l10n = AppLocalizations.of(context);
  return showExportSheet(
    context,
    monitoring: monitoring,
    lines: logExportLines(logs, dropped: l10n.logDroppedLines),
    fileName: fileName,
  );
}

/// Opens [LogExportSheet] over [lines] as a bottom sheet: LOG-10's log
/// exports, and PLT-08's status cards and inspect snapshots.
Future<void> showExportSheet(
  BuildContext context, {
  required MonitoringController monitoring,
  required List<String> lines,
  required String fileName,
  String? title,
  List<String>? namedLines,
}) {
  final host = LogExportScope.of(context);
  return showModalBottomSheet<void>(
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
        child: SingleChildScrollView(
          child: LogExportSheet(
            monitoring: monitoring,
            host: host,
            lines: lines,
            fileName: fileName,
            title: title,
            namedLines: namedLines,
          ),
        ),
      ),
    ),
  );
}

/// LOG-10's export sheet over [lines]: redacted through the engine's
/// secret redactor unless the user turns on Include secrets (SAF-07),
/// then copied, saved as [fileName] or shared. It pops once the export
/// went out. With [namedLines], a switch, off at first, exports those
/// instead: PLT-08's status card names its server only when asked.
class LogExportSheet extends StatefulWidget {
  const LogExportSheet({
    super.key,
    required this.monitoring,
    required this.host,
    required this.lines,
    required this.fileName,
    this.title,
    this.note,
    this.namedLines,
  });

  final MonitoringController monitoring;

  /// Where saves and shares go; the opener resolves it with
  /// [LogExportScope.of], since the sheet's own route is outside the
  /// scope.
  final LogExportHost host;
  final List<String> lines;
  final String fileName;

  /// The sheet's title; a log export's line count by default.
  final String? title;

  /// A paragraph under the title, if any.
  final String? note;

  /// [lines] with the server named, if they leave it out.
  final List<String>? namedLines;

  @override
  State<LogExportSheet> createState() => _LogExportSheetState();
}

class _LogExportSheetState extends State<LogExportSheet> {
  bool _includeSecrets = false;
  bool _named = false;
  LogExportTarget? _busy;

  Future<void> _export(LogExportTarget target) async {
    final l10n = AppLocalizations.of(context);
    final host = widget.host;
    final overlay = Overlay.of(context, rootOverlay: true);
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _busy = target);

    void say(String message) {
      if (overlay.mounted) showTopToast(overlay, message: message);
    }

    final lines = _named ? widget.namedLines ?? widget.lines : widget.lines;
    final text = _includeSecrets
        ? lines.join('\n')
        : await widget.monitoring.redactLines(lines);
    if (!mounted) return;
    if (text == null) {
      setState(() => _busy = null);
      // Never a fallback to the unredacted text.
      say(l10n.logsExportNotRedacted);
      return;
    }

    final bytes = Uint8List.fromList(utf8.encode('$text\n'));
    try {
      switch (target) {
        case LogExportTarget.copy:
          await Clipboard.setData(ClipboardData(text: text));
          say(l10n.logsExportDone(target.name));
        case LogExportTarget.save:
          if (!await host.save(widget.fileName, bytes)) {
            if (mounted) setState(() => _busy = null);
            return;
          }
          say(l10n.logsExportDone(target.name));
        case LogExportTarget.share:
          await host.share(widget.fileName, bytes, origin: origin);
      }
    } on Exception {
      if (mounted) setState(() => _busy = null);
      say(l10n.logsExportFailed(target.name));
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final host = widget.host;
    final busy = _busy != null;

    Widget action(LogExportTarget target, IconData icon) =>
        FilledButton.tonalIcon(
          onPressed: busy ? null : () => _export(target),
          icon: _busy == target
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(icon),
          label: Text(l10n.logsExportAction(target.name)),
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.title ?? l10n.logsExportTitle(widget.lines.length),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (widget.note case final note?) ...[
          const SizedBox(height: 8),
          Text(note),
        ],
        const SizedBox(height: 8),
        if (widget.namedLines != null)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _named,
            onChanged: busy ? null : (value) => setState(() => _named = value),
            title: Text(l10n.exportNameServer),
            subtitle: Text(
              _named ? l10n.exportServerNamed : l10n.exportServerUnnamed,
            ),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _includeSecrets,
          onChanged: busy
              ? null
              : (value) => setState(() => _includeSecrets = value),
          title: Text(l10n.logsExportIncludeSecrets),
          subtitle: Text(
            _includeSecrets
                ? l10n.logsExportSecretsIncluded
                : l10n.logsExportSecretsRedacted,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            action(LogExportTarget.copy, Icons.copy),
            action(LogExportTarget.save, Icons.save_alt),
            if (host.canShare) action(LogExportTarget.share, Icons.ios_share),
          ],
        ),
      ],
    );
  }
}
