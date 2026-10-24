import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghost_ui/ghost_ui.dart' show ghostIsDesktopPlatform;
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:seance_terminal/seance_terminal.dart';

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

  XtermTerminalEngine get _engine => widget.run.engine;

  @override
  void initState() {
    super.initState();
    widget.run.shell.state.addListener(_onState);
  }

  @override
  void dispose() {
    widget.run.shell.state.removeListener(_onState);
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
    final choice = await showDialog<TerminalPasteChoice>(
      context: context,
      builder: (context) => _PasteReviewDialog(review: review),
    );
    return choice ?? TerminalPasteChoice.cancel;
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
      ],
    );
    switch (action) {
      case _ShellMenu.copy:
        _copy();
      case _ShellMenu.paste:
        await _paste();
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
              controller: _controller,
              focusNode: _focus,
              autofocus: true,
              readOnly: ended,
              onKeyEvent: _onKey,
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
          TerminalKeyboardBar(engine: _engine),
      ],
    );
  }
}

enum _ShellMenu { copy, paste }

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

/// Asks about a multi-line paste the linter flagged, or could not check.
class _PasteReviewDialog extends StatelessWidget {
  const _PasteReviewDialog({required this.review});

  final TerminalPasteReview review;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final findings = review.findings;
    return AlertDialog(
      title: Text(l10n.dockerShellPasteTitle(review.lineCount)),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              findings == null
                  ? l10n.dockerShellPasteUnchecked
                  : l10n.dockerShellPasteFindings,
            ),
            for (final finding in findings ?? const <TerminalPasteFinding>[])
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  l10n.dockerShellPasteFinding(
                    finding.line,
                    finding.explanation,
                  ),
                  style: TextStyle(
                    color: finding.severity == TerminalPasteSeverity.critical
                        ? theme.colorScheme.error
                        : null,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, TerminalPasteChoice.cancel),
          child: Text(l10n.dockerShellPasteCancel),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, TerminalPasteChoice.firstLineOnly),
          child: Text(l10n.dockerShellPasteFirstLine),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, TerminalPasteChoice.pasteAll),
          child: Text(l10n.dockerShellPasteAll),
        ),
      ],
    );
  }
}
