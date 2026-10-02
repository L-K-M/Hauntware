import 'package:unorm_dart/unorm_dart.dart' as unorm;

// Unicode normalization and ASCII transliteration helpers for the Clean Up
// tools. Normalization itself comes from unorm_dart (decision 4 in
// docs/TEXT_TOOLS.md); the table below is the reviewed small Latin map
// Convert to ASCII uses, shared with Strip Diacritics' documented behavior.

/// Composes [input] to NFC (é as one code point).
String unicodeNfc(String input) => unorm.nfc(input);

/// Decomposes [input] to NFD (é as e plus a combining mark).
String unicodeNfd(String input) => unorm.nfd(input);

/// Whether [rune] is a combining mark Strip Diacritics removes: the five
/// combining blocks that hold Latin-script accents and marks. Combining
/// marks outside them (Hebrew points, Arabic harakat, Thai vowels) and
/// U+200C/U+200D are kept, so those scripts and emoji survive intact.
bool isCombiningMark(int rune) =>
    (rune >= 0x0300 && rune <= 0x036f) ||
    (rune >= 0x1ab0 && rune <= 0x1aff) ||
    (rune >= 0x1dc0 && rune <= 0x1dff) ||
    (rune >= 0x20d0 && rune <= 0x20ff) ||
    (rune >= 0xfe20 && rune <= 0xfe2f);

/// Removes combining marks after canonical decomposition, leaving base
/// letters. Characters without a decomposition (ø, ł, emoji, CJK) pass
/// through unchanged, as do scripts that decompose with no removable
/// mark (Hangul syllables to jamo, voiced kana to base plus U+3099 or
/// U+309A): with nothing removed the input comes back byte-for-byte.
String stripDiacritics(String input) {
  final decomposed = unorm.nfd(input);
  final out = StringBuffer();
  var removed = false;
  for (final rune in decomposed.runes) {
    if (isCombiningMark(rune)) {
      removed = true;
    } else {
      out.writeCharCode(rune);
    }
  }
  if (!removed) return input;
  // Recompose so survivors that only traveled through NFD (Hangul jamo
  // beside a stripped accent) return to their composed form.
  return unorm.nfc(out.toString());
}

// The reviewed Latin transliteration table: punctuation look-alikes,
// ligatures and accented Latin with no canonical decomposition. Values
// are pure ASCII. Anything not here and not decomposable to ASCII is
// kept literal and reported, never deleted.
const asciiTable = <int, String>{
  // Curly quotes to straight forms.
  0x2018: "'",
  0x2019: "'",
  0x201a: "'",
  0x201b: "'",
  0x201c: '"',
  0x201d: '"',
  0x201e: '"',
  0x201f: '"',
  0x00ab: '"',
  0x00bb: '"',
  0x2039: "'",
  0x203a: "'",
  0x00b4: "'",
  // Dashes to hyphen-minus.
  0x2010: '-',
  0x2011: '-',
  0x2012: '-',
  0x2013: '-',
  0x2014: '-',
  0x2015: '-',
  0x2212: '-',
  // Ellipsis to three stops.
  0x2026: '...',
  // No-break space to a plain space.
  0x00a0: ' ',
  // Ligatures and Latin look-alikes.
  0xfb00: 'ff',
  0xfb01: 'fi',
  0xfb02: 'fl',
  0xfb03: 'ffi',
  0xfb04: 'ffl',
  0xfb05: 'ft',
  0xfb06: 'st',
  0x00e6: 'ae',
  0x00c6: 'AE',
  0x0153: 'oe',
  0x0152: 'OE',
  0x00df: 'ss',
  0x1e9e: 'SS',
  // Accented Latin with no canonical decomposition.
  0x00f8: 'o',
  0x00d8: 'O',
  0x0142: 'l',
  0x0141: 'L',
  0x0111: 'd',
  0x0110: 'D',
  0x00f0: 'd',
  0x00d0: 'D',
  0x00fe: 'th',
  0x00de: 'TH',
  0x0131: 'i',
  0x014b: 'n',
  0x014a: 'N',
  0x00b5: 'u',
};

/// Transliterates [input] to ASCII: table hits first, then canonical
/// decomposition plus mark removal for accented Latin. Non-ASCII with no
/// equivalent (CJK, emoji, Cyrillic, unmapped symbols) is kept literal.
///
/// Returns the text plus counts: [converted] is input characters replaced,
/// [unmapped] is non-ASCII kept for lack of an equivalent.
({String text, int converted, int unmapped}) transliterateToAscii(
  String input,
) {
  final out = StringBuffer();
  var converted = 0;
  var unmapped = 0;
  // Compose first so a decomposed base plus mark (common from macOS
  // filenames and pasted text) reaches the table and stripping paths as
  // one character. A mark with no precomposed form still has no partner
  // and stays literal, counted unmapped rather than deleted.
  for (final rune in unorm.nfc(input).runes) {
    if (rune <= 0x7f) {
      out.writeCharCode(rune);
      continue;
    }
    final direct = asciiTable[rune];
    if (direct != null) {
      out.write(direct);
      converted++;
      continue;
    }
    final stripped = stripDiacritics(String.fromCharCode(rune));
    if (stripped.isNotEmpty &&
        stripped.runes.every((r) => r <= 0x7f) &&
        stripped != String.fromCharCode(rune)) {
      out.write(stripped);
      converted++;
      continue;
    }
    // A precomposed letter may strip down to a single base that still
    // has a table entry (ǿ U+01FF decomposes to ø plus an acute, then
    // maps to o).
    if (stripped.runes.length == 1) {
      final mapped = asciiTable[stripped.runes.single];
      if (mapped != null) {
        out.write(mapped);
        converted++;
        continue;
      }
    }
    out.writeCharCode(rune);
    unmapped++;
  }
  return (text: out.toString(), converted: converted, unmapped: unmapped);
}
