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
  // A quote typed straight after a word character is an apostrophe or a
  // possessive, never an opening quote — "don'" gains no stray second quote.
  if (_isSelfPair(character) && offset > 0 && _isWordChar(text[offset - 1])) {
    return false;
  }
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
    // A quote's closing half is its own: typing it over its twin always steps
    // over. Offset 0 can hold no opener, yet the same-twin rule still applies,
    // so a quote at the buffer's edge is covered here too.
    if (_isSelfPair(closer)) return true;
    if (offset > 0 && text[offset - 1] == pair.key) return true;
  }
  return false;
}

bool _isSelfPair(String character) => _bracketPairs[character] == character;

/// A letter, digit, or underscore — what a closing quote leans on when it is
/// really an apostrophe.
final _wordChar = RegExp(r'[\p{L}\p{N}_]', unicode: true);

bool _isWordChar(String character) => _wordChar.hasMatch(character);

/// The closer that completes [opener], or null.
String? closerFor(String opener) => _bracketPairs[opener];
