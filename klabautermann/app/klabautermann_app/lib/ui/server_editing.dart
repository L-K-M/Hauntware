import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:ghost_servers/ghost_servers.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show kBadgeImageAppleExtensions, kBadgeImageExtensions, showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/fleet_controller.dart';
import '../controllers/server_editor_controller.dart';
import '../controllers/sync_controller.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'server_editor_strings.dart';

/// In-app server editing for the surfaces under [ServerEditingScope]
/// (FL-03, M5 plan M09a): the engine's editor controller, and the sync
/// account editing needs. Editing is offered only while an account is
/// enrolled (P16); ssh_config imports stay read-only.
final class ServerEditing {
  const ServerEditing({
    required this.editor,
    required this.sync,
    required this.fleet,
  });

  final ServerEditorController editor;
  final SyncController sync;
  final FleetController fleet;

  /// Whether a server may be added, edited or deleted now.
  bool get enabled => sync.account != null;

  /// Whether [server] may be edited or deleted now: a synced server while
  /// enrolled.
  bool canEdit(FleetServer server) =>
      enabled && server.origin == FleetEntryOrigin.synced;

  // By its parts, so a rebuild that makes a new one over the same
  // controllers does not notify the scope's dependents.
  @override
  bool operator ==(Object other) =>
      other is ServerEditing &&
      identical(other.editor, editor) &&
      identical(other.sync, sync) &&
      identical(other.fleet, fleet);

  @override
  int get hashCode => Object.hash(editor, sync, fleet);
}

/// Puts [ServerEditing] in reach of the rows, the shells and Settings.
class ServerEditingScope extends InheritedWidget {
  const ServerEditingScope({
    super.key,
    required this.editing,
    required super.child,
  });

  final ServerEditing editing;

  static ServerEditing? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ServerEditingScope>()?.editing;

  @override
  bool updateShouldNotify(ServerEditingScope oldWidget) =>
      editing != oldWidget.editing;
}

/// Opens the editor on the synced server [serverId], or on a new server
/// when null. An existing server is read back from the engine first, so
/// the form starts from what the catalog holds now; one the catalog no
/// longer lists says so instead.
Future<void> openServerEditor(
  BuildContext context,
  ServerEditing editing, {
  String? serverId,
}) async {
  final l10n = AppLocalizations.of(context);
  final overlay = Overlay.of(context, rootOverlay: true);
  GhostServerDraft? existing;
  if (serverId != null) {
    final ServerDraft? draft;
    try {
      draft = await editing.editor.read(serverId);
    } on ServerEditEngineStopped {
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.serverEditEngineStopped);
      }
      return;
    }
    if (draft == null) {
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.serverEditGone);
      }
      return;
    }
    existing = ghostDraftOf(draft);
  }
  if (!context.mounted) return;
  await showGhostServerEditor(
    context,
    _EngineEditorDelegate(editing, l10n, Theme.of(context).colorScheme),
    existing,
    strings: klabautermannServerEditorStrings(l10n),
    appearanceStrings: KlabautermannServerAppearanceStrings(l10n),
    monoStyle: klabautermannMonoStyle,
    readMarkImage: pickServerMarkImage,
    // Klabautermann opens no folders: the start folder stays with the
    // server for Poltergeist, kept but not shown.
    fields: const {},
  );
}

/// Asks before deleting [server] from the account, naming it, then
/// deletes it; a refusal is told in a toast.
Future<void> confirmAndDeleteServer(
  BuildContext context,
  ServerEditing editing,
  FleetServer server,
) async {
  final l10n = AppLocalizations.of(context);
  final overlay = Overlay.of(context, rootOverlay: true);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.serverDeleteTitle(server.displayName)),
      content: Text(l10n.serverDeleteBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.serverDeleteCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.serverDeleteAction),
        ),
      ],
    ),
  );
  // A dismissed dialog reads as no: the delete reaches every device.
  if (confirmed != true) return;
  try {
    await editing.editor.delete(server.id);
  } on Object catch (error) {
    if (overlay.mounted) {
      showTopToast(overlay, message: serverEditFailureText(l10n, error));
    }
  }
}

/// The words for a failed edit: the engine's refusal, or its stopping.
String serverEditFailureText(AppLocalizations l10n, Object error) =>
    switch (error) {
      ServerEditRefused(:final failure, :final detail) =>
        l10n.serverEditRefused(failure.name, detail ?? ''),
      ServerEditEngineStopped() => l10n.serverEditEngineStopped,
      _ => l10n.serverEditRefused(CatalogWriteFailure.other.name, '$error'),
    };

/// The editor's seams over the engine. The engine plans the credential
/// and mints the vault entry's id, so the editor's second id goes unused.
final class _EngineEditorDelegate extends GhostServerEditorDelegate {
  _EngineEditorDelegate(this._editing, this._l10n, this._colors);

  final ServerEditing _editing;
  final AppLocalizations _l10n;
  final ColorScheme _colors;

  @override
  List<String> get serverGroups {
    final seen = <String>{};
    return [
      for (final server in _editing.fleet.servers)
        if (server.origin == FleetEntryOrigin.synced)
          if (server.group case final group? when seen.add(group)) group,
    ];
  }

  @override
  bool get syncConfigured => _editing.enabled;

  @override
  Color get themeSeed => _colors.primary;

  @override
  String newId() => uuidV4();

  // A key file is read by its path at connect time, which phones cannot
  // offer (03 §4.5): a picked file there is a cached copy.
  @override
  bool get canPickIdentityFile =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  @override
  Future<String?> pickIdentityFile() async {
    // Unsandboxed on macOS (03 §10.2), as for the mark image's picker.
    if (Platform.isMacOS) await FilePicker.skipEntitlementsChecks();
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return null;
    return files.first.path;
  }

  @override
  Future<bool> save(GhostServerSave save) async {
    try {
      return await _editing.editor.save(
        serverDraftOf(save.draft),
        ServerCredentialEntry(
          referenceKeyFile: save.credential.referenceKeyFile,
          password: save.credential.password,
          keyPem: save.credential.keyPem,
          keyPassphrase: save.credential.keyPassphrase,
        ),
      );
    } on Object catch (error) {
      // The editor shows `saveFailed` with this text and stays open.
      throw _SaveFailure(serverEditFailureText(_l10n, error));
    }
  }

  /// The engine tests the draft as typed, prompting as a connect does, and
  /// pins nothing. One it cannot run is reported, not thrown.
  @override
  Future<GhostTestReport> testConnection(
    GhostServerDraft draft,
    GhostCredentialDraft credential,
  ) async {
    try {
      final tested = await _editing.editor.test(
        serverDraftOf(draft),
        ServerCredentialEntry(
          referenceKeyFile: credential.privateKeyPem == null,
          password: credential.password ?? '',
          keyPem: credential.privateKeyPem ?? '',
          keyPassphrase: credential.keyPassphrase ?? '',
        ),
      );
      return GhostTestReport(
        ok: tested.ok,
        summary: tested.summary,
        notes: tested.notes,
        log: tested.log,
      );
    } on Object catch (error) {
      return GhostTestReport(
        ok: false,
        summary: _l10n.serverEditorTestFailedSummary,
        notes: [serverEditFailureText(_l10n, error)],
        log: '',
      );
    }
  }
}

/// A failed save whose text is the toast's: the editor shows it as is.
final class _SaveFailure implements Exception {
  const _SaveFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The engine's draft as the shared editor's.
GhostServerDraft ghostDraftOf(ServerDraft draft) => GhostServerDraft(
  id: draft.id,
  label: draft.label,
  host: draft.host,
  port: draft.port,
  username: draft.username,
  authMethod: switch (draft.auth) {
    ServerDraftAuth.agent => GhostAuthMethod.agent,
    ServerDraftAuth.password => GhostAuthMethod.password,
    ServerDraftAuth.privateKey => GhostAuthMethod.privateKey,
  },
  syncSecret: draft.syncSecret,
  excludeFromSync: draft.excludeFromSync,
  identityFilePath: draft.identityFilePath,
  group: draft.group,
  colorName: draft.colorName,
  customColor: draft.customColor,
  iconName: draft.iconName,
  iconEmoji: draft.iconEmoji,
  iconImage: draft.iconImage,
  loginScript: draft.loginScript,
  startDirectory: draft.startDirectory,
);

/// The shared editor's draft as the engine's.
ServerDraft serverDraftOf(GhostServerDraft draft) => ServerDraft(
  id: draft.id,
  label: draft.label,
  host: draft.host,
  port: draft.port,
  username: draft.username,
  auth: switch (draft.authMethod) {
    GhostAuthMethod.agent => ServerDraftAuth.agent,
    GhostAuthMethod.password => ServerDraftAuth.password,
    GhostAuthMethod.privateKey => ServerDraftAuth.privateKey,
  },
  syncSecret: draft.syncSecret,
  excludeFromSync: draft.excludeFromSync,
  identityFilePath: draft.identityFilePath,
  group: draft.group,
  colorName: draft.colorName,
  customColor: draft.customColor,
  iconName: draft.iconName,
  iconEmoji: draft.iconEmoji,
  iconImage: draft.iconImage,
  loginScript: draft.loginScript,
  startDirectory: draft.startDirectory,
);

/// The bytes of an image chosen for a server's mark, or null when the user
/// cancelled. Desktop pickers get the badge extensions, since the plugin's
/// image type leaves SVG out on Linux and Windows; phones keep the
/// platform's image picker (ghost_marks_picker does the same on the
/// siblings' file_picker 11).
Future<Uint8List?> pickServerMarkImage() async {
  final desktop = Platform.isLinux || Platform.isMacOS || Platform.isWindows;
  // The app is not sandboxed on macOS (03 §10.2), so it holds none of the
  // user-selected-file entitlements the plugin otherwise demands.
  if (Platform.isMacOS) await FilePicker.skipEntitlementsChecks();
  final files = await FilePicker.pickFiles(
    type: desktop ? FileType.custom : FileType.image,
    allowedExtensions: desktop
        ? [
            ...kBadgeImageExtensions,
            if (Platform.isMacOS) ...kBadgeImageAppleExtensions,
          ]
        : null,
  );
  if (files.isEmpty) return null;
  return files.first.readAsBytes();
}
