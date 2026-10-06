// Poltergeist owns localized chrome, native commands and checkout hooks.
// The shared Planchette package owns the buffer, editing surface, and search.
// See docs/PORTS.md for the extraction provenance and retained host policy.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:planchette_editor/planchette_editor.dart' as pe;

import '../l10n/app_localizations.dart';
import '../services/registered_command.dart';
import 'menus/app_menu_host.dart';
import 'menus/app_menu_commands.dart';
import 'editor_strings.dart';

/// The built-in text editor (06 §2): one document per desktop window, or
/// a full-window route on phones and tablets. The caller wires [onSaved] (the per-copy reconcile) and [onUpload] (the
/// conflict-aware save-and-upload) for a managed checkout, or leaves
/// [onUpload] null for a plain local file (the upload UI then vanishes).
class BuiltInTextEditorScreen extends StatefulWidget {
  const BuiltInTextEditorScreen({
    super.key,
    required this.file,
    this.remotePath,
    this.initialText,
    this.saveDocument,
    this.onSaved,
    this.onUpload,
    this.onCloseRequested,
    this.onQuitRequested,
    this.onNewWindowRequested,
    this.quitPending = false,
    this.onCloseGuardChanged,
    required this.showToast,
    required this.monoFontFallback,
    required this.basenameOf,
  });

  /// The local file or managed checkout being edited.
  final File file;

  /// The remote path — display title and language detection only. Null
  /// for a plain local file, where [file]'s path stands in for display.
  final String? remotePath;

  /// Test seam: preloaded text that skips the disk load entirely.
  final String? initialText;

  /// TEST-ONLY seam (06 §2.3): overrides the atomic saver wholesale,
  /// bypassing BOM/CRLF reconstruction and the expectedSha256 conflict
  /// check. Production code never passes it — the screen always saves
  /// through `saveBuiltInTextDocument` so the conflict check stays live.
  /// Returns the new baseline digest for the next save's expected value.
  final Future<String> Function(File file, String text)? saveDocument;

  /// The post-save reconcile hook (06 §2.4): fires after every save that
  /// did not upload — a local-only save, a false/throwing upload alike —
  /// never after a completed upload (that reconciles itself). Must not
  /// throw: inside the upload's `finally` an exception would replace the
  /// original upload error.
  final Future<void> Function()? onSaved;

  /// Save-and-upload for a managed checkout (06 §3.4); null = local-only.
  /// Returns false when the upload was declined (a cancelled conflict
  /// escalation), true on success; throws on failure.
  final Future<bool> Function()? onUpload;

  /// Native document windows use the same discard guard as route pops.
  /// Null retains the phone/tablet route and its normal back button.
  final Future<void> Function()? onCloseRequested;
  final Future<void> Function()? onQuitRequested;
  final Future<void> Function()? onNewWindowRequested;
  final bool quitPending;
  final void Function(Future<bool> Function()? guard)? onCloseGuardChanged;

  /// The top-toast presenter (02 §10) — Séance's `showTopToastIn` hardcode
  /// as an injected seam (06 §2.3).
  final void Function(BuildContext context, String message) showToast;

  /// The monospace family stack — Séance's `SeanceTheme.monoFallback`
  /// hardcode as an injected seam (06 §2.3).
  final List<String> monoFontFallback;

  /// The basename renderer for the two-line title (06 §2.3):
  /// `remoteBasename` for remote paths; a platform-aware basename for
  /// local callers (on Windows it must split `\` too; on POSIX `\` is a
  /// legal filename byte and is never split).
  final String Function(String path) basenameOf;

  @override
  State<BuiltInTextEditorScreen> createState() =>
      _BuiltInTextEditorScreenState();
}

class _BuiltInTextEditorScreenState extends State<BuiltInTextEditorScreen> {
  late final pe.EditorController _editor = pe.EditorController(
    displayPath: _displayPath,
    initialText: widget.initialText,
    // An explicit buffer overrides file loading.
    loadDocument: widget.initialText == null
        ? () => loadBuiltInTextDocumentDetails(widget.file)
        : null,
    saveDocument: (text, baseline) {
      final customSave = widget.saveDocument;
      if (customSave != null) return customSave(widget.file, text);
      return saveBuiltInTextDocument(
        baseline?.file ?? widget.file,
        text,
        hasUtf8Bom: baseline?.hasUtf8Bom ?? false,
        lineEnding: baseline?.lineEnding ?? LineEnding.lf,
        expectedSha256: baseline?.sha256,
      );
    },
    onSaved: widget.onSaved,
    onPublish: widget.onUpload,
  );

  String get _displayPath => widget.remotePath ?? widget.file.path;
  bool get _dirty => _editor.isDirty;
  bool get _loading => _editor.isLoading;
  bool get _saving => _editor.isSaving;
  String? get _error => _editor.error;
  bool get _searchOpen => _editor.searchOpen;

  @override
  void initState() {
    super.initState();
    _editor.setEditingLocked(widget.quitPending, notify: false);
    _editor.addListener(_changed);
    widget.onCloseGuardChanged?.call(_confirmClose);
    _editor.initialize();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(BuiltInTextEditorScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _editor.onSaved = widget.onSaved;
    _editor.onPublish = widget.onUpload;
    _editor.setEditingLocked(widget.quitPending, notify: false);
  }

  @override
  void dispose() {
    widget.onCloseGuardChanged?.call(null);
    _editor.removeListener(_changed);
    _editor.dispose();
    super.dispose();
  }

  void _openSearch() => _editor.openSearch();
  // The shared controller owns the browser's open/close state; a locked
  // document may still browse (its rows refuse to run), matching the
  // package's own contract.
  void _openTextTools() => _editor.openTextTools();
  void _closeSearch() => _editor.closeSearch();
  void _nextMatch() => _editor.nextMatch();
  void _previousMatch() => _editor.previousMatch();

  Future<bool> _confirmClose() => _editor.confirmClose(
    _confirmDiscard,
    allowWhileSaving: widget.onCloseRequested == null,
  );

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final l10n = AppLocalizations.of(context);
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l10n.editorDiscardTitle),
            content: Text(l10n.editorDiscardBody),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.editorDiscardKeep),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.editorDiscardConfirm),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _save({bool upload = false}) async {
    try {
      final result = await _editor.save(
        mode: upload ? pe.EditorSaveMode.primary : pe.EditorSaveMode.local,
      );
      if (result == null || !mounted) return;
      final l10n = AppLocalizations.of(context);
      widget.showToast(
        context,
        result.publishRequested
            ? result.published
                  ? result.hasUnsavedChanges
                        ? l10n.editorSavedUploadedDirty
                        : l10n.editorSavedUploaded
                  : l10n.editorSavedLocallyNotUploaded
            : l10n.editorSavedLocally,
      );
    } catch (error) {
      if (mounted) widget.showToast(context, error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final name = widget.basenameOf(_displayPath);
    final uploadOnSave = widget.onUpload != null;
    final editor = PopScope(
      canPop: !_dirty && (!_saving || widget.onCloseRequested == null),
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !await _confirmClose() || !context.mounted) return;
        Navigator.of(context).pop();
      },
      child: CallbackShortcuts(
        bindings: {
          if (widget.onNewWindowRequested != null) ...{
            const SingleActivator(LogicalKeyboardKey.keyN, meta: true):
                widget.onNewWindowRequested!,
            const SingleActivator(LogicalKeyboardKey.keyN, control: true):
                widget.onNewWindowRequested!,
          },
          if (widget.onCloseRequested != null) ...{
            const SingleActivator(LogicalKeyboardKey.keyW, meta: true):
                widget.onCloseRequested!,
            const SingleActivator(LogicalKeyboardKey.keyW, control: true):
                widget.onCloseRequested!,
          },
          // ⌘S/Ctrl+S is "save and upload" for a server file; hold Shift to
          // deliberately keep a save local-only.
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () =>
              _save(upload: uploadOnSave),
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
              _save(upload: uploadOnSave),
          const SingleActivator(
            LogicalKeyboardKey.keyS,
            meta: true,
            shift: true,
          ): _save,
          const SingleActivator(
            LogicalKeyboardKey.keyS,
            control: true,
            shift: true,
          ): _save,
          const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
              _openSearch,
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              _openSearch,
          const SingleActivator(LogicalKeyboardKey.keyG, meta: true):
              _nextMatch,
          const SingleActivator(LogicalKeyboardKey.keyG, control: true):
              _nextMatch,
          const SingleActivator(
            LogicalKeyboardKey.keyG,
            meta: true,
            shift: true,
          ): _previousMatch,
          const SingleActivator(
            LogicalKeyboardKey.keyG,
            control: true,
            shift: true,
          ): _previousMatch,
          const SingleActivator(LogicalKeyboardKey.f3): _nextMatch,
          const SingleActivator(LogicalKeyboardKey.f3, shift: true):
              _previousMatch,
          if (_searchOpen)
            const SingleActivator(LogicalKeyboardKey.escape): _closeSearch,
        },
        child: Scaffold(
          appBar: AppBar(
            leading: widget.onCloseRequested == null
                ? null
                : IconButton(
                    tooltip: l10n.windowCloseLabel,
                    onPressed: widget.onCloseRequested,
                    icon: const Icon(Icons.close),
                  ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  _displayPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: l10n.editorTextToolsTooltip,
                onPressed: _loading || _error != null ? null : _openTextTools,
                icon: const Icon(Icons.construction_outlined),
              ),
              IconButton(
                tooltip: l10n.editorFindTooltip,
                onPressed: _loading || _error != null ? null : _openSearch,
                icon: const Icon(Icons.search),
              ),
              IconButton(
                tooltip: l10n.editorSaveLocallyTooltip,
                onPressed: _dirty && !_saving ? _save : null,
                icon: const Icon(Icons.save_outlined),
              ),
              if (uploadOnSave)
                IconButton(
                  tooltip: l10n.editorSaveAndUploadTooltip,
                  onPressed: !_saving ? () => _save(upload: true) : null,
                  icon: const Icon(Icons.cloud_upload_outlined),
                ),
            ],
          ),
          body: pe.PlanchetteEditor(
            controller: _editor,
            strings: PoltergeistEditorStrings(l10n),
            editingLocked: widget.quitPending,
            textStyle: TextStyle(
              fontFamily: widget.monoFontFallback.first,
              fontFamilyFallback: widget.monoFontFallback,
              fontSize: 14,
              height: 1.35,
            ),
          ),
        ),
      ),
    );
    if (widget.onCloseRequested == null) return editor;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: AppMenuHost(
        commands: [
          if (widget.onNewWindowRequested != null)
            RegisteredCommand(
              id: 'window.new',
              scope: CommandScope.app,
              label: (l10n) => l10n.windowNewLabel,
              enabled: () => !widget.quitPending,
              run: (_) => widget.onNewWindowRequested!(),
              activators: (platform) => [
                _editorShortcut(platform, LogicalKeyboardKey.keyN),
              ],
              menuPlacement: const CommandMenuPlacement(
                menu: AppMenuId.file,
                order: 0,
              ),
            ),
          RegisteredCommand(
            id: 'editor.save',
            activators: (platform) => [
              _editorShortcut(platform, LogicalKeyboardKey.keyS),
            ],
            scope: CommandScope.editor,
            label: (l10n) => uploadOnSave
                ? l10n.editorSaveAndUploadTooltip
                : l10n.editorSaveLocallyTooltip,
            enabled: () =>
                !_loading && !_saving && _error == null && !widget.quitPending,
            run: (_) => _save(upload: uploadOnSave),
            menuPlacement: const CommandMenuPlacement(
              menu: AppMenuId.file,
              order: 10,
            ),
          ),
          RegisteredCommand(
            id: 'editor.close',
            activators: (platform) => [
              _editorShortcut(platform, LogicalKeyboardKey.keyW),
            ],
            scope: CommandScope.editor,
            label: (l10n) => l10n.windowCloseLabel,
            run: (_) => widget.onCloseRequested!(),
            menuPlacement: const CommandMenuPlacement(
              menu: AppMenuId.file,
              order: 20,
            ),
          ),
          RegisteredCommand(
            id: 'editor.find',
            activators: (platform) => [
              _editorShortcut(platform, LogicalKeyboardKey.keyF),
            ],
            scope: CommandScope.editor,
            label: (l10n) => l10n.editorFindTooltip,
            enabled: () => !_loading && _error == null,
            run: (_) async => _openSearch(),
            menuPlacement: const CommandMenuPlacement(
              menu: AppMenuId.edit,
              order: 10,
            ),
          ),
          ..._textCommands(context),
          if (Theme.of(context).platform != TargetPlatform.macOS)
            buildQuitCommand(requestClose: widget.onQuitRequested),
        ],
        onRun: (command) async {
          if (command.enabled()) await command.run(context);
        },
        child: editor,
      ),
    );
  }

  Iterable<RegisteredCommand> _textCommands(BuildContext context) {
    final material = MaterialLocalizations.of(context);
    final l10n = AppLocalizations.of(context);
    final actions = <(String, String, LogicalKeyboardKey, Intent)>[
      (
        'editor.undo',
        l10n.editorUndoLabel,
        LogicalKeyboardKey.keyZ,
        const UndoTextIntent(SelectionChangedCause.keyboard),
      ),
      (
        'editor.redo',
        l10n.editorRedoLabel,
        LogicalKeyboardKey.keyZ,
        const RedoTextIntent(SelectionChangedCause.keyboard),
      ),
      (
        'editor.cut',
        material.cutButtonLabel,
        LogicalKeyboardKey.keyX,
        const CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
      ),
      (
        'editor.copy',
        material.copyButtonLabel,
        LogicalKeyboardKey.keyC,
        CopySelectionTextIntent.copy,
      ),
      (
        'editor.paste',
        material.pasteButtonLabel,
        LogicalKeyboardKey.keyV,
        const PasteTextIntent(SelectionChangedCause.keyboard),
      ),
      (
        'editor.selectAll',
        material.selectAllButtonLabel,
        LogicalKeyboardKey.keyA,
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
      ),
    ];
    return [
      for (var i = 0; i < actions.length; i++)
        RegisteredCommand(
          id: actions[i].$1,
          scope: CommandScope.editor,
          label: (_) => actions[i].$2,
          enabled: () => !_loading && _error == null && !widget.quitPending,
          activators: (platform) => [
            _editorShortcut(
              platform,
              actions[i].$3,
              shift: actions[i].$1 == 'editor.redo',
            ),
          ],
          run: (_) async {
            final focusContext = FocusManager.instance.primaryFocus?.context;
            if (focusContext != null) {
              Actions.maybeInvoke(focusContext, actions[i].$4);
            }
          },
          menuPlacement: CommandMenuPlacement(
            menu: AppMenuId.edit,
            order: 20 + i,
          ),
        ),
    ];
  }

  static SingleActivator _editorShortcut(
    TargetPlatform platform,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) => SingleActivator(
    key,
    meta: platform == TargetPlatform.macOS,
    control: platform != TargetPlatform.macOS,
    shift: shift,
  );
}
