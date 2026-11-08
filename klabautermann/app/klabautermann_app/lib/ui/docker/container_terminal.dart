import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show ghostIsDesktopPlatform, showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:seance_terminal/seance_terminal.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../controllers/container_terminals.dart';
import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import '../actions/action_entry.dart';
import 'containers_view.dart' show containerNameOf;

/// Opens a shell in [container] on a page of its own, full screen with
/// the keyboard bar, as a phone pushes it (03 §10.5). The desktop
/// inspector shows a [ContainerShellPane] in its own region instead.
void openContainerShellPage(
  BuildContext context, {
  required MonitoringController monitoring,
  required String serverId,
  required ContainerSummary container,
}) => unawaited(
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        appBar: AppBar(
          title: Text(
            AppLocalizations.of(
              context,
            ).dockerShellTitle(containerNameOf(container)),
          ),
        ),
        body: SafeArea(
          // Gated like the entry that pushed it, as the desktop inspector
          // gates its pane: a switch to read-only or observe-only takes
          // the pane away, which closes its shell.
          child: ActionEntry(
            serverId: serverId,
            point: ActionEntryPoint.containerShell,
            child: ContainerShellPane(
              monitoring: monitoring,
              serverId: serverId,
              container: container,
            ),
          ),
        ),
      ),
    ),
  ),
);

/// A shell in [container] on [serverId] (03 §7.13, CTX-07): first the
/// shell and user to run it with, then Séance's terminal over the
/// engine's exec stream. Pastes pass [TerminalPastePolicy], which asks
/// before a multi-line paste the danger linter flags. The shell closes
/// when the pane goes; what it printed stays on screen after it ended,
/// with why it ended and a way to open it again.
class ContainerShellPane extends StatefulWidget {
  const ContainerShellPane({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.container,
  });

  final MonitoringController monitoring;
  final String serverId;
  final ContainerSummary container;

  @override
  State<ContainerShellPane> createState() => _ContainerShellPaneState();
}

/// The shells the picker offers; null lets the engine choose
/// (`/bin/bash`, then `/bin/sh`). Typing another path is allowed.
const List<String?> _shellChoices = [null, '/bin/bash', '/bin/sh', '/bin/ash'];

class _ContainerShellPaneState extends State<ContainerShellPane> {
  final _shellField = TextEditingController();
  final _userField = TextEditingController();
  _ShellRun? _run;

  @override
  void dispose() {
    _run?.dispose();
    _shellField.dispose();
    _userField.dispose();
    super.dispose();
  }

  void _start() {
    final previous = _run;
    final run = _ShellRun(
      widget.monitoring.terminals.open(
        serverId: widget.serverId,
        containerId: widget.container.id,
        shell: _shellField.text,
        user: _userField.text,
        columns: 80,
        rows: 24,
      ),
    );
    setState(() => _run = run);
    previous?.dispose();
  }

  void _back() {
    final previous = _run;
    setState(() => _run = null);
    previous?.dispose();
  }

  @override
  Widget build(BuildContext context) => switch (_run) {
    null => _form(context),
    final run => _ShellView(
      key: ObjectKey(run),
      run: run,
      onReopen: _start,
      onBack: _back,
    ),
  };

  Widget _form(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        DropdownMenu<String?>(
          controller: _shellField,
          expandedInsets: EdgeInsets.zero,
          requestFocusOnTap: true,
          label: Text(l10n.dockerShellShellLabel),
          hintText: l10n.dockerShellShellAuto,
          dropdownMenuEntries: [
            for (final choice in _shellChoices)
              DropdownMenuEntry(
                value: choice,
                label: choice ?? '',
                labelWidget: Text(choice ?? l10n.dockerShellShellAuto),
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _userField,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: l10n.dockerShellUserLabel,
            hintText: l10n.dockerShellUserHint,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => _start(),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.icon(
            onPressed: _start,
            icon: const Icon(Icons.terminal),
            label: Text(l10n.dockerShellStart),
          ),
        ),
      ],
    );
  }
}

/// [TerminalByteTransport] over a [ContainerShell].
final class _ShellTransport implements TerminalByteTransport {
  _ShellTransport(this._shell);

  final ContainerShell _shell;

  @override
  Stream<Uint8List> get output => _shell.output;

  @override
  void write(Uint8List bytes) => _shell.write(bytes);

  @override
  void resize({required int columns, required int rows}) =>
      _shell.resize(columns: columns, rows: rows);

  @override
  Future<void> close() async => _shell.close();
}

/// One opened shell and the terminal engine and session over it, which
/// this run owns.
final class _ShellRun {
  _ShellRun(this.shell) : engine = XtermTerminalEngine() {
    session = TerminalByteSession(
      engine: engine,
      transport: _ShellTransport(shell),
    );
  }

  final ContainerShell shell;
  final XtermTerminalEngine engine;
  late final TerminalByteSession session;

  /// Closes the shell at once, then tears the session down and disposes
  /// the engine; the session's own close reaches the shell only after
  /// its streams are cancelled.
  void dispose() {
    shell.close();
    unawaited(session.close());
  }
}

/// The only schemes a link printed by a container may invoke: anything
/// else stays inert, so the shell can never hand the OS a file path or
/// another app's scheme.
const _webSchemes = {'http', 'https'};

class _ShellView extends StatefulWidget {
  const _ShellView({
    super.key,
    required this.run,
    required this.onReopen,
    required this.onBack,
  });

  final _ShellRun run;
  final VoidCallback onReopen;
  final VoidCallback onBack;

  @override
  State<_ShellView> createState() => _ShellViewState();
}

class _ShellViewState extends State<_ShellView> {
  final _controller = TerminalController();
  final _focus = FocusNode();
  final _selectionToolbar = ContextMenuController();
  final _viewKey = GlobalKey<TerminalViewState>();

  XtermTerminalEngine get _engine => widget.run.engine;

  @override
  void initState() {
    super.initState();
    widget.run.shell.state.addListener(_onState);
    _controller.addListener(_hideSelectionToolbarWithoutSelection);
    _focus.addListener(_hideSelectionToolbarOnBlur);
  }

  @override
  void dispose() {
    widget.run.shell.state.removeListener(_onState);
    _controller.removeListener(_hideSelectionToolbarWithoutSelection);
    _focus.removeListener(_hideSelectionToolbarOnBlur);
    _selectionToolbar.remove();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onState() {
    if (mounted) setState(() {});
  }

  bool get _apple => switch (Theme.of(context).platform) {
    TargetPlatform.macOS || TargetPlatform.iOS => true,
    _ => false,
  };

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    // ⌘ on Apple platforms; elsewhere Ctrl+Shift, which leaves plain
    // Ctrl+C and Ctrl+V for the shell.
    final clip = _apple
        ? keys.isMetaPressed
        : keys.isControlPressed && keys.isShiftPressed;
    if (!clip) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.keyV) {
      // As the toolbar and the menu offer no paste once the shell ended.
      if (widget.run.shell.state.value is ContainerShellEnded) {
        return KeyEventResult.handled;
      }
      unawaited(_paste());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyC) {
      _copy();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _copy() {
    final selection = _controller.selection;
    if (selection == null) return;
    final text = _engine.terminal.buffer.getText(selection);
    _controller.clearSelection();
    unawaited(Clipboard.setData(ClipboardData(text: text)));
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || !mounted) return;
    await TerminalPastePolicy(
      inspect: (text) async => [
        for (final finding in DangerLinter.scan(text))
          TerminalPasteFinding(
            severity: switch (finding.severity) {
              DangerSeverity.critical => TerminalPasteSeverity.critical,
              DangerSeverity.warning => TerminalPasteSeverity.warning,
            },
            line: finding.line,
            explanation: finding.explanation,
          ),
      ],
      confirm: _confirmPaste,
    ).paste(_engine, text);
    if (mounted) _focus.requestFocus();
  }

  Future<TerminalPasteChoice> _confirmPaste(TerminalPasteReview review) async {
    if (!mounted) return TerminalPasteChoice.cancel;
    final l10n = AppLocalizations.of(context);
    return showTerminalPasteReview(
      context,
      review,
      strings: TerminalPasteReviewStrings(
        title: l10n.dockerShellPasteTitle,
        findings: l10n.dockerShellPasteFindings,
        unchecked: l10n.dockerShellPasteUnchecked,
        finding: l10n.dockerShellPasteFinding,
        pasteAll: l10n.dockerShellPasteAll,
        firstLineOnly: l10n.dockerShellPasteFirstLine,
        cancel: l10n.dockerShellPasteCancel,
      ),
    );
  }

  /// The whole buffer, scrollback included, as Select all covers on the
  /// platforms' own text.
  void _selectAll() {
    final terminal = _engine.terminal;
    final buffer = terminal.buffer;
    _controller.setSelection(
      buffer.createAnchor(0, 0),
      buffer.createAnchor(terminal.viewWidth, buffer.height - 1),
    );
  }

  /// Drops the lines scrolled off the top; the visible screen stays.
  void _clearScrollback() {
    final terminal = _engine.terminal;
    terminal.eraseScrollbackOnly();
    terminal.notifyListeners();
  }

  /// A link printed to the shell opens in the browser — and only the
  /// web schemes get that far, so the terminal can never invoke a file
  /// path or another app's scheme. A refused launch says so the way the
  /// app's other link failures do.
  Future<void> _openLink(Uri uri) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final notOpened = AppLocalizations.of(context).dockerLinksNotOpened;
    var opened = false;
    if (_webSchemes.contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty) {
      try {
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } on PlatformException {
        opened = false;
      } on ArgumentError {
        opened = false;
      }
    }
    if (!opened && overlay.mounted) showTopToast(overlay, message: notOpened);
  }

  /// The platform's selection toolbar over a touch selection, as
  /// Android and iOS text gets. Copy ends the selection, and Paste goes
  /// through the shell's own check so its paste policy still holds.
  void _showSelectionToolbar() {
    final anchors = _viewKey.currentState?.selectionToolbarAnchors;
    if (anchors == null) return;
    _selectionToolbar.show(
      context: context,
      contextMenuBuilder: (context) => AdaptiveTextSelectionToolbar.buttonItems(
        anchors: anchors,
        buttonItems: [
          ContextMenuButtonItem(
            type: ContextMenuButtonType.copy,
            onPressed: _copy,
          ),
          ContextMenuButtonItem(
            type: ContextMenuButtonType.paste,
            onPressed: widget.run.shell.state.value is ContainerShellEnded
                ? null
                : () {
                    _selectionToolbar.remove();
                    unawaited(_paste());
                  },
          ),
          ContextMenuButtonItem(
            type: ContextMenuButtonType.selectAll,
            onPressed: () {
              _selectAll();
              _showSelectionToolbar();
            },
          ),
        ],
      ),
    );
  }

  /// A tap that clears the selection takes its toolbar with it.
  void _hideSelectionToolbarWithoutSelection() {
    if (_controller.selection != null) return;
    _selectionToolbar.remove();
  }

  void _hideSelectionToolbarOnBlur() {
    if (_focus.hasFocus) return;
    _selectionToolbar.remove();
  }

  Future<void> _contextMenu(Offset position) async {
    final l10n = AppLocalizations.of(context);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<_ShellMenu>(
      context: context,
      position: RelativeRect.fromRect(
        position & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: _ShellMenu.copy,
          enabled: _controller.selection != null,
          child: Text(l10n.dockerShellCopy),
        ),
        PopupMenuItem(
          value: _ShellMenu.paste,
          enabled: widget.run.shell.state.value is! ContainerShellEnded,
          child: Text(l10n.dockerShellPaste),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _ShellMenu.selectAll,
          child: Text(l10n.dockerShellSelectAll),
        ),
        PopupMenuItem(
          value: _ShellMenu.clearScrollback,
          child: Text(l10n.dockerShellClearScrollback),
        ),
      ],
    );
    switch (action) {
      case _ShellMenu.copy:
        _copy();
      case _ShellMenu.paste:
        await _paste();
      case _ShellMenu.selectAll:
        // The menu's await can outlive the view; the controller dies
        // with it.
        if (mounted) _selectAll();
      case _ShellMenu.clearScrollback:
        if (mounted) _clearScrollback();
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final state = widget.run.shell.state.value;
    final ended = state is ContainerShellEnded;
    final appearance = TerminalAppearance.of(
      fontSize: kDefaultTerminalFontSize,
      fontFamily: '',
      ligatures: TerminalLigatures.off,
      // Klabautermann's palettes carry no terminal block, so the
      // terminal takes Séance's built-in palette for the app's
      // brightness.
      palette: TerminalPalette.followApp,
      themeColors: null,
      brightness: theme.brightness,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 4, 4),
          child: Row(
            children: [
              Expanded(child: _ShellStatus(state: state)),
              if (!ended) ...[
                IconButton(
                  tooltip: l10n.dockerShellPaste,
                  icon: const Icon(Icons.content_paste),
                  onPressed: () => unawaited(_paste()),
                ),
                IconButton(
                  tooltip: l10n.dockerShellClose,
                  icon: const Icon(Icons.stop_circle_outlined),
                  onPressed: widget.run.shell.close,
                ),
              ] else ...[
                TextButton(
                  onPressed: widget.onBack,
                  child: Text(l10n.dockerShellChange),
                ),
                FilledButton.tonal(
                  onPressed: widget.onReopen,
                  child: Text(l10n.dockerShellReopen),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: ColoredBox(
            color: appearance.theme.background,
            child: TerminalView(
              _engine.terminal,
              key: _viewKey,
              controller: _controller,
              focusNode: _focus,
              autofocus: true,
              readOnly: ended,
              onKeyEvent: _onKey,
              onLinkTap: _openLink,
              onTouchSelectionEnd: _showSelectionToolbar,
              // No default shortcuts: xterm's would paste around the
              // paste policy and take Ctrl+V and Ctrl+A from the shell.
              shortcuts: const <ShortcutActivator, Intent>{},
              onSecondaryTapDown: (details, _) =>
                  unawaited(_contextMenu(details.globalPosition)),
              textStyle: appearance.style,
              theme: appearance.theme,
              keyboardAppearance: appearance.brightness,
              padding: const EdgeInsets.all(6),
            ),
          ),
        ),
        if (!ghostIsDesktopPlatform(theme.platform) && !ended)
          TerminalKeyboardBar(engine: _engine, strings: _keyboardStrings(l10n)),
      ],
    );
  }

  /// The keyboard bar's key labels and tooltips, in the app's words
  /// rather than the package's built-in English ones.
  TerminalKeyboardBarStrings _keyboardStrings(AppLocalizations l10n) =>
      TerminalKeyboardBarStrings(
        escape: l10n.dockerShellKeyEscape,
        tab: l10n.dockerShellKeyTab,
        controlModifier: l10n.dockerShellKeyControlModifier,
        controlC: l10n.dockerShellKeyControlC,
        leftArrow: l10n.dockerShellKeyLeftArrow,
        upArrow: l10n.dockerShellKeyUpArrow,
        downArrow: l10n.dockerShellKeyDownArrow,
        rightArrow: l10n.dockerShellKeyRightArrow,
        home: l10n.dockerShellKeyHome,
        end: l10n.dockerShellKeyEnd,
        pageUp: l10n.dockerShellKeyPageUp,
        pageDown: l10n.dockerShellKeyPageDown,
        pipe: l10n.dockerShellKeyPipe,
        slash: l10n.dockerShellKeySlash,
        hyphen: l10n.dockerShellKeyHyphen,
        tilde: l10n.dockerShellKeyTilde,
        hideKeyboard: l10n.dockerShellKeyHideKeyboard,
      );
}

enum _ShellMenu { copy, paste, selectAll, clearScrollback }

/// What the shell is doing, or why it ended.
class _ShellStatus extends StatelessWidget {
  const _ShellStatus({required this.state});

  final ContainerShellState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    // The first line says what the shell is doing; under an ended one,
    // its exit code and the daemon's detail, muted.
    final (String text, List<String> notes) = switch (state) {
      ContainerShellOpening() => (l10n.dockerShellOpening, const <String>[]),
      ContainerShellRunning(:final command) => (
        l10n.dockerShellRunning(command.join(' ')),
        const <String>[],
      ),
      ContainerShellEnded(:final reason, :final exitCode, :final detail) => (
        l10n.dockerShellEnded(reason?.name ?? 'engineStopped'),
        [
          if (exitCode != null) l10n.dockerShellExitCode(exitCode),
          if (detail != null && detail.isNotEmpty) detail,
        ],
      ),
    };
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
          for (final note in notes)
            Text(
              note,
              style: muted,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}
