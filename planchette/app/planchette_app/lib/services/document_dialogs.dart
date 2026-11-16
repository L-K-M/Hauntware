import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart';
import 'package:path/path.dart' as paths;

import '../l10n/app_localizations.dart';
import 'android_documents.dart';
import 'document_windows.dart';
import 'document_workspace.dart';
import 'document_store.dart';
import 'template_strings.dart';

final class AppDocumentDialogs implements DocumentDialogs {
  AppDocumentDialogs(this.navigatorKey, {this.pickers, this.android});
  final GlobalKey<NavigatorState> navigatorKey;
  final AndroidDocuments? android;

  /// The window's own native file dialogs. file_selector parents every
  /// dialog to the plugin registry's view — the main window — which may be
  /// hidden while other windows are open, so a window that can be one of
  /// several asks the runner for a dialog owned by its own view instead.
  final WindowPickers? pickers;

  /// The window's strings. A native picker can be asked for before the
  /// navigator has a context; its button then reads in English, the
  /// catalog's template locale. The window's workspace reads its messages
  /// here too.
  AppLocalizations get strings {
    final context = navigatorKey.currentContext;
    if (context == null) return templateStrings();
    return AppLocalizations.of(context);
  }

  // file_selector shows each platform's own dialog. On Linux that is GTK's
  // chooser, which goes through the desktop portal only where GTK would, so
  // Open and Save As work on desktops that run no portal service.
  @override
  Future<List<String>> pickOpenFiles() async {
    final documents = android;
    if (documents != null) return documents.pickOpenFiles();
    final window = pickers;
    if (window != null && window.available) {
      return window.pickOpenFiles();
    }
    final files = await openFiles(confirmButtonText: strings.actionOpen);
    return [for (final file in files) file.path];
  }

  Future<String?> pickDirectory() {
    final window = pickers;
    if (window != null && window.available) return window.pickDirectory();
    return getDirectoryPath(confirmButtonText: strings.pickerOpenFolder);
  }

  /// Key picking shares the window-owned dialog and bounded UTF-8 reader.
  Future<String?> pickKeyText() async {
    final selected = await pickOpenFiles();
    if (selected.isEmpty) return null;
    if (selected.length != 1) {
      throw FormatException(strings.pickerOneKeyFile);
    }
    return (await LocalDocumentStore().load(selected.single)).text;
  }

  @override
  Future<String?> pickSavePath(String suggestedName) async {
    final documents = android;
    if (documents != null) {
      return documents.pickSavePath(paths.basename(suggestedName));
    }
    final window = pickers;
    if (window != null && window.available) {
      return window.pickSavePath(
        suggestedName: paths.basename(suggestedName),
        initialDirectory: _initialDirectory(suggestedName),
      );
    }
    final location = await getSaveLocation(
      suggestedName: paths.basename(suggestedName),
      initialDirectory: _initialDirectory(suggestedName),
      confirmButtonText: strings.actionSave,
    );
    return location?.path;
  }

  /// The folder of an absolute [suggestedName], if it is still there. A
  /// remembered folder may be gone or on a disk that is not connected; the
  /// system's own default is better than a dialog that cannot open there.
  static String? _initialDirectory(String suggestedName) {
    if (!paths.isAbsolute(suggestedName)) return null;
    final folder = paths.dirname(suggestedName);
    try {
      return Directory(folder).existsSync() ? folder : null;
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<bool> confirmReplace(String path) async {
    final context = navigatorKey.currentContext;
    if (context == null) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              AppLocalizations.of(context).replaceTitle(paths.basename(path)),
            ),
            content: Text(AppLocalizations.of(context).replaceBody),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(AppLocalizations.of(context).actionCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(AppLocalizations.of(context).replaceAction),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Future<BulkCloseChoice> chooseBulkClose(List<String> names) async {
    // The workspace offers this question only when more than one document is
    // unsaved; a single one gets the prompt that names its file.
    assert(names.length > 1, 'the bulk close question covers several files');
    final context = navigatorKey.currentContext;
    if (context == null) return BulkCloseChoice.cancel;
    final l10n = AppLocalizations.of(context);
    final choice = await showGhostCloseDialog(
      context,
      title: l10n.bulkCloseTitle(names.length),
      body: l10n.bulkCloseBody(_listed(names, l10n)),
      saveLabel: l10n.bulkCloseSaveAll,
    );
    return switch (choice) {
      GhostCloseChoice.save => BulkCloseChoice.saveAll,
      GhostCloseChoice.dontSave => BulkCloseChoice.discardAll,
      GhostCloseChoice.cancel => BulkCloseChoice.cancel,
      null => BulkCloseChoice.cancel,
    };
  }

  @override
  Future<CloseChoice> chooseClose(String name) async {
    final context = navigatorKey.currentContext;
    if (context == null) return CloseChoice.cancel;
    final l10n = AppLocalizations.of(context);
    final choice = await showGhostCloseDialog(
      context,
      title: l10n.closeTitle(name),
      body: l10n.closeBody,
    );
    return switch (choice) {
      GhostCloseChoice.save => CloseChoice.save,
      GhostCloseChoice.dontSave => CloseChoice.discard,
      GhostCloseChoice.cancel => CloseChoice.cancel,
      null => CloseChoice.cancel,
    };
  }

  @override
  Future<ReadOnlyChoice> chooseReadOnlySave(String name) async {
    final context = navigatorKey.currentContext;
    if (context == null) return ReadOnlyChoice.cancel;
    return await showDialog<ReadOnlyChoice>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(AppLocalizations.of(context).readOnlyTitle(name)),
            content: Text(AppLocalizations.of(context).readOnlyBody),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, ReadOnlyChoice.cancel),
                child: Text(AppLocalizations.of(context).actionCancel),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, ReadOnlyChoice.saveAnyway),
                child: Text(AppLocalizations.of(context).readOnlySaveAnyway),
              ),
              FilledButton(
                autofocus: true,
                onPressed: () => Navigator.pop(context, ReadOnlyChoice.saveAs),
                child: Text(AppLocalizations.of(context).actionSaveAs),
              ),
            ],
          ),
        ) ??
        ReadOnlyChoice.cancel;
  }

  @override
  Future<bool> confirmRevert(String name) async {
    final context = navigatorKey.currentContext;
    if (context == null) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(AppLocalizations.of(context).revertTitle(name)),
            content: Text(AppLocalizations.of(context).revertBody),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.pop(context, false),
                child: Text(AppLocalizations.of(context).actionCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(AppLocalizations.of(context).revertAction),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Future<bool> confirmDiscardRecovery(String name) async {
    final context = navigatorKey.currentContext;
    if (context == null) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(AppLocalizations.of(context).recoveryDeleteTitle(name)),
            content: Text(AppLocalizations.of(context).recoveryDeleteBody),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.pop(context, false),
                child: Text(AppLocalizations.of(context).actionKeep),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(AppLocalizations.of(context).actionDelete),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Future<bool> offerSaveElsewhere(String name, String folder) async {
    final context = navigatorKey.currentContext;
    if (context == null) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(AppLocalizations.of(context).saveElsewhereTitle(name)),
            content: Text(
              AppLocalizations.of(context).saveElsewhereBody(folder),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(AppLocalizations.of(context).actionCancel),
              ),
              FilledButton(
                autofocus: true,
                onPressed: () => Navigator.pop(context, true),
                child: Text(AppLocalizations.of(context).actionSaveAs),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Future<SaveSiblingChoice> chooseSaveSiblings(
    String name,
    List<String> siblings,
  ) async {
    final context = navigatorKey.currentContext;
    if (context == null) return SaveSiblingChoice.keep;
    return await showDialog<SaveSiblingChoice>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(AppLocalizations.of(context).siblingsTitle(name)),
            content: Text(
              AppLocalizations.of(context).siblingsBody(
                siblings.length,
                _listed(siblings, AppLocalizations.of(context)),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, SaveSiblingChoice.delete),
                child: Text(AppLocalizations.of(context).actionDelete),
              ),
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.pop(context, SaveSiblingChoice.keep),
                child: Text(AppLocalizations.of(context).actionKeep),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, SaveSiblingChoice.open),
                child: Text(AppLocalizations.of(context).actionOpen),
              ),
            ],
          ),
        ) ??
        SaveSiblingChoice.keep;
  }
}

/// A short list of file names for a prompt: a long selection still fits.
String _listed(List<String> names, AppLocalizations l10n) {
  const shown = 8;
  if (names.length <= shown) return names.join('\n');
  return l10n.listedMore(names.take(shown).join('\n'), names.length - shown);
}
