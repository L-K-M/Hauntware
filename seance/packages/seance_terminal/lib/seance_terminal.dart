/// Séance's terminal, shared with the apps that host a shell
/// (docs/design/seance-terminal.md).
library;

export 'package:xterm/xterm.dart'
    show
        TerminalController,
        TerminalLigatures,
        TerminalStyle,
        TerminalTheme,
        TerminalView;

export 'src/byte_session.dart' show TerminalByteSession, TerminalByteTransport;
export 'src/paste_policy.dart'
    show
        TerminalPasteChoice,
        TerminalPasteFinding,
        TerminalPastePolicy,
        TerminalPasteReview,
        TerminalPasteSeverity;
export 'src/terminal_appearance.dart'
    show
        SeanceTerminalThemes,
        TerminalAppearance,
        TerminalPalette,
        clampTerminalFontSize,
        kDefaultTerminalFont,
        kDefaultTerminalFontSize,
        kMaxTerminalFontSize,
        kMinTerminalFontSize,
        kTerminalFontSizeStep;
export 'src/terminal_keyboard_bar.dart'
    show TerminalKeyboardBar, TerminalKeyboardBarStrings;
export 'src/xterm_engine.dart'
    show
        ShellIntegrationState,
        TerminalCursorKey,
        TerminalPromptPhase,
        TerminalStageResult,
        XtermTerminalEngine;
