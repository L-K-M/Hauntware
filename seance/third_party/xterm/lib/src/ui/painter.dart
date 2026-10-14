import 'dart:ui';
import 'package:flutter/painting.dart';
import 'package:quiver/collection.dart';

import 'package:xterm/src/ui/palette_builder.dart';
import 'package:xterm/src/ui/paragraph_cache.dart';
import 'package:xterm/xterm.dart';

/// Encapsulates the logic for painting various terminal elements.
class TerminalPainter {
  TerminalPainter({
    required TerminalTheme theme,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
  })  : _textStyle = textStyle,
        _theme = theme,
        _textScaler = textScaler;

  /// A lookup table from terminal colors to Flutter colors.
  late var _colorPalette = PaletteBuilder(_theme).build();

  /// Size of each character in the terminal.
  late var _cellSize = _measureCharSize();

  /// The cached for cells in the terminal. Should be cleared when the same
  /// cell no longer produces the same visual output. For example, when
  /// [_textStyle] is changed, or when the system font changes.
  final _paragraphCache = ParagraphCache(10240);

  /// [seance fork] Laid-out runs for ligature drawing (see [paintLine]),
  /// keyed by the run's text and painted style exactly: runs vary far more
  /// than single glyphs, so an int hash like [_paragraphCache]'s would
  /// collide. Cleared wherever that cache is.
  final _runCache = LruMap<String, _RunLayout>(maximumSize: _runCacheSize);

  static const _runCacheSize = 4096;

  /// [seance fork] The longest run shaped as one. Ligatures span two to
  /// four characters; the cap bounds the layout a long unbroken token
  /// (a hash, base64) costs, at the price of a ligature cut at the seam.
  static const _maxRunLength = 64;

  /// [seance fork] How far, in logical pixels, a run's laid-out width may
  /// stray from its cells' before it is drawn cell by cell instead. A
  /// fixed-pitch face lands within rounding; a proportional one or a
  /// fallback glyph does not, and would drift off the grid.
  static const _runWidthTolerance = 0.5;

  TerminalStyle get textStyle => _textStyle;
  TerminalStyle _textStyle;
  set textStyle(TerminalStyle value) {
    if (value == _textStyle) return;
    _textStyle = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
    _runCache.clear();
  }

  TextScaler get textScaler => _textScaler;
  TextScaler _textScaler = TextScaler.linear(1.0);
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
    _runCache.clear();
  }

  TerminalTheme get theme => _theme;
  TerminalTheme _theme;
  set theme(TerminalTheme value) {
    if (value == _theme) return;
    _theme = value;
    _colorPalette = PaletteBuilder(value).build();
    _paragraphCache.clear();
    _runCache.clear();
  }

  Size _measureCharSize() {
    const test = 'mmmmmmmmmm';

    final textStyle = _textStyle.toTextStyle();
    final builder = ParagraphBuilder(textStyle.getParagraphStyle());
    builder.pushStyle(
      textStyle.getTextStyle(textScaler: _textScaler),
    );
    builder.addText(test);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: double.infinity));

    final result = Size(
      paragraph.maxIntrinsicWidth / test.length,
      paragraph.height,
    );

    paragraph.dispose();
    return result;
  }

  /// The size of each character in the terminal.
  Size get cellSize => _cellSize;

  /// When the set of font available to the system changes, call this method to
  /// clear cached state related to font rendering.
  void clearFontCache() {
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
    _runCache.clear();
  }

  /// Paints the cursor based on the current cursor type.
  void paintCursor(
    Canvas canvas,
    Offset offset, {
    required TerminalCursorType cursorType,
    bool hasFocus = true,
  }) {
    final paint = Paint()
      ..color = _theme.cursor
      ..strokeWidth = 1;

    if (!hasFocus) {
      paint.style = PaintingStyle.stroke;
      canvas.drawRect(offset & _cellSize, paint);
      return;
    }

    switch (cursorType) {
      case TerminalCursorType.block:
        paint.style = PaintingStyle.fill;
        canvas.drawRect(offset & _cellSize, paint);
        return;
      // [seance fork] Both on the cursor's row: upstream dropped offset.dy
      // and drew them at the top of the view, wherever the cursor was.
      case TerminalCursorType.underline:
        final y = offset.dy + _cellSize.height - 1;
        return canvas.drawLine(
          Offset(offset.dx, y),
          Offset(offset.dx + _cellSize.width, y),
          paint,
        );
      case TerminalCursorType.verticalBar:
        return canvas.drawLine(
          offset,
          Offset(offset.dx, offset.dy + _cellSize.height),
          paint,
        );
    }
  }

  @pragma('vm:prefer-inline')
  void paintHighlight(Canvas canvas, Offset offset, int length, Color color) {
    final endOffset =
        offset.translate(length * _cellSize.width, _cellSize.height);

    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    canvas.drawRect(
      Rect.fromPoints(offset, endOffset),
      paint,
    );
  }

  /// Paints [line] to [canvas] at [offset]. The x offset of [offset] is usually
  /// 0, and the y offset is the top of the line.
  ///
  /// [seance fork] Cells inside one of [recolor]'s spans are painted in that
  /// span's colours instead of their own.
  ///
  /// [seance fork] With [TerminalStyle.ligatures] on, a run of neighbouring
  /// cells that can join ([_joinable]) and share their painted style is
  /// shaped as one paragraph, so the font can draw `->` as an arrow. The
  /// fonts that ligate this way keep every character one cell wide, so the
  /// run lands on the grid; one that does not is drawn cell by cell:
  ///
  ///     cells   | a |   | - | > |   | b |
  ///     drawn     a       ->(one run)  b
  void paintLine(
    Canvas canvas,
    Offset offset,
    BufferLine line, [
    List<CellRecolor>? recolor,
  ]) {
    final cellData = CellData.empty();
    final cellWidth = _cellSize.width;
    final joinRuns = _textStyle.ligatures == TerminalLigatures.on;

    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);
      if (recolor != null) _recolorCell(cellData, i, recolor);

      if (joinRuns && _joinable(cellData)) {
        final end = _paintRun(canvas, offset, line, i, cellData, recolor);
        if (end != null) {
          i = end - 1;
          continue;
        }
      }

      final charWidth = cellData.content >> CellContent.widthShift;
      final cellOffset = offset.translate(i * cellWidth, 0);

      paintCell(canvas, cellOffset, cellData);

      if (charWidth == 2) {
        i++;
      }
    }
  }

  /// [seance fork] Whether [cell] can be part of a ligature run: printable
  /// ASCII other than the space, one cell wide. Every ligature the bundled
  /// fonts draw is made of these. Spaces stay out so the underline
  /// workaround in [paintCellForeground] still applies to them; wide,
  /// combining and non-ASCII characters keep the cell-by-cell path.
  @pragma('vm:prefer-inline')
  static bool _joinable(CellData cell) {
    final charCode = cell.content & CellContent.codepointMask;
    final charWidth = cell.content >> CellContent.widthShift;
    return charWidth == 1 && charCode > 0x20 && charCode < 0x7F;
  }

  /// [seance fork] Paints the run of joinable cells that starts at column
  /// [start] (whose data, recoloured, is [first]) and returns the column
  /// after it, or null for a lone cell, which the caller paints. Cells join
  /// while they share colours and painted flags; the hyperlink id in the
  /// attribute word changes nothing on screen and does not split a run. A
  /// run whose shaped width is off the grid is painted cell by cell, whole,
  /// so its tail is not shaped again as a shorter run.
  int? _paintRun(
    Canvas canvas,
    Offset offset,
    BufferLine line,
    int start,
    CellData first,
    List<CellRecolor>? recolor,
  ) {
    final flags = first.flags & CellAttr.styleMask;
    final codes = <int>[first.content & CellContent.codepointMask];
    final next = CellData.empty();
    final limit = (start + _maxRunLength).clamp(0, line.length);
    var end = start + 1;
    for (; end < limit; end++) {
      line.getCellData(end, next);
      if (recolor != null) _recolorCell(next, end, recolor);
      if (!_joinable(next) ||
          next.foreground != first.foreground ||
          next.background != first.background ||
          next.flags & CellAttr.styleMask != flags) {
        break;
      }
      codes.add(next.content & CellContent.codepointMask);
    }
    if (codes.length < 2) return null;

    final text = String.fromCharCodes(codes);
    final key = '${first.foreground}:${first.background}:$flags:$text';
    final layout = _runCache[key] ??= _layoutRun(text, first, codes.length);
    final paragraph = layout.paragraph;
    final cellWidth = _cellSize.width;

    if (paragraph == null) {
      for (var x = start; x < end; x++) {
        line.getCellData(x, next);
        if (recolor != null) _recolorCell(next, x, recolor);
        paintCell(canvas, offset.translate(x * cellWidth, 0), next);
      }
      return end;
    }

    // Backgrounds before the text, all of them: one cell's background
    // painted after the run would cover the glyphs that reach into it.
    for (var x = start; x < end; x++) {
      paintCellBackground(canvas, offset.translate(x * cellWidth, 0), first);
    }
    canvas.drawParagraph(paragraph, offset.translate(start * cellWidth, 0));
    return end;
  }

  /// [seance fork] Shapes [text], [length] cells styled like [cell], or
  /// records that its width is off the grid.
  _RunLayout _layoutRun(String text, CellData cell, int length) {
    // Built as [ParagraphCache.performAndCacheLayout] builds a cell's.
    final style = _foregroundStyle(cell);
    final builder = ParagraphBuilder(style.getParagraphStyle())
      ..pushStyle(style.getTextStyle(textScaler: _textScaler))
      ..addText(text);
    final paragraph = builder.build()
      ..layout(ParagraphConstraints(width: double.infinity));

    final drift = paragraph.maxIntrinsicWidth - length * _cellSize.width;
    if (drift.abs() <= _runWidthTolerance) return _RunLayout(paragraph);

    paragraph.dispose();
    return const _RunLayout(null);
  }

  /// [seance fork] Gives [cellData] (the cell at column [x]) the colours of
  /// the span covering it, as an RGB background and foreground. Spans come in
  /// highlight creation order and the newest wins, as overlay highlights,
  /// painted in that order, would show it. Clearing
  /// inverse keeps the pair the right way round. Going through the cell's
  /// own colour words rather than a side channel keeps the paragraph cache
  /// honest: its key already hashes them.
  @pragma('vm:prefer-inline')
  void _recolorCell(CellData cellData, int x, List<CellRecolor> recolor) {
    for (final span in recolor.reversed) {
      if (x < span.start || x >= span.end) continue;
      cellData.background = CellColor.rgb | (span.background & CellColor.valueMask);
      cellData.foreground = CellColor.rgb | (span.foreground & CellColor.valueMask);
      cellData.flags &= ~CellFlags.inverse;
      return;
    }
  }

  @pragma('vm:prefer-inline')
  void paintCell(Canvas canvas, Offset offset, CellData cellData) {
    paintCellBackground(canvas, offset, cellData);
    paintCellForeground(canvas, offset, cellData);
  }

  /// Paints the character in the cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellForeground(Canvas canvas, Offset offset, CellData cellData) {
    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode == 0) return;

    final cacheKey = cellData.getHash() ^ _textScaler.hashCode;
    var paragraph = _paragraphCache.getLayoutFromCache(cacheKey);

    if (paragraph == null) {
      final cellFlags = cellData.flags;
      final style = _foregroundStyle(cellData);

      // Flutter does not draw an underline below a space which is not between
      // other regular characters. As only single characters are drawn, this
      // will never produce an underline below a space in the terminal. As a
      // workaround the regular space CodePoint 0x20 is replaced with
      // the CodePoint 0xA0. This is a non breaking space and a underline can be
      // drawn below it.
      var char = String.fromCharCode(charCode);
      if (cellFlags & CellFlags.underline != 0 && charCode == 0x20) {
        char = String.fromCharCode(0xA0);
      }

      paragraph = _paragraphCache.performAndCacheLayout(
        char,
        style,
        _textScaler,
        cacheKey,
      );
    }

    canvas.drawParagraph(paragraph, offset);
  }

  /// The text style [cellData]'s character is drawn in: its colour (the
  /// background's when inverse, halved when faint) and its weight, slant and
  /// underline. [seance fork] Factored out of [paintCellForeground] so the
  /// ligature runs style their text the same way.
  TextStyle _foregroundStyle(CellData cellData) {
    final cellFlags = cellData.flags;

    var color = cellFlags & CellFlags.inverse == 0
        ? resolveForegroundColor(cellData.foreground)
        : resolveBackgroundColor(cellData.background);

    if (cellData.flags & CellFlags.faint != 0) {
      color = color.withOpacity(0.5);
    }

    return _textStyle.toTextStyle(
      color: color,
      bold: cellFlags & CellFlags.bold != 0,
      italic: cellFlags & CellFlags.italic != 0,
      underline: cellFlags & CellFlags.underline != 0,
    );
  }

  /// Paints the background of a cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellBackground(Canvas canvas, Offset offset, CellData cellData) {
    late Color color;
    final colorType = cellData.background & CellColor.typeMask;

    if (cellData.flags & CellFlags.inverse != 0) {
      color = resolveForegroundColor(cellData.foreground);
    } else if (colorType == CellColor.normal) {
      return;
    } else {
      color = resolveBackgroundColor(cellData.background);
    }

    final paint = Paint()..color = color;
    final doubleWidth = cellData.content >> CellContent.widthShift == 2;
    final widthScale = doubleWidth ? 2 : 1;
    final size = Size(_cellSize.width * widthScale + 1, _cellSize.height);
    canvas.drawRect(offset & size, paint);
  }

  /// Get the effective foreground color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveForegroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.foreground;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }

  /// Get the effective background color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveBackgroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.background;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }
}

/// [seance fork] Columns [start] to [end] (exclusive) of one line, painted
/// with [background] under the text and [foreground] for it, both as
/// 0xAARRGGBB with the alpha ignored: the cell colours they stand in for are
/// opaque.
class CellRecolor {
  const CellRecolor(this.start, this.end, this.background, this.foreground);

  final int start;
  final int end;
  final int background;
  final int foreground;
}

/// [seance fork] A shaped ligature run, or none when its width was off the
/// grid; caching the refusal spares re-shaping it every frame.
class _RunLayout {
  const _RunLayout(this.paragraph);

  final Paragraph? paragraph;
}
