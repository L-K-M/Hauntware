import 'editor_syntax.dart';

/// The pair a closer completes, and the closer itself, keyed by opener.
const Map<String, String> _bracketPairs = {
  '(': ')',
  '[': ']',
  '{': '}',
  '"': '"',
  "'": "'",
  '`': '`',
};

/// The characters that should move over a pair already under the caret rather
/// than insert a second one.
const Set<String> _closers = {')', ']', '}', '"', "'", '`'};

/// Whether [language] is one where brackets are syntax worth pairing. Prose is
/// not: pairing in a Markdown paragraph is noise rather than help.
bool pairsBrackets(SyntaxLanguage? language) =>
    language != null && language.id != 'markdown';

/// Whether typing [character] at [offset] should open a pair.
///
/// The character already under the caret disqualifies it: typing the closer of
/// a pair the user just made should move over that pair, which is
/// [movesOverCloser]'s job, not a second insertion.
bool opensPair(
  SyntaxLanguage? language,
  String character,
  String text,
  int offset,
) {
  if (!pairsBrackets(language)) return false;
  if (!_bracketPairs.containsKey(character)) return false;
  return offset >= text.length || text[offset] != character;
}

/// Whether [character] should move over the pair it closes.
///
/// Only the matching closer qualifies. Typing `)` between `(` and something else
/// is a real bracket, not a request to skip.
bool movesOverCloser(
  SyntaxLanguage? language,
  String character,
  String text,
  int offset,
) {
  // The same gate as `opensPair`. In prose a brace is a character, and stepping
  // over one would delete what the user just typed.
  if (!pairsBrackets(language)) return false;
  if (!_closers.contains(character) || offset >= text.length) return false;
  if (text[offset] != character) return false;
  return _isOpenerFor(character, text, offset);
}

bool _isOpenerFor(String closer, String text, int offset) {
  for (final pair in _bracketPairs.entries) {
    if (pair.value != closer) continue;
    // Either an opener sits directly before the pair, or the pair is a quote,
    // whose closing half is its own.
    if (offset == 0 || text[offset - 1] == pair.key) return true;
  }
  return false;
}

/// The closer that completes [opener], or null.
String? closerFor(String opener) => _bracketPairs[opener];
