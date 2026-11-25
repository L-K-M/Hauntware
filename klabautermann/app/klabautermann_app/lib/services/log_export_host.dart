// P1-03a: a saved or shared export is remote-sourced, so the host that
// writes one stamps it as downloaded and owner-only. The plugin-backed
// [LogExportHost] lives with the app's other file services; the
// interface and the export sheet stay under ui/logs.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

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
