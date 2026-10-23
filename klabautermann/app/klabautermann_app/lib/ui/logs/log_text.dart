import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show FamilyHue, FamilyPalette, contrastRatio, legibleOn;
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:planchette_core/planchette_core.dart' show TextMatch;

import 'log_level.dart';
import 'log_tokens.dart';
import 'log_view_controller.dart' show ContainerLine;

/// The contrast every span of log text keeps on its background: WCAG's
/// 4.5:1 for body text (A11Y-04). SGR colours can ask for text that matches
/// its background (`30;40`, equal RGB values); the viewer lifts such text
/// to this floor instead (03 §10.8).
const double logTextMinContrast = 4.5;

/// The highest code unit counted as one advance wide: Latin-1, so all
/// ASCII.
const int _maxNarrowUnit = 0xff;

const int _tab = 0x09;

/// What separates a cut line from its note.
const String _noteGap = ' ';

/// Faint text is the foreground mixed this far toward its background
/// before the contrast floor applies.
const double _faintMix = 0.35;

/// How much of the family's yellow, and of its orange for the current
/// match, a search match's background mixes into the log background.
const double _matchMix = 0.3;
const double _currentMatchMix = 0.55;

/// The most resolved styles and colours a palette keeps. Lines can name
/// any of 16.7 million RGB colours, so the caches start over past this.
const int _cacheLimit = 1024;

/// The colours a log view draws with, and the text styles it resolves for
/// a line's SGR styles and level (03 §10.8).
///
/// SGR palette entries 1 to 6 take the family's glyph hues (red, green,
/// yellow, blue, purple for magenta, cyan), and their bright forms 9 to 14
/// the same hues; 8 (bright black) is the family's graphite, and 0, 7 and
/// 15 stay black, light grey and white. 16 to 255 are the xterm colour cube
/// and grey ramp; RGB values are drawn as given.
/// Every foreground is then held to [logTextMinContrast] on the background
/// it is drawn over.
final class LogPalette {
  LogPalette._({
    required this.background,
    required this._foreground,
    required this._secondary,
    required this._error,
    required this._warning,
    required this._match,
    required this._currentMatch,
    required List<Color> ansi,
    required Map<LogTokenKind, Color> tokens,
  }) : assert(ansi.length == 16),
       _ansi = List.unmodifiable(ansi),
       _tokens = Map.unmodifiable(tokens);

  /// The palette of [theme]: its lowest container as the background, its
  /// text colours, and the family's red and yellow for errors and
  /// warnings.
  factory LogPalette.fromTheme(ThemeData theme) {
    final family =
        theme.extension<FamilyPalette>() ??
        FamilyPalette.forBrightness(theme.brightness);
    final scheme = theme.colorScheme;
    final hues = [
      FamilyHue.red,
      FamilyHue.green,
      FamilyHue.yellow,
      FamilyHue.blue,
      FamilyHue.purple,
      FamilyHue.cyan,
    ].map(family.glyph);
    return LogPalette._(
      background: scheme.surfaceContainerLowest,
      foreground: scheme.onSurface,
      secondary: scheme.onSurfaceVariant,
      error: family.glyph(FamilyHue.red),
      warning: family.glyph(FamilyHue.yellow),
      match: Color.lerp(
        scheme.surfaceContainerLowest,
        family.glyph(FamilyHue.yellow),
        _matchMix,
      )!,
      currentMatch: Color.lerp(
        scheme.surfaceContainerLowest,
        family.glyph(FamilyHue.orange),
        _currentMatchMix,
      )!,
      ansi: [
        const Color(0xFF000000),
        ...hues,
        const Color(0xFFE5E5E5),
        family.glyph(FamilyHue.graphite),
        ...hues,
        const Color(0xFFFFFFFF),
      ],
      tokens: {
        LogTokenKind.url: family.glyph(FamilyHue.blue),
        LogTokenKind.ipAddress: family.glyph(FamilyHue.cyan),
        LogTokenKind.httpSuccess: family.glyph(FamilyHue.green),
        LogTokenKind.httpRedirect: family.glyph(FamilyHue.purple),
        LogTokenKind.httpClientError: family.glyph(FamilyHue.orange),
        LogTokenKind.httpServerError: family.glyph(FamilyHue.red),
      },
    );
  }

  final Color background;
  final Color _foreground;

  /// Markers (a cut line's note, dropped lines) and debug lines.
  final Color _secondary;
  final Color _error;
  final Color _warning;
  final Color _match;
  final Color _currentMatch;
  final List<Color> _ansi;
  final Map<LogTokenKind, Color> _tokens;

  final _styles = <(SgrStyle, LogLevel?), TextStyle>{};
  final _legibleCache = <(Color, Color), Color>{};

  /// The text colour of a line at [level] where its SGR styles set none.
  Color levelColor(LogLevel? level) => _legible(switch (level) {
    LogLevel.error => _error,
    LogLevel.warning => _warning,
    LogLevel.debug => _secondary,
    LogLevel.info || null => _foreground,
  }, background);

  /// The style of a cut line's note and of a dropped-lines record.
  late final TextStyle markerStyle = TextStyle(
    color: _legible(_secondary, background),
    fontStyle: FontStyle.italic,
  );

  /// The style of a journal row's unit and PID, and of a container
  /// row's time and `stdout` mark.
  late final TextStyle sourceStyle = TextStyle(
    color: _legible(_secondary, background),
  );

  /// The style of a container row's `stderr` mark (CTX-01): the error
  /// colour, beside the mark's own word, so the stream never shows by
  /// colour alone. The line itself keeps its level's colour, since a
  /// program may write anything to stderr.
  late final TextStyle stderrStyle = TextStyle(
    color: _legible(_error, background),
  );

  /// [style] inside a search match (LOG-05): the match background, with
  /// the text held to [logTextMinContrast] on it. Only the current match
  /// is underlined, whatever the line's SGR underline, so it differs by
  /// more than colour; a strikethrough stays.
  TextStyle matchStyle(TextStyle style, {required bool current}) {
    final background = current ? _currentMatch : _match;
    final struck =
        style.decoration?.contains(TextDecoration.lineThrough) ?? false;
    return style.copyWith(
      backgroundColor: background,
      color: _legible(style.color ?? _foreground, background),
      decoration: TextDecoration.combine([
        if (struck) TextDecoration.lineThrough,
        if (current) TextDecoration.underline,
      ]),
    );
  }

  /// [style] with LOG-07's colour for a [kind] token, held to
  /// [logTextMinContrast] on what it is drawn over.
  TextStyle tokenStyle(TextStyle style, LogTokenKind kind) => style.copyWith(
    color: _legible(_tokens[kind]!, style.backgroundColor ?? background),
  );

  /// The colours and attributes of [style] on a line at [level]: the
  /// level's colour stands in for the default foreground.
  TextStyle styleFor(SgrStyle style, LogLevel? level) {
    if (_styles.length >= _cacheLimit) _styles.clear();
    return _styles.putIfAbsent((style, level), () => _resolve(style, level));
  }

  /// [color], or the colour nearest it toward black or white (whichever
  /// [background] favours) that keeps [logTextMinContrast] on [background].
  Color _legible(Color color, Color background) {
    if (_legibleCache.length >= _cacheLimit) _legibleCache.clear();
    return _legibleCache.putIfAbsent((color, background), () {
      if (contrastRatio(color, background) >= logTextMinContrast) {
        return color;
      }

      // The better of black and white clears the floor on any background
      // (4.58:1 at worst), and moving toward it crosses the floor only
      // once, so a bisection finds the smallest change.
      final target = legibleOn(background);
      var low = 0.0;
      var high = 1.0;
      for (var i = 0; i < 12; i++) {
        final mid = (low + high) / 2;
        final candidate = Color.lerp(color, target, mid)!;
        if (contrastRatio(candidate, background) >= logTextMinContrast) {
          high = mid;
        } else {
          low = mid;
        }
      }
      return Color.lerp(color, target, high)!;
    });
  }

  TextStyle _resolve(SgrStyle style, LogLevel? level) {
    var foreground = _color(style.foreground) ?? levelColor(level);
    var background = _color(style.background);
    if (style.inverse) {
      (foreground, background) = (background ?? this.background, foreground);
    }

    final drawnOver = background ?? this.background;
    if (style.faint) foreground = Color.lerp(foreground, drawnOver, _faintMix)!;

    return TextStyle(
      color: _legible(foreground, drawnOver),
      backgroundColor: background,
      fontWeight: style.bold ? FontWeight.bold : null,
      fontStyle: style.italic ? FontStyle.italic : null,
      decoration: TextDecoration.combine([
        if (style.underline) TextDecoration.underline,
        if (style.strikethrough) TextDecoration.lineThrough,
      ]),
    );
  }

  Color? _color(SgrColor? color) => switch (color) {
    null => null,
    SgrPaletteColor(:final index) when index < 16 => _ansi[index],
    SgrPaletteColor(:final index) => _xterm256(index),
    SgrRgbColor(:final red, :final green, :final blue) => Color.fromARGB(
      0xff,
      red,
      green,
      blue,
    ),
  };

  /// xterm's colours 16 to 255: a 6x6x6 cube, then a 24-step grey ramp.
  static Color _xterm256(int index) {
    if (index >= 232) {
      final grey = 8 + 10 * (index - 232);
      return Color.fromARGB(0xff, grey, grey, grey);
    }

    final cube = index - 16;
    int level(int step) => step == 0 ? 0 : 55 + 40 * step;
    return Color.fromARGB(
      0xff,
      level(cube ~/ 36),
      level(cube ~/ 6 % 6),
      level(cube % 6),
    );
  }
}

/// What a journal MESSAGE's newline shows as: a return mark, then a line
/// separator, which breaks the row with wrap on. Without wrap the row
/// ends at the separator with no ellipsis, so the mark tells that more
/// lines follow.
const String _messageNewline = '\u23ce\u2028';

/// How many characters a container row's time takes: `2026-10-17
/// 14:30:05`, in the device's zone.
const int _containerTimeWidth = 19;

/// A container row's time (CTX-01) in the device's zone, to the second,
/// or as many spaces when the line carried none, so the marks line up.
String _containerTime(DateTime? at) {
  if (at == null) return ' ' * _containerTimeWidth;

  final iso = at.toLocal().toIso8601String();
  return '${iso.substring(0, 10)} ${iso.substring(11, _containerTimeWidth)}';
}

/// How many characters a [container] row's time and stream mark take
/// before its text, the gaps included.
int logContainerSourceLength(ContainerLine container) =>
    _containerTimeWidth + container.stream.name.length + 2;

/// The text of [line]'s row before styling: a journal line's unit and PID
/// (LOG-01) or a [container] line's time and stream (CTX-01), then what
/// `parseSgr` leaves of its text, with a MESSAGE's newlines shown instead
/// of dropped.
({String source, SgrText body}) _rowParts(
  LogLine line,
  ContainerLine? container,
) {
  if (container != null) {
    return (
      source: '${_containerTime(container.at)} ${container.stream.name} ',
      body: parseSgr(line.text),
    );
  }

  final journal = line.journal;
  if (journal == null) return (source: '', body: parseSgr(line.text));

  final pid = journal.pid == null ? '' : '[${journal.pid}]';
  final source = '${journal.source ?? ''}$pid';
  return (
    source: source.isEmpty ? '' : '$source: ',
    body: parseSgr(line.text.replaceAll('\n', _messageNewline)),
  );
}

/// The visible text of [line]'s row without its note: what a search reads
/// and the width the view measures. A [container] line's row starts with
/// its time and stream.
String logRowText(LogLine line, {ContainerLine? container}) {
  final (:source, :body) = _rowParts(line, container);
  return source + body.text;
}

/// [line] as a log view draws it: a journal line's unit and PID, or a
/// [container] line's time and stream mark, its visible text styled by
/// [palette], then [note] (a cut line's, or a journal MESSAGE's that was
/// not sent). A screen reader hears [streamLabel] for the stream mark.
/// [matches] are search matches in [logRowText], in order; the one at
/// [currentMatch] is the current one.
TextSpan logLineSpan(
  LogLine line, {
  required LogPalette palette,
  required TextStyle base,
  LogLevel? level,
  String? note,
  ContainerLine? container,
  String? streamLabel,
  List<TextMatch> matches = const [],
  int? currentMatch,
}) {
  final (:source, :body) = _rowParts(line, container);
  final text = source + body.text;
  // A container row's stream mark sits between its time and the gap
  // before the text.
  final mark = container == null
      ? null
      : (
          start: _containerTimeWidth + 1,
          end: _containerTimeWidth + 1 + container.stream.name.length,
        );
  // Each run: its range, its style, and what a screen reader hears for
  // it instead of its text.
  final runs = <(int, int, TextStyle, String?)>[
    if (mark != null) ...[
      (0, mark.start, palette.sourceStyle, null),
      (
        mark.start,
        mark.end,
        container!.stream == ContainerLogStream.stderr
            ? palette.stderrStyle
            : palette.sourceStyle,
        streamLabel,
      ),
      (mark.end, source.length, palette.sourceStyle, null),
    ] else if (source.isNotEmpty)
      (0, source.length, palette.sourceStyle, null),
  ];
  // LOG-07's tokens colour only text whose SGR styles set no colour: a
  // program's own colours win.
  final tokens = logTokens(body.text);
  var token = 0;
  void run(int start, int end, SgrStyle style) {
    if (start == end) return;
    final resolved = palette.styleFor(style, level);
    void add(int from, int to, TextStyle style) {
      if (from < to) {
        runs.add((source.length + from, source.length + to, style, null));
      }
    }

    if (style.foreground != null || style.inverse) {
      add(start, end, resolved);
      return;
    }
    var at = start;
    while (token < tokens.length && tokens[token].start < end) {
      final (start: from, end: to, :kind) = tokens[token];
      if (to <= at) {
        token++;
        continue;
      }
      add(at, math.max(at, from), resolved);
      final stop = math.min(to, end);
      add(math.max(at, from), stop, palette.tokenStyle(resolved, kind));
      at = stop;
      if (to > end) break;
      token++;
    }
    add(at, end, resolved);
  }

  var at = 0;
  for (final span in body.spans) {
    run(at, span.start, SgrStyle.plain);
    run(span.start, span.end, span.style);
    at = span.end;
  }
  run(at, body.text.length, SgrStyle.plain);

  // Each run is split where a match starts or ends inside it.
  final children = <InlineSpan>[];
  var next = 0;
  for (final (start, end, style, label) in runs) {
    var from = start;
    // A run a match splits speaks its label once, from its first piece.
    String? spoken() {
      if (label == null) return null;
      return from == start ? label : '';
    }

    while (from < end) {
      while (next < matches.length && matches[next].end <= from) {
        next++;
      }
      final match = next < matches.length ? matches[next] : null;
      if (match == null || match.start >= end) {
        children.add(
          TextSpan(
            text: text.substring(from, end),
            style: style,
            semanticsLabel: spoken(),
          ),
        );
        break;
      }

      if (match.start > from) {
        children.add(
          TextSpan(
            text: text.substring(from, match.start),
            style: style,
            semanticsLabel: spoken(),
          ),
        );
        from = match.start;
      }
      final stop = math.min(match.end, end);
      children.add(
        TextSpan(
          text: text.substring(from, stop),
          style: palette.matchStyle(style, current: next == currentMatch),
          semanticsLabel: spoken(),
        ),
      );
      from = stop;
    }
  }
  if (note != null) {
    children.add(TextSpan(text: _noteGap + note, style: palette.markerStyle));
  }

  return TextSpan(style: base, children: children);
}

/// An upper bound of the width [text] takes once styled, in Latin-1 glyph
/// advances of a monospace font, when every code unit is Latin-1: one a
/// unit, two for a tab. Null when any unit is not: a fallback font may
/// draw its glyph wider than any fixed count of advances (an emoji, a
/// three-em dash), and a line or paragraph separator breaks the row. It
/// lets the view size most rows without laying their lines out.
int? logTextCells(String text) {
  var cells = 0;
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit > _maxNarrowUnit) return null;
    cells += unit == _tab ? 2 : 1;
  }
  return cells;
}
