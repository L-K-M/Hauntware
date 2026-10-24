import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:ghost_fonts/ghost_fonts.dart'
    show ghostMonoFontFamilies, ghostMonoFontFamily;

import 'xterm_engine.dart';

/// The key caps' face: the family's shared monospace stack, led by bundled
/// JetBrains Mono, as Séance's `SeanceTheme.mono` draws it.
const TextStyle _mono = TextStyle(
  fontFamily: ghostMonoFontFamily,
  fontFamilyFallback: ghostMonoFontFamilies,
);

/// What [TerminalKeyboardBar] says to assistive technology: each key's
/// semantics label, and the tooltip of the keys that show one. The
/// defaults are English; an app with its own strings passes them. The
/// cap legends (`esc`, `ctrl`, `^C`, `pgup`, `|`, ...) are key names and
/// stay as they are.
@immutable
class TerminalKeyboardBarStrings {
  const TerminalKeyboardBarStrings({
    this.escape = 'Escape',
    this.tab = 'Tab',
    this.controlModifier = 'Control modifier',
    this.controlC = 'Control C',
    this.leftArrow = 'Left arrow',
    this.upArrow = 'Up arrow',
    this.downArrow = 'Down arrow',
    this.rightArrow = 'Right arrow',
    this.home = 'Home',
    this.end = 'End',
    this.pageUp = 'Page up',
    this.pageDown = 'Page down',
    this.pipe = 'Pipe',
    this.slash = 'Slash',
    this.hyphen = 'Hyphen',
    this.tilde = 'Tilde',
    this.hideKeyboard = 'Hide keyboard',
  });

  final String escape;
  final String tab;
  final String controlModifier;
  final String controlC;
  final String leftArrow;
  final String upArrow;
  final String downArrow;
  final String rightArrow;
  final String home;
  final String end;
  final String pageUp;
  final String pageDown;
  final String pipe;
  final String slash;
  final String hyphen;
  final String tilde;
  final String hideKeyboard;
}

/// A compact, horizontally-scrollable row of keys the soft keyboard lacks —
/// Esc, Tab, Ctrl, arrows, Home/End/PgUp/PgDn and a few shell punctuation
/// characters — shown above the keyboard on touch platforms.
///
/// Every button sends bytes straight to the session, so nothing here can be
/// mistaken for typed text. `Ctrl` is a one-shot modifier: tap it (it lights
/// up), then a letter on the soft keyboard, to send e.g. Ctrl-C. A dedicated
/// `^C` button is provided too because interrupting is the common case.
class TerminalKeyboardBar extends StatelessWidget {
  final XtermTerminalEngine engine;
  final TerminalKeyboardBarStrings strings;
  const TerminalKeyboardBar({
    super.key,
    required this.engine,
    this.strings = const TerminalKeyboardBarStrings(),
  });

  static const List<int> _esc = [0x1b];
  static const List<int> _tab = [0x09];
  static const List<int> _ctrlC = [0x03];
  static const List<int> _pgUp = [0x1b, 0x5b, 0x35, 0x7e];
  static const List<int> _pgDn = [0x1b, 0x5b, 0x36, 0x7e];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        // Keep the soft keyboard open: without this, tapping a key would move
        // focus off the terminal's hidden input and dismiss the keyboard.
        child: ExcludeFocus(
          child: SizedBox(
            height: 46,
            child: Row(
              children: [
                Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 6,
                    ),
                    children: [
                      _label('esc', _esc, strings.escape),
                      _label('tab', _tab, strings.tab),
                      _ctrlKey(context),
                      _label('^C', _ctrlC, strings.controlC),
                      _icon(
                        Icons.keyboard_arrow_left,
                        TerminalCursorKey.arrowLeft,
                        strings.leftArrow,
                      ),
                      _icon(
                        Icons.keyboard_arrow_up,
                        TerminalCursorKey.arrowUp,
                        strings.upArrow,
                      ),
                      _icon(
                        Icons.keyboard_arrow_down,
                        TerminalCursorKey.arrowDown,
                        strings.downArrow,
                      ),
                      _icon(
                        Icons.keyboard_arrow_right,
                        TerminalCursorKey.arrowRight,
                        strings.rightArrow,
                      ),
                      _cursorKey('home', TerminalCursorKey.home, strings.home),
                      _cursorKey('end', TerminalCursorKey.end, strings.end),
                      _label('pgup', _pgUp, strings.pageUp),
                      _label('pgdn', _pgDn, strings.pageDown),
                      _char('|', strings.pipe),
                      _char('/', strings.slash),
                      _char('-', strings.hyphen),
                      _char('~', strings.tilde),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                _KeyButton(
                  onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                  semanticLabel: strings.hideKeyboard,
                  tooltip: strings.hideKeyboard,
                  child: const Icon(Icons.keyboard_hide_outlined, size: 20),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String text, List<int> bytes, String semanticLabel) =>
      _KeyButton(
        onTap: () => engine.sendKey(bytes),
        semanticLabel: semanticLabel,
        child: Text(text, style: _mono.copyWith(fontSize: 13)),
      );

  Widget _icon(IconData icon, TerminalCursorKey key, String semanticLabel) =>
      _KeyButton(
        onTap: () => engine.sendCursorKey(key),
        semanticLabel: semanticLabel,
        tooltip: semanticLabel,
        child: Icon(icon, size: 20),
      );

  Widget _cursorKey(String text, TerminalCursorKey key, String semanticLabel) =>
      _KeyButton(
        onTap: () => engine.sendCursorKey(key),
        semanticLabel: semanticLabel,
        child: Text(text, style: _mono.copyWith(fontSize: 13)),
      );

  Widget _char(String ch, String semanticLabel) => _KeyButton(
    onTap: () => engine.sendKey(utf8.encode(ch)),
    semanticLabel: semanticLabel,
    child: Text(ch, style: _mono.copyWith(fontSize: 15)),
  );

  /// The sticky Ctrl modifier, highlighted while armed.
  Widget _ctrlKey(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<bool>(
      valueListenable: engine.ctrlArmed,
      builder: (context, armed, _) => _KeyButton(
        onTap: engine.toggleCtrl,
        semanticLabel: strings.controlModifier,
        toggled: armed,
        background: armed ? scheme.primary : null,
        child: Text(
          'ctrl',
          style: _mono.copyWith(
            fontSize: 13,
            fontWeight: armed ? FontWeight.bold : FontWeight.normal,
            color: armed ? scheme.onPrimary : null,
          ),
        ),
      ),
    );
  }
}

/// One key cap: a small, tappable rounded rectangle.
class _KeyButton extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  final String semanticLabel;
  final String? tooltip;
  final bool? toggled;
  final Color? background;
  const _KeyButton({
    required this.child,
    required this.onTap,
    required this.semanticLabel,
    this.tooltip,
    this.toggled,
    this.background,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget keyCap = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Material(
        color: background ?? scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 40),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: child,
          ),
        ),
      ),
    );
    if (tooltip != null) {
      keyCap = Tooltip(
        message: tooltip!,
        excludeFromSemantics: true,
        child: keyCap,
      );
    }
    return Semantics(
      button: true,
      label: semanticLabel,
      toggled: toggled,
      onTap: onTap,
      excludeSemantics: true,
      child: keyCap,
    );
  }
}
