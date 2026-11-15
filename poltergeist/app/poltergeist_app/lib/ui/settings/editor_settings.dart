// The Settings → Editing surface's bounded mount (06 §8): the
// `Open With ▸ Configure Editors…` deep-link destination when there is no
// Settings window — the Double-click action row, the two registry-backed
// sections (Default editor, External editors) and Preview & downloads in
// a dialog, mounted exactly like the Backup section's bounded dialog.
import 'package:flutter/material.dart';
import 'package:ghost_editors/ghost_editors.dart'
    show GhostEditorsSettingsSection, GhostEditorsStrings;

import '../../l10n/app_localizations.dart';
import '../../services/application_error_reporter.dart';
import '../../services/settings_models.dart';
import '../../services/external_file_opener.dart';
import '../top_toast.dart';
import 'double_click_action_settings.dart';
import 'preview_settings.dart';

/// The `open-with-external` Configure Editors… destination (06 §4.1's
/// menu tail): the Editing sections that already have a backing store.
/// [doubleClickAction] mounts the Opening files row and [previewSettings]
/// the §8 "Preview & downloads" rows when wired — null leaves a section
/// absent rather than rendered-dead.
Future<void> showEditorsSettingsDialog(
  BuildContext context, {
  required EditorRegistryModel controller,
  ExternalFileOpener opener = const ExternalFileOpener(),
  DoubleClickActionModel? doubleClickAction,
  PreviewDownloadsSettings? previewSettings,
}) => showDialog<void>(
  context: context,
  builder: (dialogContext) {
    final l10n = AppLocalizations.of(dialogContext);
    return AlertDialog(
      key: const ValueKey('editors.settings.dialog'),
      title: Text(l10n.settingsTitle),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (doubleClickAction != null) ...[
                DoubleClickActionSection(model: doubleClickAction),
                const SizedBox(height: 20),
              ],
              EditorsSettingsSection(controller: controller, opener: opener),
              if (previewSettings != null) ...[
                const SizedBox(height: 20),
                PreviewDownloadsSection(settings: previewSettings),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('editors.settings.close'),
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l10n.editorSettingsClose),
        ),
      ],
    );
  },
);

/// The §8 registry-backed sections, shared with Séance through
/// ghost_editors: the Default-editor dropdown, the External-editors list
/// with its row actions and the per-extension defaults. Every mutation
/// goes through the controller's persist-first discipline (06 §8's
/// immediate-persist model), so a failed settings write restores the
/// pre-mutation registry and the surfaced error.
final class EditorsSettingsSection extends StatelessWidget {
  const EditorsSettingsSection({
    super.key,
    required this.controller,
    this.opener = const ExternalFileOpener(),
    this.picker,
  });

  final EditorRegistryModel controller;
  final ExternalFileOpener opener;

  /// `Add Editor…`'s picker, when it is not [opener]'s: the Settings
  /// window has no plugins or runner channels of its own, so it asks the
  /// app to show the platform's picker.
  final EditorPicker? picker;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return GhostEditorsSettingsSection(
      model: controller,
      picker: picker ?? opener.pickEditor,
      strings: GhostEditorsStrings(
        defaultLabel: l10n.editorDefaultLabel,
        builtInOption: l10n.editorBuiltInOption,
        systemDefaultOption: l10n.editorSystemDefaultOption,
        otherPlatformName: l10n.editorNameOtherPlatform,
        listLabel: l10n.editorListLabel,
        emptyState: l10n.editorEmptyState,
        desktopOnly: l10n.editorDesktopOnly,
        addLabel: l10n.editorAddLabel,
        pickDialogTitle: l10n.editorPickDialogTitle,
        addTitle: l10n.editorAddTitle,
        editTitle: l10n.editorEditTitle,
        editLabel: l10n.editorEditLabel,
        removeLabel: l10n.editorRemoveLabel,
        removeTitle: l10n.editorRemoveTitle,
        removeBody: l10n.editorRemoveBody,
        removeDefaultBody: l10n.editorRemoveDefaultBody,
        nameFieldLabel: l10n.editorNameFieldLabel,
        extensionsFieldLabel: l10n.editorExtensionsFieldLabel,
        extensionsFieldHint: l10n.editorExtensionsFieldHint,
        extensionsFieldHelper: l10n.editorExtensionsFieldHelper,
        cancel: l10n.editorDialogCancel,
        save: l10n.editorDialogSave,
        bindingsLabel: l10n.editorBindingsLabel,
        bindingsEmpty: l10n.editorBindingsEmpty,
        bindingAddLabel: l10n.editorBindingAddLabel,
        bindingAddTitle: l10n.editorBindingAddTitle,
        bindingExtensionLabel: l10n.editorBindingExtensionLabel,
        bindingExtensionHint: l10n.editorBindingExtensionHint,
        bindingEditorLabel: l10n.editorBindingEditorLabel,
        bindingExtensionInvalid: l10n.editorBindingExtensionInvalid,
        bindingEditorRejects: l10n.editorBindingEditorRejects,
      ),
      onError: (context, error, stackTrace) {
        ApplicationErrorReporter().report(error, stackTrace);
        showTopToastIn(context, message: error.toString());
      },
    );
  }
}
