import 'editor_syntax.dart';

/// A bracket and its partner, as offsets of the two bracket characters.
final class BracketMatch {
  const BracketMatch(this.bracket, this.partner);

  /// The bracket beside the caret.
  final int bracket;

  /// The bracket that closes or opens it.
  final int partner;

  @override
  bool operator ==(Object other) =>
      other is BracketMatch &&
      other.bracket == bracket &&
      other.partner == partner;

  @override
  int get hashCode => Object.hash(bracket, partner);

  @override
  String toString() => 'BracketMatch($bracket, $partner)';
}

/// Where Go to Matching Bracket moves a caret.
final class BracketJump {
  const BracketJump(this.offset, this.bracket);

  /// The new caret offset.
  final int offset;

  /// The bracket the caret now sits beside. Passing it back as `preferred`
  /// makes the next jump return, even when the caret also touches another
  /// bracket there, as between the two parentheses of `))`.
  final int bracket;

  @override
  bool operator ==(Object other) =>
      other is BracketJump &&
      other.offset == offset &&
      other.bracket == bracket;

  @override
  int get hashCode => Object.hash(offset, bracket);

  @override
  String toString() => 'BracketJump($offset, $bracket)';
}

const _closerOf = {0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D}; // ( [ {
const _openerOf = {0x29: 0x28, 0x5D: 0x5B, 0x7D: 0x7B}; // ) ] }

/// The partner of the bracket beside [caret]: [preferred] first when it
/// touches the caret, then the bracket before the caret, then the one after,
/// so the partner of a closer just typed is the one found. Null when neither
/// neighbour is a bracket with a partner.
///
/// Brackets pair with their own type only, so a stray `]` does not break a
/// pair of parentheses. Brackets in string and comment [tokens] are not code:
/// code skips them, and a bracket inside one pairs only within that token,
/// so `"("` never pairs with code but a parenthesis in a comment still
/// finds its partner there. Every other token, such as a Rust attribute or a
/// shell `${name}`, holds real brackets.
BracketMatch? matchBracket(
  String text,
  int caret,
  List<SyntaxToken> tokens, {
  int? preferred,
}) {
  RangeError.checkValueInInterval(caret, 0, text.length, 'caret');
  final candidates = [
    if (preferred == caret - 1 || preferred == caret) preferred!,
    caret - 1,
    caret,
  ];
  for (final bracket in candidates) {
    if (bracket < 0 || bracket >= text.length) continue;
    final partner = _partnerOf(text, bracket, tokens);
    if (partner != null) return BracketMatch(bracket, partner);
  }
  return null;
}

/// Where Go to Matching Bracket moves a caret at [caret].
///
/// Beside a bracket, the caret moves to the same side of its partner: from
/// after `{` to after its `}`, from before `(` to before its `)`, so a second
/// jump returns. Anywhere else it moves to before the closing bracket of the
/// innermost pair around it. Null when there is nowhere to go. See
/// [matchBracket] for [tokens] and [preferred].
BracketJump? bracketJump(
  String text,
  int caret,
  List<SyntaxToken> tokens, {
  int? preferred,
}) {
  RangeError.checkValueInInterval(caret, 0, text.length, 'caret');
  final match = matchBracket(text, caret, tokens, preferred: preferred);
  if (match != null) {
    final after = match.bracket == caret - 1;
    return BracketJump(
      after ? match.partner + 1 : match.partner,
      match.partner,
    );
  }
  final closer = _enclosingCloser(text, caret, tokens);
  return closer == null ? null : BracketJump(closer, closer);
}

int? _partnerOf(String text, int bracket, List<SyntaxToken> tokens) {
  final unit = text.codeUnitAt(bracket);
  final closer = _closerOf[unit];
  final opener = _openerOf[unit];
  if (closer == null && opener == null) return null;
  final region = _Region.around(text, bracket, tokens);
  var depth = 0;
  if (closer != null) {
    return region.forward(bracket + 1, (_, u) {
      if (u == unit) depth++;
      if (u != closer) return false;
      if (depth == 0) return true;
      depth--;
      return false;
    });
  }
  return region.backward(bracket - 1, (_, u) {
    if (u == unit) depth++;
    if (u != opener) return false;
    if (depth == 0) return true;
    depth--;
    return false;
  });
}

/// The closing bracket of the innermost pair around [caret]. An opener
/// without a partner is skipped, so one unclosed `(` does not hide the
/// braces around it. Inside a string or comment, its own pairs come first,
/// then the code around it.
int? _enclosingCloser(String text, int caret, List<SyntaxToken> tokens) {
  final region = _Region.around(text, caret, tokens, strictlyInside: true);
  final inner = _innermostCloser(region, caret, tokens);
  if (inner != null || region.skipsTokens) return inner;
  final code = _Region(text, tokens, 0, text.length, skipsTokens: true);
  return _innermostCloser(code, region.start, tokens);
}

int? _innermostCloser(_Region region, int caret, List<SyntaxToken> tokens) {
  final depth = {for (final opener in _closerOf.keys) opener: 0};
  // Once an opener has no partner, no earlier opener of its type has one:
  // the pairs between them are balanced, so the earlier one's search would
  // pass the same unclosed bracket. Skipping them keeps a run of unclosed
  // brackets from costing a scan each.
  final unclosed = <int>{};
  int? closer;
  region.backward(caret - 1, (i, u) {
    final opener = _openerOf[u];
    if (opener != null) {
      depth[opener] = depth[opener]! + 1;
      return false;
    }
    final open = depth[u];
    if (open == null) return false;
    if (open > 0) {
      depth[u] = open - 1;
      return false;
    }
    if (unclosed.contains(u)) return false;
    closer = _partnerOf(region.text, i, tokens);
    if (closer == null) unclosed.add(u);
    return closer != null;
  });
  return closer;
}

/// The stretch of text a bracket pairs within: the string or comment token
/// holding [offset], or else the whole text with those tokens skipped.
final class _Region {
  _Region(
    this.text,
    this.tokens,
    this.start,
    this.end, {
    required this.skipsTokens,
  });

  factory _Region.around(
    String text,
    int offset,
    List<SyntaxToken> tokens, {
    bool strictlyInside = false,
  }) {
    // A caret at a token's first or last edge is outside it; a bracket
    // character at its first offset is inside.
    final index = _lastStartingAtOrBefore(tokens, offset);
    if (index >= 0) {
      final token = tokens[index];
      final inside = strictlyInside
          ? token.start < offset && offset < token.end
          : offset < token.end;
      if (inside && _isText(token)) {
        return _Region(
          text,
          const [],
          token.start,
          token.end.clamp(0, text.length),
          skipsTokens: false,
        );
      }
    }
    return _Region(text, tokens, 0, text.length, skipsTokens: true);
  }

  final String text;
  final List<SyntaxToken> tokens;
  final int start;
  final int end;
  final bool skipsTokens;

  /// The first offset from [from] up to [end] whose code unit [found]
  /// accepts, skipping string and comment tokens outside them.
  int? forward(int from, bool Function(int offset, int unit) found) {
    var t = skipsTokens ? _lastStartingAtOrBefore(tokens, from) : -1;
    if (t < 0) t = 0;
    for (var i = from; i < end; i++) {
      if (skipsTokens) {
        while (t < tokens.length && tokens[t].end <= i) {
          t++;
        }
        if (t < tokens.length && tokens[t].start <= i && _isText(tokens[t])) {
          i = tokens[t].end - 1;
          continue;
        }
      }
      if (found(i, text.codeUnitAt(i))) return i;
    }
    return null;
  }

  /// Like [forward], from [from] down to [start].
  int? backward(int from, bool Function(int offset, int unit) found) {
    var t = skipsTokens ? _lastStartingAtOrBefore(tokens, from) : -1;
    for (var i = from; i >= start; i--) {
      if (skipsTokens) {
        while (t >= 0 && tokens[t].start > i) {
          t--;
        }
        if (t >= 0 && tokens[t].end > i && _isText(tokens[t])) {
          i = tokens[t].start;
          continue;
        }
      }
      if (found(i, text.codeUnitAt(i))) return i;
    }
    return null;
  }
}

bool _isText(SyntaxToken token) =>
    token.type == SyntaxTokenType.string ||
    token.type == SyntaxTokenType.comment;

/// Index of the last token starting at or before [offset], or -1.
int _lastStartingAtOrBefore(List<SyntaxToken> tokens, int offset) {
  var lo = 0;
  var hi = tokens.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (tokens[mid].start <= offset) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo - 1;
}
