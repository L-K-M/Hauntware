import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:planchette_editor/planchette_editor.dart';
import 'package:seance_core/seance_core.dart';

import '../services/editor_document.dart';
import '../services/remote_files_controller.dart';
import '../theme.dart';
import 'editor_syntax.dart' show seanceEditorSyntaxTheme;
import 'top_toast.dart';

export '../services/editor_document.dart';
export 'package:planchette_core/planchette_core.dart'
    show lineStartOffsets, utf8EncodedLength;

class BuiltInTextEditorScreen extends StatefulWidget {
  final File file;
  final String remotePath;
  final String? initialText;

  /// When set, the editor watches this controller's drift flag for
  /// [remotePath] and offers to reload the file once the server copy no
  /// longer matches what the local checkout was taken from.
  final RemoteFilesController? remoteFiles;
  final Future<void> Function(File file, String text)? saveDocument;
  final Future<void> Function()? onSaved;
  final Future<bool> Function()? onUpload;

  /// Written with the buffer's dirty flag on every change — a hosting tab
  /// strip draws its modified marker from it.
  final ValueNotifier<bool>? dirtyNotifier;

  /// False while another tab is front-most, so autofocus and
  /// focus-on-activation never fight the tab that is actually showing.
  final bool isActive;

  const BuiltInTextEditorScreen({
    super.key,
    required this.file,
    required this.remotePath,
    this.initialText,
    this.remoteFiles,
    this.saveDocument,
    this.onSaved,
    this.onUpload,
    this.dirtyNotifier,
    this.isActive = true,
  });

  @override
  State<BuiltInTextEditorScreen> createState() =>
      BuiltInTextEditorScreenState();
}

/// Séance owns the session, remote drift, tab chrome, and notifications. The
/// buffer and editing surface are shared with Planchette and Poltergeist.
class BuiltInTextEditorScreenState extends State<BuiltInTextEditorScreen>
    with WidgetsBindingObserver {
  late final EditorController _editor;
  bool _reloading = false;
  bool _missingBannerDismissed = false;

  bool get isDirty => _editor.isDirty;
  bool? get _remoteChanged =>
      widget.remoteFiles?.remoteChangedFor(widget.remotePath);
  bool get _remoteMissing {
    final files = widget.remoteFiles;
    return files != null &&
        files.latestRemoteSnapshots.containsKey(widget.remotePath) &&
        files.latestRemoteSnapshots[widget.remotePath] == null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _editor = EditorController(
      displayPath: widget.remotePath,
      initialText: widget.initialText,
      loadDocument: () => loadTextDocument(
        widget.file,
        normalization: TextNormalization.preserve,
      ),
      saveDocument: (text, baseline) async {
        final customSave = widget.saveDocument;
        if (customSave != null) {
          await customSave(widget.file, text);
          return baseline?.sha256 ?? '';
        }
        return saveBuiltInTextDocument(
          baseline?.file ?? widget.file,
          text,
          hasUtf8Bom: baseline?.hasUtf8Bom ?? false,
          lineEnding: baseline?.lineEnding == LineEnding.crlf ? '\r\n' : '\n',
          expectedSha256: baseline?.sha256,
        );
      },
      onSaved: widget.onSaved,
      onPublish: widget.onUpload,
    );
    _editor.addListener(_changed);
    unawaited(_editor.initialize());
    // Initial text is installed before listeners attach. Prime the tab marker
    // after its host finishes building, without invalidating an ancestor.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.dirtyNotifier?.value = _editor.isDirty;
    });
    _checkRemoteDrift();
  }

  void _changed() {
    if (!mounted) return;
    widget.dirtyNotifier?.value = _editor.isDirty;
    setState(() {});
  }

  void _checkRemoteDrift() {
    unawaited(
      widget.remoteFiles?.checkRemoteSnapshot(widget.remotePath) ??
          Future<void>.value(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkRemoteDrift();
  }

  @override
  void didUpdateWidget(BuiltInTextEditorScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _editor.onSaved = widget.onSaved;
    _editor.onPublish = widget.onUpload;
    if (!identical(widget.dirtyNotifier, oldWidget.dirtyNotifier)) {
      widget.dirtyNotifier?.value = _editor.isDirty;
    }
    if (!identical(widget.remoteFiles, oldWidget.remoteFiles)) {
      _checkRemoteDrift();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _editor.removeListener(_changed);
    _editor.dispose();
    super.dispose();
  }

  /// The tab host keeps this entry point so closing a tab uses the same shared
  /// save/dirty guard as the other applications.
  Future<bool> confirmDiscard() => _editor.confirmClose(() async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard unsaved changes?'),
            content: const Text(
              'Changes not saved to the managed local copy will be lost.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep editing'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Discard'),
              ),
            ],
          ),
        ) ??
        false;
  });

  Future<void> _save({bool upload = false}) async {
    if (_reloading) return;
    try {
      final result = await _editor.save(
        mode: upload ? EditorSaveMode.primary : EditorSaveMode.local,
      );
      if (!mounted || result == null) return;
      showTopToastIn(
        context,
        message: result.publishRequested
            ? result.published
                  ? result.hasUnsavedChanges
                        ? 'Uploaded the saved version; newer edits remain unsaved.'
                        : 'Saved and uploaded.'
                  : 'Saved locally; not uploaded.'
            : 'Saved locally.',
      );
    } catch (error) {
      if (mounted) showTopToastIn(context, message: error.toString());
    }
  }

  Future<void> _reloadFromServer() async {
    final files = widget.remoteFiles;
    if (files == null || _reloading || _editor.isBusy) return;
    final revision = _editor.text.text;
    final localEdits =
        _editor.isDirty ||
        (files.localCopies[widget.remotePath]?.dirty ?? false);
    if (localEdits) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard local changes?'),
          content: const Text(
            'Reloading replaces the local copy with the server version. '
            'Unsaved edits will be lost.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Discard and reload'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    // A native action or another task may have edited or saved while the
    // confirmation was pending. Consent covers only the snapshot shown.
    if (_editor.isBusy ||
        _editor.text.text != revision ||
        !identical(files, widget.remoteFiles)) {
      return;
    }
    setState(() => _reloading = true);
    _editor.editingLocked = true;
    try {
      await files.refreshLocalCopy(
        widget.remotePath,
        maximumBytes: builtInEditorMaximumBytes,
      );
      if (!mounted || !identical(files, widget.remoteFiles)) return;
      // Reload replaces the confirmed snapshot. Keep the surface locked until
      // the new load finishes, even though the controller permits loading.
      _editor.editingLocked = false;
      await _editor.reload();
    } catch (error) {
      if (mounted) showTopToastIn(context, message: error.toString());
    } finally {
      if (mounted) {
        _editor.editingLocked = false;
        setState(() => _reloading = false);
        widget.dirtyNotifier?.value = _editor.isDirty;
      }
    }
  }

  Widget _remoteBanner() => ListenableBuilder(
    listenable: widget.remoteFiles!,
    builder: (context, _) {
      if (!_remoteMissing) _missingBannerDismissed = false;
      if (_remoteChanged != true || _missingBannerDismissed) {
        return const SizedBox.shrink();
      }
      return MaterialBanner(
        leading: const Icon(Icons.sync_problem_outlined),
        content: Text(
          _remoteMissing
              ? 'This file no longer exists on the server.'
              : 'This file changed on the server.',
        ),
        actions: [
          if (_remoteMissing)
            TextButton(
              onPressed: () => setState(() => _missingBannerDismissed = true),
              child: const Text('Keep local copy'),
            )
          else
            TextButton(
              onPressed: _reloading || _editor.isBusy
                  ? null
                  : _reloadFromServer,
              child: const Text('Reload'),
            ),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () =>
          _save(upload: widget.onUpload != null),
      const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
          _save(upload: widget.onUpload != null),
      const SingleActivator(LogicalKeyboardKey.keyS, meta: true, shift: true):
          _save,
      const SingleActivator(
        LogicalKeyboardKey.keyS,
        control: true,
        shift: true,
      ): _save,
    },
    child: Scaffold(
      body: Column(
        children: [
          _header(context),
          Expanded(
            child: PlanchetteEditor(
              controller: _editor,
              strings: const EditorStrings(),
              isActive: widget.isActive,
              editingLocked: _reloading,
              syntaxTheme: seanceEditorSyntaxTheme(
                Theme.of(context).brightness,
              ),
              textStyle: TextStyle(
                fontFamily: SeanceTheme.monoFallback.first,
                fontFamilyFallback: SeanceTheme.monoFallback,
                fontSize: 14,
                height: 1.35,
              ),
              banner: widget.remoteFiles == null ? null : _remoteBanner(),
              statusBuilder: (context, controller) => widget.remoteFiles == null
                  ? _statusBar(context)
                  : ListenableBuilder(
                      listenable: widget.remoteFiles!,
                      builder: (context, _) => _statusBar(context),
                    ),
            ),
          ),
        ],
      ),
    ),
  );

  /// The in-pane title row the route's AppBar used to provide: file name,
  /// remote path, and the find/save actions. The tab strip above carries
  /// the close affordance.
  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final uploadOnSave = widget.onUpload != null;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: const EdgeInsets.only(left: 12, right: 4),
      child: Row(
        children: [
          Icon(Icons.edit_document, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    remoteBasename(widget.remotePath),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  Text(
                    widget.remotePath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'Find',
            visualDensity: VisualDensity.compact,
            onPressed: _editor.isLoading || _editor.error != null
                ? null
                : _editor.openSearch,
            icon: const Icon(Icons.search),
          ),
          IconButton(
            tooltip: 'Save locally',
            visualDensity: VisualDensity.compact,
            onPressed: _editor.isDirty && !_editor.isSaving ? _save : null,
            icon: const Icon(Icons.save_outlined),
          ),
          if (uploadOnSave)
            IconButton(
              tooltip: 'Save and upload',
              visualDensity: VisualDensity.compact,
              onPressed: !_editor.isSaving ? () => _save(upload: true) : null,
              icon: const Icon(Icons.cloud_upload_outlined),
            ),
        ],
      ),
    );
  }

  Widget _statusBar(BuildContext context) {
    final theme = Theme.of(context);
    final (line, col) = _editor.caretLineColumn;
    final copy = widget.remoteFiles?.localCopies[widget.remotePath];
    final status = [
      if (_editor.isSaving) 'Saving…',
      if (_remoteMissing)
        'Deleted on server'
      else if (_remoteChanged == true)
        'Changed on server',
      if (_editor.isDirty)
        'Unsaved edits'
      else if (copy?.dirty ?? false)
        'Local changes'
      else if (copy != null)
        'In sync',
      _editor.document?.lineEnding == LineEnding.crlf ? 'CRLF' : 'LF',
      (_editor.document?.hasUtf8Bom ?? false) ? 'UTF-8 BOM' : 'UTF-8',
      if (_editor.text.language case final language?) language.id,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Ln $line, Col $col · ${_editor.lineStarts.length} lines · ${_editor.byteCount} bytes',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            ),
          ),
          Flexible(
            child: Text(
              status.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }
}
