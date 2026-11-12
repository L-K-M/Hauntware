import 'dart:convert';
import 'dart:typed_data';

import 'text_document.dart';
import 'text_metrics.dart';

/// The character encodings a document is read and written in.
///
/// UTF-8 and byte-order-marked UTF-16 are recognized when a file opens.
/// Latin-1 and Windows-1252 accept almost any bytes, so they are never
/// guessed: a document uses one only when the user chose it.
enum TextEncoding {
  utf8('UTF-8'),
  utf16le('UTF-16 LE'),
  utf16be('UTF-16 BE'),

  /// ISO 8859-1: each byte is the code point of the same value.
  latin1('Latin-1'),

  /// Latin-1 with printable characters in place of most of 0x80 to 0x9F.
  windows1252('Windows-1252');

  const TextEncoding(this.label);

  /// The name status bars and menus show. Not localized: encoding names
  /// are the same in every language.
  final String label;

  /// Whether a file is read in this encoding only when the user asks for
  /// it. Reloading such a document must ask for it again.
  bool get requiresExplicitChoice => this == latin1 || this == windows1252;

  /// Bytes per UTF-16 code unit, or null for UTF-8, whose width varies.
  /// A single-byte encoding counts a unit it cannot hold as one byte; the
  /// save then refuses it.
  int? get bytesPerCodeUnit => switch (this) {
    utf8 => null,
    utf16le || utf16be => 2,
    latin1 || windows1252 => 1,
  };

  /// The byte order mark every file in this encoding starts with. UTF-8's
  /// mark is optional and recorded separately, so it is not counted here.
  int get markLength => this == utf16le || this == utf16be ? 2 : 0;

  /// The encodings a refused file can be reopened with.
  static const reopenChoices = [latin1, windows1252];
}

/// The decoded text of a file's bytes, with the encoding they were read in
/// and whether a leading UTF-8 byte order mark was taken as metadata.
typedef DecodedText = ({String text, TextEncoding encoding, bool utf8Bom});

/// Decodes [bytes] as [encoding], or, when it is null, as byte-order-marked
/// UTF-16 or else strict UTF-8. Every failure names the offending byte.
DecodedText decodeTextBytes(Uint8List bytes, TextEncoding? encoding) {
  if (encoding == null) {
    if (_startsWith(bytes, _utf32LeBom) || _startsWith(bytes, _utf32BeBom)) {
      throw const UnsupportedTextEncodingException(
        'This file starts with a UTF-32 byte order mark. UTF-32 text is not '
        'supported.',
      );
    }
    if (_startsWith(bytes, _utf16LeBom)) {
      encoding = TextEncoding.utf16le;
    } else if (_startsWith(bytes, _utf16BeBom)) {
      encoding = TextEncoding.utf16be;
    } else {
      encoding = TextEncoding.utf8;
    }
  }
  return switch (encoding) {
    TextEncoding.utf8 => _decodeUtf8(bytes),
    TextEncoding.utf16le || TextEncoding.utf16be => (
      text: _decodeUtf16(bytes, encoding),
      encoding: encoding,
      utf8Bom: false,
    ),
    TextEncoding.latin1 => (
      text: String.fromCharCodes(bytes),
      encoding: encoding,
      utf8Bom: false,
    ),
    TextEncoding.windows1252 => (
      text: _decodeWindows1252(bytes),
      encoding: encoding,
      utf8Bom: false,
    ),
  };
}

/// Encodes [text] in [encoding]. UTF-16 always carries its byte order mark,
/// since only a marked file is recognized again; a UTF-8 mark is optional.
/// A character the encoding cannot hold throws, naming where it is in
/// [text], rather than being replaced.
Uint8List encodeText(
  String text,
  TextEncoding encoding, {
  required bool utf8Bom,
}) {
  switch (encoding) {
    case TextEncoding.utf8:
      final encoded = utf8.encode(text);
      if (!utf8Bom) return encoded;
      return Uint8List(_utf8Bom.length + encoded.length)
        ..setAll(0, _utf8Bom)
        ..setAll(_utf8Bom.length, encoded);
    case TextEncoding.utf16le:
    case TextEncoding.utf16be:
      final endian = encoding == TextEncoding.utf16le
          ? Endian.little
          : Endian.big;
      final data = ByteData(2 * (text.length + 1))
        ..setUint16(0, 0xfeff, endian);
      for (var i = 0; i < text.length; i++) {
        final unit = text.codeUnitAt(i);
        // A lone surrogate would write a file that is not valid UTF-16 and
        // that this editor would then refuse to reopen.
        if (_isLead(unit) &&
            i + 1 < text.length &&
            _isTrail(text.codeUnitAt(i + 1))) {
          data
            ..setUint16(2 * (i + 1), unit, endian)
            ..setUint16(2 * (i + 2), text.codeUnitAt(i + 1), endian);
          i++;
          continue;
        }
        if (_isLead(unit) || _isTrail(unit)) {
          _throwUnrepresentable(text, i, encoding);
        }
        data.setUint16(2 * (i + 1), unit, endian);
      }
      return data.buffer.asUint8List();
    case TextEncoding.latin1:
    case TextEncoding.windows1252:
      final bytes = Uint8List(text.length);
      for (var i = 0; i < text.length; i++) {
        final byte = _singleByteFor(text.codeUnitAt(i), encoding);
        if (byte == null) _throwUnrepresentable(text, i, encoding);
        bytes[i] = byte;
      }
      return bytes;
  }
}

/// The encoded size of [text] in [encoding] when every character fits.
int encodedTextLength(
  String text,
  TextEncoding encoding, {
  bool utf8Bom = false,
}) => switch (encoding.bytesPerCodeUnit) {
  final width? => encoding.markLength + text.length * width,
  null => utf8EncodedLength(text) + (utf8Bom ? _utf8Bom.length : 0),
};

/// The bytes a UTF-8 byte order mark adds.
int get utf8BomLength => _utf8Bom.length;

DecodedText _decodeUtf8(Uint8List bytes) {
  // Count every leading mark: the first is metadata, the rest content.
  var leadingBoms = 0;
  while (_startsWith(bytes, _utf8Bom, leadingBoms * _utf8Bom.length)) {
    leadingBoms++;
  }
  final start = leadingBoms * _utf8Bom.length;
  final String content;
  try {
    // Utf8Decoder itself drops a leading BOM. Decode only after all leading
    // BOMs, then put back the ones that are document content.
    content = const Utf8Decoder(allowMalformed: false).convert(bytes, start);
  } on FormatException {
    final offset = _firstInvalidUtf8(bytes, start);
    throw UnsupportedTextEncodingException(
      'This file is not valid UTF-8 text: the byte ${_hex(bytes[offset])} at '
      'offset $offset does not begin a valid UTF-8 sequence.',
    );
  }
  return (
    text: leadingBoms > 1 ? '﻿' * (leadingBoms - 1) + content : content,
    encoding: TextEncoding.utf8,
    utf8Bom: leadingBoms > 0,
  );
}

String _decodeUtf16(Uint8List bytes, TextEncoding encoding) {
  final little = encoding == TextEncoding.utf16le;
  if (!_startsWith(bytes, little ? _utf16LeBom : _utf16BeBom)) {
    throw UnsupportedTextEncodingException(
      'This file does not start with a ${encoding.label} byte order mark. '
      'Only marked UTF-16 files can be opened as UTF-16.',
    );
  }
  String malformed(String reason) =>
      'This file starts with a ${encoding.label} byte order mark but is not '
      'valid UTF-16: $reason';
  if (bytes.length.isOdd) {
    throw UnsupportedTextEncodingException(
      malformed(
        'it has an odd number of bytes, so its last character is incomplete.',
      ),
    );
  }
  final data = ByteData.sublistView(bytes);
  final endian = little ? Endian.little : Endian.big;
  final units = Uint16List(bytes.length ~/ 2 - 1);
  for (var i = 0; i < units.length; i++) {
    units[i] = data.getUint16(2 * (i + 1), endian);
  }
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (_isLead(unit) && i + 1 < units.length && _isTrail(units[i + 1])) {
      i++;
      continue;
    }
    if (_isLead(unit) || _isTrail(unit)) {
      throw UnsupportedTextEncodingException(
        malformed(
          'the unpaired surrogate ${_hex(unit, digits: 4)} at byte '
          '${2 * (i + 1)} is not part of a character.',
        ),
      );
    }
  }
  return String.fromCharCodes(units);
}

String _decodeWindows1252(Uint8List bytes) {
  final units = Uint16List(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    final byte = bytes[i];
    if (byte < 0x80 || byte >= 0xa0) {
      units[i] = byte;
      continue;
    }
    final unit = _windows1252High[byte - 0x80];
    // Five bytes have no character. Reading them as C1 controls would
    // be a guess the user did not make; Latin-1 is the lossless choice.
    if (unit == _undefined) {
      throw UnsupportedTextEncodingException(
        'This file is not valid Windows-1252 text: the byte ${_hex(byte)} at '
        'offset $i has no character in Windows-1252.',
      );
    }
    units[i] = unit;
  }
  return String.fromCharCodes(units);
}

int? _singleByteFor(int unit, TextEncoding encoding) {
  if (unit < 0x80 || (unit >= 0xa0 && unit <= 0xff)) return unit;
  if (encoding == TextEncoding.latin1) return unit <= 0xff ? unit : null;
  final index = _windows1252High.indexOf(unit);
  return index < 0 ? null : 0x80 + index;
}

Never _throwUnrepresentable(String text, int offset, TextEncoding encoding) {
  final unit = text.codeUnitAt(offset);
  final paired =
      _isLead(unit) &&
      offset + 1 < text.length &&
      _isTrail(text.codeUnitAt(offset + 1));
  final rune = paired
      ? 0x10000 +
            ((unit - 0xd800) << 10) +
            (text.codeUnitAt(offset + 1) - 0xdc00)
      : unit;
  final starts = lineStartOffsets(text);
  final line = lineIndexAt(starts, offset);
  final column = text.substring(starts[line], offset).runes.length + 1;
  final code = rune.toRadixString(16).toUpperCase().padLeft(4, '0');
  // A lone surrogate cannot be shown, only named.
  final shown = _isLead(rune) || _isTrail(rune)
      ? 'U+$code'
      : '"${String.fromCharCode(rune)}" (U+$code)';
  throw TextDocumentException(
    'The character $shown at line ${line + 1}, column $column cannot be '
    'saved in ${encoding.label}. Remove or replace it, or choose an '
    'encoding that can represent it.',
  );
}

/// The offset where the first malformed UTF-8 sequence at or after [start]
/// begins, following the Unicode well-formedness table (no overlong forms,
/// no surrogates, nothing above U+10FFFF). Only called once the strict
/// decoder has refused, so a sequence is always found.
int _firstInvalidUtf8(Uint8List bytes, int start) {
  var i = start;
  while (i < bytes.length) {
    final lead = bytes[i];
    if (lead < 0x80) {
      i++;
      continue;
    }
    final int trailing;
    var low = 0x80;
    var high = 0xbf;
    if (lead >= 0xc2 && lead <= 0xdf) {
      trailing = 1;
    } else if (lead >= 0xe0 && lead <= 0xef) {
      trailing = 2;
      if (lead == 0xe0) low = 0xa0;
      if (lead == 0xed) high = 0x9f;
    } else if (lead >= 0xf0 && lead <= 0xf4) {
      trailing = 3;
      if (lead == 0xf0) low = 0x90;
      if (lead == 0xf4) high = 0x8f;
    } else {
      return i;
    }
    if (i + trailing >= bytes.length) return i;
    final second = bytes[i + 1];
    if (second < low || second > high) return i;
    for (var k = 2; k <= trailing; k++) {
      if (bytes[i + k] & 0xc0 != 0x80) return i;
    }
    i += trailing + 1;
  }
  return bytes.length - 1;
}

bool _startsWith(List<int> bytes, List<int> prefix, [int offset = 0]) {
  if (bytes.length < offset + prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[offset + i] != prefix[i]) return false;
  }
  return true;
}

bool _isLead(int unit) => unit >= 0xd800 && unit <= 0xdbff;

bool _isTrail(int unit) => unit >= 0xdc00 && unit <= 0xdfff;

String _hex(int value, {int digits = 2}) =>
    '0x${value.toRadixString(16).toUpperCase().padLeft(digits, '0')}';

const _utf8Bom = [0xef, 0xbb, 0xbf];
const _utf16LeBom = [0xff, 0xfe];
const _utf16BeBom = [0xfe, 0xff];
const _utf32LeBom = [0xff, 0xfe, 0x00, 0x00];
const _utf32BeBom = [0x00, 0x00, 0xfe, 0xff];

/// Marks the Windows-1252 bytes that have no character.
const _undefined = -1;

/// Windows-1252 bytes 0x80 to 0x9F, from the code page's published table.
const _windows1252High = [
  0x20ac, _undefined, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021, //
  0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, _undefined, 0x017d, _undefined,
  _undefined, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
  0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, _undefined, 0x017e, 0x0178,
];
