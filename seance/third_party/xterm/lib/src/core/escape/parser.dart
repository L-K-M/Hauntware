import 'package:xterm/src/core/color.dart';
import 'package:xterm/src/core/mouse/mode.dart';
import 'package:xterm/src/core/escape/handler.dart';
import 'package:xterm/src/utils/ascii.dart';
import 'package:xterm/src/utils/char_code.dart';
import 'package:xterm/src/utils/lookup_table.dart';

/// [seance fork] The default cap on a buffered OSC, including its `ESC ]`
/// introducer. Once the cap is crossed, input is discarded through BEL or ST
/// without being stored.
const kMaxPendingSequenceLength = 64 * 1024;

/// Maximum size of a CSI, including its two-byte `ESC [` introducer.
const kMaxCsiSequenceLength = 4096;

/// Maximum number of positional parameters accepted in one CSI.
const kMaxCsiParameters = 32;

/// Largest CSI parameter value retained while parsing decimal digits.
const kMaxCsiParameterValue = 1000000;

/// [EscapeParser] translates control characters and escape sequences into
/// function calls that the terminal can handle.
///
/// Design goals:
///  * Process every rune once, independent of write boundaries.
///  * Keep incomplete control strings bounded.
class EscapeParser {
  final EscapeHandler handler;

  /// [seance fork] See [kMaxPendingSequenceLength]. Injectable so tests can
  /// drive the overflow path without generating 64 KiB of input.
  final int maxPendingSequenceLength;

  EscapeParser(
    this.handler, {
    this.maxPendingSequenceLength = kMaxPendingSequenceLength,
  }) : assert(maxPendingSequenceLength >= 2);

  var _state = _ParserState.ground;
  var _totalConsumed = 0;

  /// Start of sequence or character being processed. Useful for debugging.
  var tokenBegin = 0;

  /// End of sequence or character being processed. Useful for debugging.
  int get tokenEnd => _totalConsumed;

  void write(String chunk) {
    for (final char in chunk.runes) {
      if (_state == _ParserState.ground) {
        tokenBegin = _totalConsumed;
      }
      _totalConsumed++;
      _processRune(char);
    }
  }

  void _processRune(int char) {
    if (_state != _ParserState.ground &&
        (char == Ascii.CAN || char == Ascii.SUB)) {
      _cancelSequence();
      return;
    }

    switch (_state) {
      case _ParserState.ground:
        if (char == Ascii.ESC) {
          _state = _ParserState.escape;
        } else {
          _processChar(char);
        }
        return;
      case _ParserState.escape:
        _processEscapeChar(char);
        return;
      case _ParserState.charset0:
        _processCharset(char, 0);
        return;
      case _ParserState.charset1:
        _processCharset(char, 1);
        return;
      case _ParserState.csi:
        _processCsiChar(char);
        return;
      case _ParserState.csiIgnore:
        _processIgnoredCsiChar(char);
        return;
      case _ParserState.osc:
        _processOscChar(char);
        return;
      case _ParserState.oscEscape:
        _processOscEscapeChar(char);
        return;
      case _ParserState.oscDiscard:
        _processDiscardedOscChar(char);
        return;
      case _ParserState.oscDiscardEscape:
        _processDiscardedOscEscapeChar(char);
        return;
      case _ParserState.stringDiscard:
        if (char == Ascii.ESC) {
          _state = _ParserState.stringDiscardEscape;
        }
        return;
      case _ParserState.stringDiscardEscape:
        if (char == Ascii.backslash) {
          _state = _ParserState.ground;
        } else if (char != Ascii.ESC) {
          _state = _ParserState.stringDiscard;
        }
        return;
    }
  }

  void _processChar(int char) {
    if (char > _sbcHandlers.maxIndex) {
      handler.writeChar(char);
      return;
    }

    final sbcHandler = _sbcHandlers[char];
    if (sbcHandler == null) {
      handler.unkownEscape(char);
      return;
    }

    sbcHandler();
  }

  void _processEscapeChar(int char) {
    if (char == Ascii.ESC) {
      tokenBegin = _totalConsumed - 1;
      return;
    }

    switch (char) {
      case Ascii.openBracket:
        _startCsi();
        return;
      case Ascii.closeBracket:
        _startOsc();
        return;
      case Ascii.openParentheses:
        _state = _ParserState.charset0;
        return;
      case Ascii.closeParentheses:
        _state = _ParserState.charset1;
        return;
      case Ascii.P:
      case Ascii.X:
      case Ascii.caret:
      case Ascii.underscore:
        _state = _ParserState.stringDiscard;
        return;
    }

    final escapeHandler = _escHandlers[char];
    _state = _ParserState.ground;
    if (escapeHandler == null) {
      handler.unkownEscape(char);
    } else {
      escapeHandler();
    }
  }

  void _processCharset(int char, int charset) {
    if (char == Ascii.ESC) {
      tokenBegin = _totalConsumed - 1;
      _state = _ParserState.escape;
      return;
    }

    _state = _ParserState.ground;
    handler.designateCharset(charset, char);
  }

  late final _sbcHandlers = FastLookupTable<_SbcHandler>({
    0x07: handler.bell,
    0x08: handler.backspaceReturn,
    0x09: handler.tab,
    0x0a: handler.lineFeed,
    0x0b: handler.lineFeed,
    0x0c: handler.lineFeed,
    0x0d: handler.carriageReturn,
    0x0e: handler.shiftOut,
    0x0f: handler.shiftIn,
  });

  late final _escHandlers = FastLookupTable<_EscHandler>({
    '7'.charCode: _escHandleSaveCursor,
    '8'.charCode: _escHandleRestoreCursor,
    'D'.charCode: _escHandleIndex,
    'E'.charCode: _escHandleNextLine,
    'H'.charCode: _escHandleTabSet,
    'M'.charCode: _escHandleReverseIndex,
    // 'c'.charCode: _unsupportedHandler,
    // '#'.charCode: _unsupportedHandler,
    // '*'.charCode: _voidHandler(1), // TODO: G2 (vt220)
    // '+'.charCode: _voidHandler(1), // TODO: G3 (vt220)
    '>'.charCode: _escHandleResetAppKeypadMode, // TODO: Normal Keypad
    '='.charCode: _escHandleSetAppKeypadMode, // TODO: Application Keypad
  });

  /// `ESC 7` Save Cursor (DECSC)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_a7/
  void _escHandleSaveCursor() {
    handler.saveCursor();
  }

  /// `ESC 8` Restore Cursor (DECRC)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_a8/
  void _escHandleRestoreCursor() {
    handler.restoreCursor();
  }

  /// `ESC D` Index (IND)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_cd/
  void _escHandleIndex() {
    handler.index();
  }

  /// `ESC E` Next Line (NEL)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_ce/
  void _escHandleNextLine() {
    handler.nextLine();
  }

  /// `ESC H` Horizontal Tab Set (HTS)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_ch/
  void _escHandleTabSet() {
    handler.setTapStop();
  }

  /// `ESC M` Reverse Index (RI)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_cm/
  void _escHandleReverseIndex() {
    handler.reverseIndex();
  }

  /// `ESC >` Reset Application Keypad Mode (DECKPNM)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_x3c_greater_than/
  void _escHandleSetAppKeypadMode() {
    handler.setAppKeypadMode(true);
  }

  /// `ESC =` Set Application Keypad Mode (DECKPAM)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_x3d_equals/
  void _escHandleResetAppKeypadMode() {
    handler.setAppKeypadMode(false);
  }

  void _dispatchCsi() {
    final csiHandler = _csiHandlerFor(_csi);

    if (csiHandler == null) {
      handler.unknownCSI(_csi.finalByte);
    } else {
      csiHandler();
    }
  }

  /// The last parsed [_Csi]. This is a mutable singleton by design to reduce
  /// object allocations.
  final _csi = _Csi(finalByte: 0, params: []);

  var _csiSequenceLength = 0;
  var _csiParameter = 0;
  var _csiHasParameter = false;
  var _csiCanHavePrefix = true;

  void _startCsi() {
    _csi.params.clear();
    _csi.prefix = null;
    _csi.hasIntermediates = false;
    _csiSequenceLength = 2;
    _csiParameter = 0;
    _csiHasParameter = false;
    _csiCanHavePrefix = true;
    _state = _ParserState.csi;
  }

  void _processCsiChar(int char) {
    if (char == Ascii.ESC) {
      _restartEscape();
      return;
    }

    _csiSequenceLength++;
    if (_csiSequenceLength > kMaxCsiSequenceLength) {
      _state = _isCsiFinal(char) ? _ParserState.ground : _ParserState.csiIgnore;
      return;
    }

    if (_isCsiFinal(char)) {
      if (_csiHasParameter && !_appendCsiParameter()) {
        _state = _ParserState.ground;
        return;
      }
      _csi.finalByte = char;
      _state = _ParserState.ground;
      _dispatchCsi();
      return;
    }

    // Embedded C0 controls and DEL are ignored inside a CSI. ESC, CAN and SUB
    // are handled separately because they change the parser state.
    if (char < Ascii.space || char == 0x7f) {
      return;
    }

    if (char >= Ascii.num0 && char <= Ascii.num9) {
      if (_csi.hasIntermediates) {
        _state = _ParserState.csiIgnore;
        return;
      }
      _csiCanHavePrefix = false;
      _csiHasParameter = true;
      final digit = char - Ascii.num0;
      if (_csiParameter > (kMaxCsiParameterValue - digit) ~/ 10) {
        _csiParameter = kMaxCsiParameterValue;
      } else {
        _csiParameter = _csiParameter * 10 + digit;
      }
      return;
    }

    if (char == Ascii.semicolon) {
      if (_csi.hasIntermediates || !_appendCsiParameter()) {
        _state = _ParserState.csiIgnore;
        return;
      }
      // Empty fields retain their positions and default to zero.
      _csiCanHavePrefix = false;
      _csiHasParameter = true;
      return;
    }

    if (char >= Ascii.lessThan && char <= Ascii.questionMark) {
      if (!_csiCanHavePrefix || _csi.prefix != null) {
        _state = _ParserState.csiIgnore;
        return;
      }
      _csi.prefix = char;
      _csiCanHavePrefix = false;
      return;
    }

    if (char >= Ascii.space && char < Ascii.num0) {
      _csi.hasIntermediates = true;
      _csiCanHavePrefix = false;
      return;
    }

    // Colon subparameters and non-ASCII data are not implemented. Ignore the
    // complete function instead of reinterpreting its suffix.
    _state = _ParserState.csiIgnore;
  }

  bool _appendCsiParameter() {
    if (_csi.params.length >= kMaxCsiParameters) {
      return false;
    }
    _csi.params.add(_csiParameter);
    _csiParameter = 0;
    return true;
  }

  void _processIgnoredCsiChar(int char) {
    if (char == Ascii.ESC) {
      _restartEscape();
    } else if (_isCsiFinal(char)) {
      _state = _ParserState.ground;
    }
  }

  bool _isCsiFinal(int char) => char >= Ascii.atSign && char <= Ascii.tilde;

  void _restartEscape() {
    tokenBegin = _totalConsumed - 1;
    _state = _ParserState.escape;
  }

  void _cancelSequence() {
    _oscBuffer.clear();
    _state = _ParserState.ground;
  }

  late final _csiHandlers = FastLookupTable<_CsiHandler>({
    // 'a'.codeUnitAt(0): _csiHandleCursorHorizontalRelative,
    'b'.codeUnitAt(0): _csiHandleRepeatPreviousCharacter,
    'c'.codeUnitAt(0): _csiHandleSendDeviceAttributes,
    'd'.codeUnitAt(0): _csiHandleLinePositionAbsolute,
    'f'.codeUnitAt(0): _csiHandleCursorPosition,
    'g'.codeUnitAt(0): _csiHandelClearTabStop,
    'h'.codeUnitAt(0): _csiHandleMode,
    'l'.codeUnitAt(0): _csiHandleMode,
    'm'.codeUnitAt(0): _csiHandleSgr,
    'n'.codeUnitAt(0): _csiHandleDeviceStatusReport,
    'r'.codeUnitAt(0): _csiHandleSetMargins,
    't'.codeUnitAt(0): _csiWindowManipulation,
    'A'.codeUnitAt(0): _csiHandleCursorUp,
    'B'.codeUnitAt(0): _csiHandleCursorDown,
    'C'.codeUnitAt(0): _csiHandleCursorForward,
    'D'.codeUnitAt(0): _csiHandleCursorBackward,
    'E'.codeUnitAt(0): _csiHandleCursorNextLine,
    'F'.codeUnitAt(0): _csiHandleCursorPrecedingLine,
    'G'.codeUnitAt(0): _csiHandleCursorHorizontalAbsolute,
    'H'.codeUnitAt(0): _csiHandleCursorPosition,
    'J'.codeUnitAt(0): _csiHandleEraseDisplay,
    'K'.codeUnitAt(0): _csiHandleEraseLine,
    'L'.codeUnitAt(0): _csiHandleInsertLines,
    'M'.codeUnitAt(0): _csiHandleDeleteLines,
    'P'.codeUnitAt(0): _csiHandleDelete,
    'S'.codeUnitAt(0): _csiHandleScrollUp,
    'T'.codeUnitAt(0): _csiHandleScrollDown,
    'X'.codeUnitAt(0): _csiHandleEraseCharacters,
    '@'.codeUnitAt(0): _csiHandleInsertBlankCharacters,
  });

  /// [seance fork] The private-marker functions this terminal implements,
  /// keyed by marker. Every other marker and final byte pair is ignored.
  late final _csiPrivateHandlers = {
    Ascii.questionMark: FastLookupTable<_CsiHandler>({
      'h'.codeUnitAt(0): _csiHandleMode, // DECSET
      'l'.codeUnitAt(0): _csiHandleMode, // DECRST
      'n'.codeUnitAt(0): _csiHandleDeviceStatusReport, // DEC DSR
      'J'.codeUnitAt(0): _csiHandleEraseDisplay, // DECSED
      'K'.codeUnitAt(0): _csiHandleEraseLine, // DECSEL
    }),
    Ascii.greaterThan: FastLookupTable<_CsiHandler>({
      'c'.codeUnitAt(0): _csiHandleSendDeviceAttributes, // secondary DA
    }),
    Ascii.equal: FastLookupTable<_CsiHandler>({
      'c'.codeUnitAt(0): _csiHandleSendDeviceAttributes, // tertiary DA
    }),
  };

  /// [seance fork] Finds the handler for the whole function identity of
  /// [csi]. A private marker or an intermediate names a different function
  /// than the bare final byte: `CSI > 4 m` resets xterm's modifyOtherKeys,
  /// `CSI 4 m` turns on underline. Upstream dispatched on the final byte
  /// alone, so Claude Code's exit sequence underlined all later output.
  _CsiHandler? _csiHandlerFor(_Csi csi) {
    // No implemented function takes intermediates, e.g. `CSI 2 SP A` (SR).
    if (csi.hasIntermediates) return null;

    final prefix = csi.prefix;
    if (prefix == null) return _csiHandlers[csi.finalByte];

    return _csiPrivateHandlers[prefix]?[csi.finalByte];
  }

  /// `ESC [ Ps a` Cursor Horizontal Position Relative (HPR)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sa/
  // void _csiHandleCursorHorizontalRelative() {
  //   if (_csi.params.isEmpty) {
  //     handler.cursorHorizontal(1);
  //   } else {
  //     handler.cursorHorizontal(_csi.params[0]);
  //   }
  // }

  /// `ESC [ Ps b` Repeat Previous Character (REP)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sb/
  void _csiHandleRepeatPreviousCharacter() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.repeatPreviousCharacter(amount);
  }

  /// `ESC [ Ps c` Device Attributes (DA)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sc/
  void _csiHandleSendDeviceAttributes() {
    switch (_csi.prefix) {
      case Ascii.greaterThan:
        return handler.sendSecondaryDeviceAttributes();
      case Ascii.equal:
        return handler.sendTertiaryDeviceAttributes();
      default:
        handler.sendPrimaryDeviceAttributes();
    }
  }

  /// `ESC [ Ps d` Cursor Vertical Position Absolute (VPA)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sd/
  void _csiHandleLinePositionAbsolute() {
    var y = 1;

    if (_csi.params.isNotEmpty) {
      y = _csi.params[0];
    }

    handler.setCursorY(y - 1);
  }

  /// `ESC [ Ps ; Ps f` Alias: Set Cursor Position
  ///
  /// https://terminalguide.namepad.de/seq/csi_sf/
  void _csiHandleCursorPosition() {
    var row = 1;
    var col = 1;

    if (_csi.params.isNotEmpty) {
      row = _csi.params[0] == 0 ? 1 : _csi.params[0];
    }
    if (_csi.params.length > 1) {
      col = _csi.params[1] == 0 ? 1 : _csi.params[1];
    }

    handler.setCursor(col - 1, row - 1);
  }

  /// `ESC [ Ps g` Tab Clear (TBC)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sg/
  void _csiHandelClearTabStop() {
    var cmd = 0;

    if (_csi.params.length == 1) {
      cmd = _csi.params[0];
    }

    switch (cmd) {
      case 0:
        return handler.clearTabStopUnderCursor();
      default:
        return handler.clearAllTabStops();
    }
  }

  /// - `ESC [ [ Pm ] h Set Mode (SM)` https://terminalguide.namepad.de/seq/csi_sm/
  /// - `ESC [ ? [ Pm ] h` Set Mode (?) (SM) https://terminalguide.namepad.de/seq/csi_sh__p/
  /// - `ESC [ [ Pm ] l` Reset Mode (RM) https://terminalguide.namepad.de/seq/csi_rm/
  /// - `ESC [ ? [ Pm ] l` Reset Mode (?) (RM) https://terminalguide.namepad.de/seq/csi_sl__p/
  void _csiHandleMode() {
    final isEnabled = _csi.finalByte == Ascii.h;

    final isDecModes = _csi.prefix == Ascii.questionMark;

    if (isDecModes) {
      for (var mode in _csi.params) {
        _setDecMode(mode, isEnabled);
      }
    } else {
      for (var mode in _csi.params) {
        _setMode(mode, isEnabled);
      }
    }
  }

  /// `ESC [ [ Ps ] m` Select Graphic Rendition (SGR)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sm/
  void _csiHandleSgr() {
    final params = _csi.params;

    if (params.isEmpty) {
      return handler.resetCursorStyle();
    }

    // This is a workaround for a bug in the analyzer.
    // ignore: dead_code
    for (var i = 0; i < _csi.params.length; i++) {
      final param = params[i];
      switch (param) {
        case 0:
          handler.resetCursorStyle();
          continue;
        case 1:
          handler.setCursorBold();
          continue;
        case 2:
          handler.setCursorFaint();
          continue;
        case 3:
          handler.setCursorItalic();
          continue;
        case 4:
          handler.setCursorUnderline();
          continue;
        case 5:
          handler.setCursorBlink();
          continue;
        case 7:
          handler.setCursorInverse();
          continue;
        case 8:
          handler.setCursorInvisible();
          continue;
        case 9:
          handler.setCursorStrikethrough();
          continue;

        case 21:
          handler.unsetCursorBold();
          continue;
        case 22:
          handler.unsetCursorFaint();
          continue;
        case 23:
          handler.unsetCursorItalic();
          continue;
        case 24:
          handler.unsetCursorUnderline();
          continue;
        case 25:
          handler.unsetCursorBlink();
          continue;
        case 27:
          handler.unsetCursorInverse();
          continue;
        case 28:
          handler.unsetCursorInvisible();
          continue;
        case 29:
          handler.unsetCursorStrikethrough();
          continue;

        case 30:
          handler.setForegroundColor16(NamedColor.black);
          continue;
        case 31:
          handler.setForegroundColor16(NamedColor.red);
          continue;
        case 32:
          handler.setForegroundColor16(NamedColor.green);
          continue;
        case 33:
          handler.setForegroundColor16(NamedColor.yellow);
          continue;
        case 34:
          handler.setForegroundColor16(NamedColor.blue);
          continue;
        case 35:
          handler.setForegroundColor16(NamedColor.magenta);
          continue;
        case 36:
          handler.setForegroundColor16(NamedColor.cyan);
          continue;
        case 37:
          handler.setForegroundColor16(NamedColor.white);
          continue;
        case 38:
          final last = _applyExtendedColor(
            params,
            i,
            _ColorTarget.foreground,
          );
          if (last == null) return;
          i = last;
          continue;
        case 39:
          handler.resetForeground();
          continue;

        case 40:
          handler.setBackgroundColor16(NamedColor.black);
          continue;
        case 41:
          handler.setBackgroundColor16(NamedColor.red);
          continue;
        case 42:
          handler.setBackgroundColor16(NamedColor.green);
          continue;
        case 43:
          handler.setBackgroundColor16(NamedColor.yellow);
          continue;
        case 44:
          handler.setBackgroundColor16(NamedColor.blue);
          continue;
        case 45:
          handler.setBackgroundColor16(NamedColor.magenta);
          continue;
        case 46:
          handler.setBackgroundColor16(NamedColor.cyan);
          continue;
        case 47:
          handler.setBackgroundColor16(NamedColor.white);
          continue;
        case 48:
          final last = _applyExtendedColor(
            params,
            i,
            _ColorTarget.background,
          );
          if (last == null) return;
          i = last;
          continue;
        case 49:
          handler.resetBackground();
          continue;

        case 90:
          handler.setForegroundColor16(NamedColor.brightBlack);
          continue;
        case 91:
          handler.setForegroundColor16(NamedColor.brightRed);
          continue;
        case 92:
          handler.setForegroundColor16(NamedColor.brightGreen);
          continue;
        case 93:
          handler.setForegroundColor16(NamedColor.brightYellow);
          continue;
        case 94:
          handler.setForegroundColor16(NamedColor.brightBlue);
          continue;
        case 95:
          handler.setForegroundColor16(NamedColor.brightMagenta);
          continue;
        case 96:
          handler.setForegroundColor16(NamedColor.brightCyan);
          continue;
        case 97:
          handler.setForegroundColor16(NamedColor.brightWhite);
          continue;

        case 100:
          handler.setBackgroundColor16(NamedColor.brightBlack);
          continue;
        case 101:
          handler.setBackgroundColor16(NamedColor.brightRed);
          continue;
        case 102:
          handler.setBackgroundColor16(NamedColor.brightGreen);
          continue;
        case 103:
          handler.setBackgroundColor16(NamedColor.brightYellow);
          continue;
        case 104:
          handler.setBackgroundColor16(NamedColor.brightBlue);
          continue;
        case 105:
          handler.setBackgroundColor16(NamedColor.brightMagenta);
          continue;
        case 106:
          handler.setBackgroundColor16(NamedColor.brightCyan);
          continue;
        case 107:
          handler.setBackgroundColor16(NamedColor.brightWhite);
          continue;

        default:
          handler.unsupportedStyle(param);
          continue;
      }
    }
  }

  /// Applies an SGR 38/48 group and returns the last parameter it consumed.
  /// A null result means the group is truncated or its mode is unknown, so no
  /// later value can safely be interpreted as an independent SGR command.
  int? _applyExtendedColor(
    List<int> params,
    int start,
    _ColorTarget target,
  ) {
    if (start + 1 >= params.length) return null;

    switch (params[start + 1]) {
      case 2:
        if (start + 4 >= params.length) return null;
        final r = params[start + 2];
        final g = params[start + 3];
        final b = params[start + 4];
        if (_isColorComponent(r) &&
            _isColorComponent(g) &&
            _isColorComponent(b)) {
          switch (target) {
            case _ColorTarget.foreground:
              handler.setForegroundColorRgb(r, g, b);
            case _ColorTarget.background:
              handler.setBackgroundColorRgb(r, g, b);
          }
        }
        return start + 4;
      case 5:
        if (start + 2 >= params.length) return null;
        final index = params[start + 2];
        if (_isColorComponent(index)) {
          switch (target) {
            case _ColorTarget.foreground:
              handler.setForegroundColor256(index);
            case _ColorTarget.background:
              handler.setBackgroundColor256(index);
          }
        }
        return start + 2;
      default:
        return null;
    }
  }

  bool _isColorComponent(int value) => value >= 0 && value <= 255;

  /// `ESC [ Ps n` Device Status Report [Dispatch] (DSR)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sn/
  void _csiHandleDeviceStatusReport() {
    if (_csi.params.isEmpty) return;

    switch (_csi.params[0]) {
      case 5:
        return handler.sendOperatingStatus();
      case 6:
        return handler.sendCursorPosition();
    }
  }

  /// `ESC [ Ps ; Ps r` Set Top and Bottom Margins (DECSTBM)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sr/
  void _csiHandleSetMargins() {
    var top = 1;
    int? bottom;

    if (_csi.params.length > 2) return;

    if (_csi.params.isNotEmpty) {
      top = _csi.params[0] == 0 ? 1 : _csi.params[0];

      // [seance fork] Zero and omitted DECSTBM parameters mean the default
      // top/bottom edges, before converting to zero-based buffer positions.
      if (_csi.params.length == 2 && _csi.params[1] != 0) {
        bottom = _csi.params[1] - 1;
      }
    }

    handler.setMargins(top - 1, bottom);
  }

  /// `ESC [ Ps t` Window operations [DISPATCH]
  ///
  /// https://terminalguide.namepad.de/seq/csi_st/
  void _csiWindowManipulation() {
    // The sequence needs at least one parameter.
    if (_csi.params.isEmpty) {
      return;
    }
    // Most the commands in this group are either of the scope of this package,
    // or should be disabled for security risks.
    switch (_csi.params.first) {
      // Window handling is currently not in the scope of the package.
      case 1: // Restore Terminal Window (show window if minimized)
      case 2: // Minimize Terminal Window
      case 3: // Set Terminal Window Position
      case 4: // Set Terminal Window Size in Pixels
      case 5: // Raise Terminal Window
      case 6: // Lower Terminal Window
      case 7: // Refresh/Redraw Terminal Window
      case 8: // Set Terminal Window Size (in characters)
        return;
      // Window handling is currently no in the scope of the package.
      case 9: // Maximize Terminal Window
      case 10: // Alias: Maximize Terminal Window
      case 11: // Report Terminal Window State
      case 13: // Report Terminal Window Position
      case 14: // Report Terminal Window Size in Pixels
      case 15: // Report Screen Size in Pixels
      case 16: // Report Cell Size in Pixels
        return;
      case 18: // Report Terminal Size (in characters)
        handler.sendSize();
        return;
      // Screen handling is currently no in the scope of the package.
      case 19: // Report Screen Size (in characters)
      // Disabled as these can a security risk.
      case 20: // Get Icon Title
      case 21: // Get Terminal Title
      // Not implemented.
      case 22: // Push Terminal Title
      case 23: // Pop Terminal Title
        return;
      // Unknown CSI.
      default:
        return;
    }
  }

  /// `ESC [ Ps A` Cursor Up (CUU)
  ///
  /// https://terminalguide.namepad.de/seq/csi_ca/
  void _csiHandleCursorUp() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.moveCursorY(-amount);
  }

  /// `ESC [ Ps B` Cursor Down (CUD)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cb/
  void _csiHandleCursorDown() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.moveCursorY(amount);
  }

  /// `ESC [ Ps C` Cursor Right (CUF)
  ///
  /// Cursor Right (CUF)
  void _csiHandleCursorForward() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.moveCursorX(amount);
  }

  /// `ESC [ Ps D` Cursor Left (CUB)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cd/
  void _csiHandleCursorBackward() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.moveCursorX(-amount);
  }

  /// `ESC [ Ps E` Cursor Next Line (CNL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_ce/
  void _csiHandleCursorNextLine() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.cursorNextLine(amount);
  }

  /// `ESC [ Ps F` Cursor Previous Line (CPL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cf/
  void _csiHandleCursorPrecedingLine() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.cursorPrecedingLine(amount);
  }

  void _csiHandleCursorHorizontalAbsolute() {
    var x = 1;

    if (_csi.params.isNotEmpty) {
      x = _csi.params[0];
      if (x == 0) x = 1;
    }

    handler.setCursorX(x - 1);
  }

  /// ESC [ Ps J Erase Display [Dispatch] (ED)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cj/
  void _csiHandleEraseDisplay() {
    var cmd = 0;

    if (_csi.params.length == 1) {
      cmd = _csi.params[0];
    }

    switch (cmd) {
      case 0:
        return handler.eraseDisplayBelow();
      case 1:
        return handler.eraseDisplayAbove();
      case 2:
        return handler.eraseDisplay();
      case 3:
        return handler.eraseScrollbackOnly();
    }
  }

  /// `ESC [ Ps K` Erase Line [Dispatch] (EL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_ck/
  void _csiHandleEraseLine() {
    var cmd = 0;

    if (_csi.params.length == 1) {
      cmd = _csi.params[0];
    }

    switch (cmd) {
      case 0:
        return handler.eraseLineRight();
      case 1:
        return handler.eraseLineLeft();
      case 2:
        return handler.eraseLine();
    }
  }

  /// `ESC [ Ps L` Insert Line (IL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cl/
  void _csiHandleInsertLines() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.insertLines(amount);
  }

  /// ESC [ Ps M Delete Line (DL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cm/
  void _csiHandleDeleteLines() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.deleteLines(amount);
  }

  /// ESC [ Ps P Delete Character (DCH)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cp/
  void _csiHandleDelete() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.deleteChars(amount);
  }

  /// `ESC [ Ps S` Scroll Up (SU)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cs/
  void _csiHandleScrollUp() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.scrollUp(amount);
  }

  /// `ESC [ Ps T `Scroll Down (SD)
  ///
  /// https://terminalguide.namepad.de/seq/csi_ct_1param/
  void _csiHandleScrollDown() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.scrollDown(amount);
  }

  /// `ESC [ Ps X` Erase Character (ECH)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cx/
  void _csiHandleEraseCharacters() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.eraseChars(amount);
  }

  /// `ESC [ Ps @` Insert Blanks (ICH)
  ///
  /// https://terminalguide.namepad.de/seq/csi_x40_at/
  ///
  /// Inserts amount spaces at current cursor position moving existing cell
  /// contents to the right. The contents of the amount right-most columns in
  /// the scroll region are lost. The cursor position is not changed.
  void _csiHandleInsertBlankCharacters() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.insertBlankChars(amount);
  }

  void _setMode(int mode, bool enabled) {
    switch (mode) {
      case 4:
        return handler.setInsertMode(enabled);
      case 20:
        return handler.setLineFeedMode(enabled);
      default:
        return handler.setUnknownMode(mode, enabled);
    }
  }

  void _setDecMode(int mode, bool enabled) {
    switch (mode) {
      case 1:
        return handler.setCursorKeysMode(enabled);
      case 3:
        return handler.setColumnMode(enabled);
      case 5:
        return handler.setReverseDisplayMode(enabled);
      case 6:
        return handler.setOriginMode(enabled);
      case 7:
        return handler.setAutoWrapMode(enabled);
      case 9:
        return enabled
            ? handler.setMouseMode(MouseMode.clickOnly)
            : handler.setMouseMode(MouseMode.none);
      case 12:
      case 13:
        return handler.setCursorBlinkMode(enabled);
      case 25:
        return handler.setCursorVisibleMode(enabled);
      case 47:
        if (enabled) {
          return handler.useAltBuffer();
        } else {
          return handler.useMainBuffer();
        }
      case 66:
        return handler.setAppKeypadMode(enabled);
      case 1000:
      case 10061000:
        return enabled
            ? handler.setMouseMode(MouseMode.upDownScroll)
            : handler.setMouseMode(MouseMode.none);
      case 1001:
        return enabled
            ? handler.setMouseMode(MouseMode.upDownScroll)
            : handler.setMouseMode(MouseMode.none);
      case 1002:
        return enabled
            ? handler.setMouseMode(MouseMode.upDownScrollDrag)
            : handler.setMouseMode(MouseMode.none);
      case 1003:
        return enabled
            ? handler.setMouseMode(MouseMode.upDownScrollMove)
            : handler.setMouseMode(MouseMode.none);
      case 1004:
        return handler.setReportFocusMode(enabled);
      case 1005:
        return enabled
            ? handler.setMouseReportMode(MouseReportMode.utf)
            : handler.setMouseReportMode(MouseReportMode.normal);
      case 1006:
        return enabled
            ? handler.setMouseReportMode(MouseReportMode.sgr)
            : handler.setMouseReportMode(MouseReportMode.normal);
      case 1007:
        return handler.setAltBufferMouseScrollMode(enabled);
      case 1015:
        return enabled
            ? handler.setMouseReportMode(MouseReportMode.urxvt)
            : handler.setMouseReportMode(MouseReportMode.normal);
      case 1047:
        if (enabled) {
          handler.useAltBuffer();
        } else {
          handler.clearAltBuffer();
          handler.useMainBuffer();
        }
        return;
      case 1048:
        if (enabled) {
          return handler.saveCursor();
        } else {
          return handler.restoreCursor();
        }
      case 1049:
        if (enabled) {
          handler.saveCursor();
          handler.clearAltBuffer();
          handler.useAltBuffer();
        } else {
          handler.useMainBuffer();
        }
        return;
      case 2004:
        return handler.setBracketedPasteMode(enabled);
      default:
        return handler.setUnknownDecMode(mode, enabled);
    }
  }

  void _dispatchOsc() {
    // Common OSCs
    if (_osc.length >= 2) {
      final ps = _osc[0];
      final pt = _osc[1];

      switch (ps) {
        case '0':
          handler.setTitle(pt);
          handler.setIconName(pt);
          return;
        case '1':
          handler.setIconName(pt);
          return;
        case '2':
          handler.setTitle(pt);
          return;
        // [seance fork] OSC 8 ; params ; URI — a hyperlink attached to the
        // cells that follow, which is how a program links text that is not a
        // URL (or wraps a URL across its own hard newlines). The params field
        // is ignored: its only defined key, `id`, exists to group a link's
        // cells for hover highlighting, which this terminal does not do. A
        // target may itself contain semicolons, so the rest is rejoined.
        case '8':
          final target = _osc.length > 2 ? _osc.sublist(2).join(';') : '';
          handler.setHyperlink(target.isEmpty ? null : target);
          return;
      }
    }

    // Private extensions
    handler.unknownOSC(_osc[0], _osc.sublist(1));
  }

  final _osc = <String>[];
  final _oscBuffer = StringBuffer();
  var _oscLength = 0;

  void _startOsc() {
    _osc.clear();
    _oscBuffer.clear();
    _oscLength = 2;
    _state = _ParserState.osc;
  }

  void _processOscChar(int char) {
    if (char == Ascii.BEL) {
      _completeOsc();
      return;
    }

    if (char == Ascii.ESC) {
      _state = _ParserState.oscEscape;
      return;
    }

    _oscLength++;
    if (_oscLength > maxPendingSequenceLength) {
      _oscBuffer.clear();
      _state = _ParserState.oscDiscard;
      return;
    }

    _oscBuffer.writeCharCode(char);
  }

  void _processOscEscapeChar(int char) {
    if (char == Ascii.backslash) {
      _completeOsc();
      return;
    }

    if (char == Ascii.ESC) {
      return;
    }

    // An ESC not followed by `\` is invalid inside OSC. Keep the surrounding
    // content quarantined and continue looking for a real BEL or ST.
    _state = _ParserState.osc;
    _processOscChar(char);
  }

  void _completeOsc() {
    final value = _oscBuffer.toString();
    _oscBuffer.clear();
    _osc
      ..clear()
      ..addAll(value.split(';'));
    _state = _ParserState.ground;
    _dispatchOsc();
  }

  void _processDiscardedOscChar(int char) {
    if (char == Ascii.BEL) {
      _state = _ParserState.ground;
    } else if (char == Ascii.ESC) {
      _state = _ParserState.oscDiscardEscape;
    }
  }

  void _processDiscardedOscEscapeChar(int char) {
    if (char == Ascii.backslash || char == Ascii.BEL) {
      _state = _ParserState.ground;
    } else if (char != Ascii.ESC) {
      _state = _ParserState.oscDiscard;
    }
  }
}

enum _ParserState {
  ground,
  escape,
  charset0,
  charset1,
  csi,
  csiIgnore,
  osc,
  oscEscape,
  oscDiscard,
  oscDiscardEscape,
  stringDiscard,
  stringDiscardEscape,
}

enum _ColorTarget { foreground, background }

class _Csi {
  _Csi({
    required this.params,
    required this.finalByte,
    // required this.intermediates,
  });

  int? prefix;

  /// [seance fork] Whether the sequence carried any intermediate byte.
  var hasIntermediates = false;

  List<int> params;

  int finalByte;
  // final List<int> intermediates;

  @override
  String toString() {
    return params.join(';') + String.fromCharCode(finalByte);
  }
}

/// Function that handles a complete two-rune ESC sequence.
typedef _EscHandler = void Function();

typedef _SbcHandler = void Function();

typedef _CsiHandler = void Function();
