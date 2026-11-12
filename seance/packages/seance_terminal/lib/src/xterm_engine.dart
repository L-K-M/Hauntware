import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:seance_core/seance_core.dart';
import 'package:xterm/xterm.dart';

const _escape = 0x1b;
const _controlSequenceIntroducer = 0x5b;
const _singleShiftThree = 0x4f;

enum TerminalCursorKey {
  arrowUp(0x41),
  arrowDown(0x42),
  arrowRight(0x43),
  arrowLeft(0x44),
  home(0x48),
  end(0x46);

  final int finalByte;
  const TerminalCursorKey(this.finalByte);
}

enum TerminalPromptPhase { unknown, rendering, acceptingInput, executing, done }

enum TerminalStageResult {
  staged,
  shellIntegrationRequired,
  promptNotReady,
  pendingInput,
  invalidPath,
}

@immutable
class ShellIntegrationState {
  final RemoteShellKind? shell;
  final TerminalPromptPhase phase;
  final bool inputSincePrompt;
  final int? lastExitCode;

  const ShellIntegrationState({
    this.shell,
    this.phase = TerminalPromptPhase.unknown,
    this.inputSincePrompt = true,
    this.lastExitCode,
  });

  ShellIntegrationState copyWith({
    RemoteShellKind? shell,
    TerminalPromptPhase? phase,
    bool? inputSincePrompt,
    int? lastExitCode,
    bool clearExitCode = false,
  }) => ShellIntegrationState(
    shell: shell ?? this.shell,
    phase: phase ?? this.phase,
    inputSincePrompt: inputSincePrompt ?? this.inputSincePrompt,
    lastExitCode: clearExitCode ? null : lastExitCode ?? this.lastExitCode,
  );
}

/// A [TerminalEngine] backed by xterm.dart's [Terminal]. This is the concrete
/// v1 terminal; a future libghostty engine drops in behind the same interface
/// (see the proposal's M10). Bytes from SSH are written to the terminal;
/// keystrokes it emits are forwarded to SSH as bytes.
class XtermTerminalEngine implements TerminalEngine {
  final Terminal terminal;
  final StreamController<Uint8List> _input =
      StreamController<Uint8List>.broadcast();
  late final ByteConversionSink _terminalDecoder;
  TerminalSize _size;
  bool _feedingOutput = false;

  /// Fired with each non-empty line submitted at a validated OSC 133 prompt.
  /// Input without shell integration, or while a program is running, is never
  /// reported. Used to suggest frequently-run commands as snippets and never
  /// leaves the device on its own.
  final void Function(String command)? onCommand;

  /// Current shell directory reported through standard OSC 7 metadata. Null
  /// until the remote shell emits it; never inferred from prompt text.
  final ValueNotifier<String?> workingDirectory = ValueNotifier<String?>(null);

  /// Last OSC 0/2 terminal title. Common Bash configurations include the cwd
  /// here even when they do not emit OSC 7, so Files can use it as a fallback.
  final ValueNotifier<String?> terminalTitle = ValueNotifier<String?>(null);

  /// Explicit OSC 133/1337 prompt and shell metadata. A guarded Files action
  /// uses this conservative state rather than guessing from prompt text.
  final ValueNotifier<ShellIntegrationState> shellIntegration =
      ValueNotifier<ShellIntegrationState>(const ShellIntegrationState());

  /// The command line currently executing (best effort), or null at a prompt.
  ///
  /// Set when Enter submits a non-empty captured line *at an accepting OSC
  /// 133 prompt* — which both filters out lines typed into a running program
  /// and guarantees the integration that will deliver the end-of-command
  /// signal. Without 133 this stays null: a name that can never clear is
  /// worse than none. Cleared when the shell reports the command done
  /// (`133;D`) or a fresh prompt (`133;A`).
  final ValueNotifier<String?> activeCommand = ValueNotifier<String?>(null);

  /// Ticks when the shell may have moved, with or without shell
  /// integration: on every Enter that may reach it, an empty line or a
  /// recalled history entry included, and when a full-screen program hands
  /// the terminal back (a picker whose choice the shell then `cd`s to). An
  /// Enter on the alternate screen (an editor, a pager) or known to go to a
  /// running program does not tick. [activeCommand] and [onCommand] need OSC
  /// 133, and [onCommand] skips lines it could not reconstruct, so a shell
  /// that reports no directory is re-read on this instead.
  Listenable get shellMayHaveMoved => _shellMoves;
  final ValueNotifier<int> _shellMoves = ValueNotifier<int>(0);

  // A best-effort reconstruction of the current, not-yet-submitted input line,
  // built from the keystrokes the user sends. Used to prefill the command
  // generator. It's an approximation — full readline editing (history, cursor
  // moves) isn't modelled — but covers the common "typed a partial command"
  // case.
  String _pendingInput = '';
  bool _localInputSincePrompt = false;
  bool _submittedSincePrompt = false;
  bool _sawCommandCompletion = false;
  bool _hasAcceptedPrompt = false;

  /// One-shot Ctrl modifier for the on-screen key row (mobile has no physical
  /// Ctrl): when armed, the next character the soft keyboard produces is sent
  /// as its control code (e.g. `c` → 0x03). Consumed after one keystroke.
  final ValueNotifier<bool> ctrlArmed = ValueNotifier<bool>(false);

  /// The platform the terminal reports itself as running on.
  ///
  /// Never leave this [TerminalTargetPlatform.unknown]: xterm's input
  /// handlers gate "Option/Alt sends Meta" on it, and `unknown` takes the
  /// non-macOS path. On a Mac that turned Option-N into `ESC N` **and marked
  /// the key event handled**, which starved the IME of the keystroke — so
  /// dead keys never composed and every Option-composed character on
  /// international layouts (`~` on Swiss Option-N, `@` on German Option-G, …)
  /// was untypeable. The stray `ESC N` then put remote readline into its
  /// non-incremental history search, whose prompt renders as `:` — the
  /// "types a colon" symptom.
  static TerminalTargetPlatform detectPlatform({
    TargetPlatform? platform,
    bool isWeb = kIsWeb,
  }) {
    if (isWeb) return TerminalTargetPlatform.web;
    return switch (platform ?? defaultTargetPlatform) {
      TargetPlatform.android => TerminalTargetPlatform.android,
      TargetPlatform.fuchsia => TerminalTargetPlatform.fuchsia,
      TargetPlatform.iOS => TerminalTargetPlatform.ios,
      TargetPlatform.linux => TerminalTargetPlatform.linux,
      TargetPlatform.macOS => TerminalTargetPlatform.macos,
      TargetPlatform.windows => TerminalTargetPlatform.windows,
    };
  }

  XtermTerminalEngine({
    int maxLines = 10000,
    TerminalSize? initialSize,
    this.onCommand,
  }) : terminal = Terminal(maxLines: maxLines, platform: detectPlatform()),
       _size = initialSize ?? const TerminalSize(80, 24) {
    _terminalDecoder = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(_TerminalOutputSink(terminal));
    // Keystrokes / paste / device replies produced by the terminal go to SSH.
    terminal.onOutput = (data) {
      if (_disposed) return;
      // xterm answers terminal queries synchronously during feed. These
      // replies belong to the transport, so they must not consume a user's
      // one-shot modifier or turn an empty shell prompt into pending input.
      final out = _feedingOutput ? data : _applyCtrl(data);
      if (!_feedingOutput) {
        _markInputActivity();
        _trackPending(out);
      }
      _input.add(Uint8List.fromList(utf8.encode(out)));
    };
    terminal.onTitleChange = (title) => terminalTitle.value = title;
    terminal.onPrivateOSC = _handlePrivateOsc;
  }

  void _handlePrivateOsc(String code, List<String> args) {
    if (args.isEmpty) return;
    if (code == '133') {
      _handlePromptMarker(args);
      return;
    }
    if (code == '1337') {
      _handleShellIdentity(args);
      return;
    }
    if (code != '7') return;
    _handleWorkingDirectory(args.join(';'));
  }

  /// The host of the first OSC 7 report that named one, lower-cased.
  String? _directoryHost;

  /// Takes `file://host/path` from OSC 7. The path is cut at the first `/`
  /// after the host and percent-decoded as a whole, rather than parsed as a
  /// URI, so an unencoded `?` or `#` some emitters leave in stays part of
  /// it. A report from another host than the session's first is ignored: a
  /// nested `ssh other` whose shell reports its own directory must not move
  /// the Files and Git panes onto a path of the wrong machine. An empty
  /// host or `localhost` names the session's own host.
  void _handleWorkingDirectory(String value) {
    const prefix = 'file://';
    if (!value.startsWith(prefix)) return;
    final slash = value.indexOf('/', prefix.length);
    if (slash < 0) return;

    final host = value.substring(prefix.length, slash).toLowerCase();
    if (host.isNotEmpty && host != 'localhost') {
      final known = _directoryHost ??= host;
      if (host != known) return;
    }

    final String path;
    try {
      path = Uri.decodeComponent(value.substring(slash));
    } on ArgumentError {
      return; // Malformed remote metadata must never disrupt the terminal.
    } on FormatException {
      return;
    }
    if (path.contains('\u0000')) return;
    workingDirectory.value = path;
  }

  void _handlePromptMarker(List<String> args) {
    final marker = args.first;
    final current = shellIntegration.value;
    switch (marker) {
      case 'A':
        activeCommand.value = null;
        shellIntegration.value = current.copyWith(
          phase: TerminalPromptPhase.rendering,
          clearExitCode: true,
        );
      case 'B':
        final initialPrompt = !_hasAcceptedPrompt && !_localInputSincePrompt;
        final completedCommand = _submittedSincePrompt && _sawCommandCompletion;
        if (current.phase != TerminalPromptPhase.rendering ||
            (!initialPrompt && !completedCommand)) {
          return;
        }
        _hasAcceptedPrompt = true;
        _localInputSincePrompt = false;
        _submittedSincePrompt = false;
        _sawCommandCompletion = false;
        shellIntegration.value = current.copyWith(
          phase: TerminalPromptPhase.acceptingInput,
          inputSincePrompt: false,
        );
      case 'C':
        shellIntegration.value = current.copyWith(
          phase: TerminalPromptPhase.executing,
          inputSincePrompt: true,
        );
      case 'D':
        activeCommand.value = null;
        final status = args.length > 1 ? int.tryParse(args[1]) : null;
        if (_submittedSincePrompt) _sawCommandCompletion = true;
        shellIntegration.value = current.copyWith(
          phase: TerminalPromptPhase.done,
          inputSincePrompt: true,
          lastExitCode: status != null && status >= 0 && status <= 255
              ? status
              : null,
          clearExitCode: status == null || status < 0 || status > 255,
        );
    }
  }

  static final RegExp _shellIntegrationVersion = RegExp(
    r'^ShellIntegrationVersion=[1-9][0-9]*$',
  );

  /// Takes `1337;ShellIntegrationVersion=<n>;<shell>` (Séance's snippets)
  /// and the `;shell=<shell>` form iTerm2's own integration sends, of any
  /// version.
  void _handleShellIdentity(List<String> args) {
    if (args.length < 2 || !_shellIntegrationVersion.hasMatch(args.first)) {
      return;
    }
    const key = 'shell=';
    final name = args[1].startsWith(key)
        ? args[1].substring(key.length)
        : args[1];
    final shell = switch (name.toLowerCase()) {
      'bash' || 'zsh' || 'sh' => RemoteShellKind.posix,
      'fish' => RemoteShellKind.fish,
      _ => null,
    };
    if (shell != null) {
      shellIntegration.value = shellIntegration.value.copyWith(shell: shell);
    }
  }

  /// The current, not-yet-submitted input line (best effort).
  String get pendingInput => _pendingInput;

  /// If the Ctrl modifier is armed and [data] is one typed character, send
  /// that character's control code and disarm. Anything else passes
  /// unchanged and leaves Ctrl armed for the key it was meant for: a paste
  /// (several characters, or ESC-led when bracketed), a mouse report or a
  /// hardware arrow key (ESC-led), as [sendCursorKey] already does.
  String _applyCtrl(String data) {
    if (!ctrlArmed.value) return data;
    final runes = data.runes;
    if (runes.length != 1 || runes.first == _escape) return data;
    ctrlArmed.value = false;
    final code = _controlCode(runes.first);
    if (code == null) return data;
    return String.fromCharCode(code);
  }

  /// Map a printable ASCII key to the control code Ctrl+key would produce, or
  /// null if there's no sensible mapping. Covers letters (Ctrl-C, Ctrl-D, …)
  /// and the `@ [ \ ] ^ _` / space group.
  static int? _controlCode(int c) {
    if (c >= 0x61 && c <= 0x7a) return c - 0x60; // a-z → 1..26
    if (c >= 0x41 && c <= 0x5a) return c - 0x40; // A-Z → 1..26
    if (c == 0x20 || c == 0x40) return 0; // space / @ → NUL
    if (c >= 0x5b && c <= 0x5f) return c - 0x40; // [ \ ] ^ _ → 27..31
    return null;
  }

  /// Fold one outbound chunk into [_pendingInput]. Escape sequences (arrow
  /// keys, device replies) arrive as their own chunk starting with ESC and are
  /// ignored; Enter clears the line (and reports the command); backspace/kill
  /// trim it.
  void _trackPending(String data) {
    if (data.isEmpty || data.codeUnitAt(0) == 0x1b) return;
    for (final r in data.runes) {
      if (r == 0x0d || r == 0x0a) {
        // Read before the phase is overwritten below: only an Enter at an
        // accepting prompt submits a *command*. An Enter while a command is
        // already executing is input to that program, not a new command.
        final phase = shellIntegration.value.phase;
        final atPrompt = phase == TerminalPromptPhase.acceptingInput;
        // Once the shell has shown an integrated prompt, `executing` is known
        // rather than assumed: the line goes to a running program (a password
        // prompt, a REPL) and is no command to suggest. That also covers a
        // nested `ssh` or `su` without integration, whose own password prompt
        // cannot be told from its commands, and a PS2 continuation line,
        // which was only ever a fragment. `done` and `unknown` do not prove a
        // prompt either; capture resumes only after a validated A/B pair.
        final toProgram =
            _hasAcceptedPrompt && phase == TerminalPromptPhase.executing;
        _submittedSincePrompt = true;
        shellIntegration.value = shellIntegration.value.copyWith(
          phase: TerminalPromptPhase.executing,
          inputSincePrompt: true,
        );
        _submitPending(atPrompt: atPrompt);
        if (!toProgram && !terminal.isUsingAltBuffer) _shellMoves.value++;
      } else if (r == 0x7f || r == 0x08) {
        if (_pendingInput.isNotEmpty) {
          _pendingInput = _pendingInput.substring(0, _pendingInput.length - 1);
        }
      } else if (r == 0x15 || r == 0x03) {
        if (r == 0x03) _submittedSincePrompt = true;
        _pendingInput = ''; // Ctrl-U (kill line) / Ctrl-C (interrupt)
      } else if (r >= 0x20) {
        _pendingInput += String.fromCharCode(r);
      }
    }
  }

  /// A line was submitted: report it (for command suggestions) and reset.
  ///
  /// [atPrompt] — whether the shell was at an accepting OSC 133 prompt when
  /// Enter arrived. Only then is the line a command (see [activeCommand]);
  /// `acceptingInput` is only ever set from a `133;B` marker, so this gate
  /// also implies the integration that will later deliver the clearing `D`.
  void _submitPending({required bool atPrompt}) {
    final line = _pendingInput.trim();
    if (line.isNotEmpty && atPrompt) {
      onCommand?.call(line);
      activeCommand.value = line;
    }
    _pendingInput = '';
  }

  /// Type [text] into the session as if the user typed it — used by the
  /// assistant's paste-to-prompt tool. The remote shell echoes it back so it
  /// appears at the prompt. It is cleaned with [PasteSanitizer.sanitize]
  /// first, so it never executes and cannot steer the terminal: control
  /// characters other than Tab are dropped, and a line break throws
  /// [UnsafePasteException] with nothing sent. [sendKey] is the raw path.
  void injectInput(String text) {
    if (_disposed) return;
    text = PasteSanitizer.sanitize(text);
    _markInputActivity();
    _trackPending(text);
    _input.add(Uint8List.fromList(utf8.encode(text)));
  }

  /// Send raw [bytes] to the session — used by the on-screen key row for fixed
  /// byte inputs such as Tab, Esc, and Ctrl-C. Unlike
  /// [injectInput] this is allowed to carry control bytes such as Enter.
  void sendKey(List<int> bytes) {
    if (_disposed) return;
    _markInputActivity();
    _trackPending(utf8.decode(bytes, allowMalformed: true));
    _input.add(Uint8List.fromList(bytes));
  }

  /// Send an arrow, Home, or End [key] using the active DECCKM mode.
  void sendCursorKey(TerminalCursorKey key) {
    if (_disposed) return;
    // Cursor sequences are intentionally terminal controls, not command text.
    // Bypass pending-input tracking and leave one-shot Ctrl armed for typing.
    _markInputActivity();
    _input.add(Uint8List.fromList(_cursorSequence(key)));
  }

  /// Moves the shell line editor's caret to [target] with cursor-key input.
  ///
  /// A terminal cannot set shell-owned editing state directly. Restrict the
  /// approximation to the cursor's current soft-wrapped line, where one arrow
  /// per visible character preserves the shell's own prompt and input rules.
  void moveCaretTo(CellOffset target) {
    if (_disposed || terminal.isUsingAltBuffer) return;
    // A mouse-aware remote already owns the press; arrows would duplicate it.
    if (terminal.mouseMode != MouseMode.none) return;
    if (_hasAcceptedPrompt &&
        shellIntegration.value.phase != TerminalPromptPhase.acceptingInput) {
      return;
    }

    final buffer = terminal.buffer;
    if (target.x < 0 ||
        target.x >= terminal.viewWidth ||
        target.y < 0 ||
        target.y >= buffer.lines.length) {
      return;
    }

    final cursor = CellOffset(buffer.cursorX, buffer.absoluteCursorY);
    final distance = _visibleCharacterDistance(cursor, target);
    if (distance == null || distance == 0) return;

    final key = distance < 0
        ? TerminalCursorKey.arrowLeft
        : TerminalCursorKey.arrowRight;
    final sequence = _cursorSequence(key);
    final bytes = Uint8List(sequence.length * distance.abs());
    for (var offset = 0; offset < bytes.length; offset += sequence.length) {
      bytes.setRange(offset, offset + sequence.length, sequence);
    }

    _markInputActivity();
    _input.add(bytes);
  }

  List<int> _cursorSequence(TerminalCursorKey key) => [
    _escape,
    terminal.cursorKeysMode ? _singleShiftThree : _controlSequenceIntroducer,
    key.finalByte,
  ];

  int? _visibleCharacterDistance(CellOffset cursor, CellOffset target) {
    final forward = cursor.isBefore(target);
    final start = forward ? cursor : target;
    final end = forward ? target : cursor;
    final buffer = terminal.buffer;
    var distance = 0;

    for (var row = start.y; row <= end.y; row++) {
      if (row > start.y && !buffer.lines[row].isWrapped) return null;

      final line = buffer.lines[row];
      final firstColumn = row == start.y ? start.x : 0;
      final lastColumn = row == end.y ? end.x : terminal.viewWidth;
      for (var column = firstColumn; column < lastColumn; column++) {
        // Width zero is either a wide character's continuation or empty space.
        if (line.getWidth(column) > 0) distance++;
      }
    }

    return forward ? distance : -distance;
  }

  /// Stages a quoted `cd` at a verified empty prompt, without submitting it.
  TerminalStageResult stageChangeDirectory(String absolutePath) {
    if (_disposed) return TerminalStageResult.promptNotReady;
    final state = shellIntegration.value;
    final shell = state.shell;
    if (shell == null) return TerminalStageResult.shellIntegrationRequired;
    if (state.phase != TerminalPromptPhase.acceptingInput) {
      return TerminalStageResult.promptNotReady;
    }
    if (state.inputSincePrompt || _pendingInput.isNotEmpty) {
      return TerminalStageResult.pendingInput;
    }
    late final String command;
    try {
      command = buildChangeDirectoryCommand(absolutePath, shell: shell);
    } on ArgumentError {
      return TerminalStageResult.invalidPath;
    }
    injectInput(command);
    return TerminalStageResult.staged;
  }

  void _markInputActivity() {
    _localInputSincePrompt = true;
    final state = shellIntegration.value;
    if (!state.inputSincePrompt) {
      shellIntegration.value = state.copyWith(inputSincePrompt: true);
    }
  }

  /// Toggle the one-shot Ctrl modifier (armed by the key row's Ctrl button).
  void toggleCtrl() {
    if (_disposed) return;
    ctrlArmed.value = !ctrlArmed.value;
  }

  @override
  void feed(Uint8List data) {
    // A tab can close while its SSH handshake is still opening the shell.
    // The pending connection is closed when it returns, but may emit data
    // first; never revive a disposed terminal or notify its released views.
    if (_disposed) return;
    final wasFeedingOutput = _feedingOutput;
    final wasFullScreen = terminal.isUsingAltBuffer;
    _feedingOutput = true;
    try {
      _terminalDecoder.add(data);
    } finally {
      _feedingOutput = wasFeedingOutput;
    }
    if (wasFullScreen && !terminal.isUsingAltBuffer) _shellMoves.value++;
  }

  @override
  Stream<Uint8List> get userInput => _input.stream;

  @override
  TerminalSize get size => _size;

  @override
  void resize(TerminalSize size) {
    // Only record the size — the xterm widget owns the on-screen terminal size
    // (autoResize) and calls terminal.resize itself, which is what fires
    // terminal.onResize. Since our onResize handler routes back here (to forward
    // the size to the remote PTY), calling terminal.resize again would re-fire
    // onResize and recurse until the stack overflows. So this is bookkeeping
    // only, mirroring HeadlessTerminalEngine.
    _size = size;
  }

  /// Rendered scrollback text (no escape codes) for LLM context — the last
  /// [maxLines] lines. Uses xterm's own buffer so it matches what the user sees.
  ///
  /// Reads only the requested range. `getText()` with no argument materializes
  /// the *entire* buffer — up to `maxLines: 10000` rows of full-width cells —
  /// into one string, which the old implementation then split into a
  /// ten-thousand-element list to keep the last two hundred entries. That ran
  /// on every assistant turn and every ⌘K, and cost megabytes of allocation on
  /// a long-lived session.
  String recentText({int maxLines = 200}) {
    final buffer = terminal.buffer;
    final height = buffer.height;
    final viewWidth = terminal.viewWidth;
    if (height <= 0 || maxLines <= 0 || viewWidth <= 0) return '';
    final start = height > maxLines ? height - maxLines : 0;
    return buffer
        .getText(
          BufferRangeLine(
            CellOffset(0, start),
            CellOffset(viewWidth, height - 1),
          ),
        )
        .trimRight();
  }

  bool _disposed = false;

  @override
  Future<void> dispose() async {
    // Idempotent: with per-server tabs, closeTab/reconnect can dispose an
    // engine that a closing SshSession also disposes. A second dispose would
    // otherwise re-dispose the ValueNotifier (a debug assertion).
    if (_disposed) return;
    _disposed = true;
    _terminalDecoder.close();
    ctrlArmed.dispose();
    workingDirectory.dispose();
    terminalTitle.dispose();
    shellIntegration.dispose();
    activeCommand.dispose();
    _shellMoves.dispose();
    await _input.close();
  }
}

class _TerminalOutputSink implements Sink<String> {
  final Terminal terminal;

  _TerminalOutputSink(this.terminal);

  @override
  void add(String data) => terminal.write(data);

  @override
  void close() {
    // Decoder closure flushes pending bytes; xterm has no output sink to close.
  }
}
