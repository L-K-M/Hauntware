/// Display safety for text that arrives in a suite link: hidden and
/// reordering characters are stripped and reported, and a host name's
/// scripts are flagged. Moved from Poltergeist's `deep_links.dart`
/// (docs/design/suite-links.md section 1.3).
library;

import 'package:meta/meta.dart';

@immutable
class SafeDeepLinkDisplay {
  const SafeDeepLinkDisplay({
    required this.text,
    required this.removedControls,
  });

  final String text;
  final bool removedControls;
}

@immutable
final class SafeDeepLinkHostDisplay extends SafeDeepLinkDisplay {
  const SafeDeepLinkHostDisplay({
    required super.text,
    required super.removedControls,
    required this.internationalized,
    required this.mixedScripts,
    required this.unrecognizedScripts,
  });

  final bool internationalized;
  final bool mixedScripts;
  final bool unrecognizedScripts;
}

SafeDeepLinkDisplay safeDeepLinkDisplay(String value) {
  final safe = StringBuffer();
  var removed = false;
  for (final rune in value.runes) {
    if (isUnsafeDisplayControl(rune)) {
      removed = true;
      continue;
    }
    safe.writeCharCode(rune);
  }
  return SafeDeepLinkDisplay(text: safe.toString(), removedControls: removed);
}

SafeDeepLinkHostDisplay safeDeepLinkHostDisplay(String value) {
  final safe = safeDeepLinkDisplay(value);
  var internationalized = false;
  var mixedScripts = false;
  var unrecognizedScripts = false;
  for (final label in safe.text.split(RegExp(r'[.\u3002\uff0e\uff61]'))) {
    final scripts = <_WritingScript>{};
    var hasUnclassified = false;
    for (final rune in label.runes) {
      if (rune > 0x7f) internationalized = true;
      final script = _scriptOf(rune);
      if (script != null) {
        scripts.add(script);
      } else if (_isUnclassifiedScriptCharacter(rune)) {
        hasUnclassified = true;
      }
    }
    mixedScripts |= _scriptsAreMixed(scripts);
    unrecognizedScripts |= hasUnclassified;
  }
  return SafeDeepLinkHostDisplay(
    text: safe.text,
    removedControls: safe.removedControls,
    internationalized: internationalized,
    mixedScripts: mixedScripts,
    unrecognizedScripts: unrecognizedScripts,
  );
}

bool _scriptsAreMixed(Set<_WritingScript> scripts) {
  if (scripts.length < 2) return false;
  if (scripts.difference(const {
    _WritingScript.han,
    _WritingScript.hiragana,
    _WritingScript.katakana,
  }).isEmpty) {
    return false;
  }
  if (scripts.difference(const {
    _WritingScript.han,
    _WritingScript.hangul,
  }).isEmpty) {
    return false;
  }
  return true;
}

bool _isUnclassifiedScriptCharacter(int rune) {
  if (rune <= 0x7f) return false;
  if ((rune >= 0x0300 && rune <= 0x036f) ||
      (rune >= 0x1ab0 && rune <= 0x1aff) ||
      (rune >= 0x1dc0 && rune <= 0x1dff) ||
      (rune >= 0x20d0 && rune <= 0x20ff) ||
      (rune >= 0xfe20 && rune <= 0xfe2f)) {
    return false;
  }
  return true;
}

/// Whether [rune] is hidden or reorders text when shown: C0, DEL, C1,
/// the line and paragraph separators, and the default-ignorable format
/// characters. The link parsers refuse a host or username holding one.
@internal
bool isUnsafeDisplayControl(int rune) =>
    rune < 0x20 ||
    (rune >= 0x7f && rune <= 0x9f) ||
    rune == 0x2028 ||
    rune == 0x2029 ||
    _isDefaultIgnorableFormat(rune);

bool _isDefaultIgnorableFormat(int rune) =>
    rune == 0x00ad ||
    rune == 0x034f ||
    rune == 0x061c ||
    (rune >= 0x115f && rune <= 0x1160) ||
    (rune >= 0x17b4 && rune <= 0x17b5) ||
    (rune >= 0x180b && rune <= 0x180f) ||
    (rune >= 0x200b && rune <= 0x200f) ||
    (rune >= 0x202a && rune <= 0x202e) ||
    (rune >= 0x2060 && rune <= 0x206f) ||
    rune == 0x3164 ||
    (rune >= 0xfe00 && rune <= 0xfe0f) ||
    rune == 0xfeff ||
    rune == 0xffa0 ||
    (rune >= 0xfff0 && rune <= 0xfff8) ||
    (rune >= 0x1bca0 && rune <= 0x1bcaf) ||
    (rune >= 0x1d173 && rune <= 0x1d17a) ||
    (rune >= 0xe0000 && rune <= 0xe0fff);

enum _WritingScript {
  latin,
  greek,
  cyrillic,
  armenian,
  georgian,
  hebrew,
  arabic,
  devanagari,
  han,
  hiragana,
  katakana,
  hangul,
}

_WritingScript? _scriptOf(int rune) {
  if ((rune >= 0x41 && rune <= 0x5a) ||
      (rune >= 0x61 && rune <= 0x7a) ||
      (rune >= 0x00c0 && rune <= 0x024f)) {
    return _WritingScript.latin;
  }
  if (rune >= 0x0370 && rune <= 0x03ff) return _WritingScript.greek;
  if (rune >= 0x0400 && rune <= 0x052f) return _WritingScript.cyrillic;
  if (rune >= 0x0530 && rune <= 0x058f) return _WritingScript.armenian;
  if ((rune >= 0x10a0 && rune <= 0x10ff) ||
      (rune >= 0x1c90 && rune <= 0x1cbf)) {
    return _WritingScript.georgian;
  }
  if (rune >= 0x0590 && rune <= 0x05ff) return _WritingScript.hebrew;
  if ((rune >= 0x0600 && rune <= 0x06ff) ||
      (rune >= 0x0750 && rune <= 0x077f)) {
    return _WritingScript.arabic;
  }
  if (rune >= 0x0900 && rune <= 0x097f) return _WritingScript.devanagari;
  if (rune >= 0x3040 && rune <= 0x309f) return _WritingScript.hiragana;
  if (rune >= 0x30a0 && rune <= 0x30ff) return _WritingScript.katakana;
  if ((rune >= 0x3400 && rune <= 0x4dbf) ||
      (rune >= 0x4e00 && rune <= 0x9fff)) {
    return _WritingScript.han;
  }
  if ((rune >= 0x1100 && rune <= 0x11ff) ||
      (rune >= 0xac00 && rune <= 0xd7af)) {
    return _WritingScript.hangul;
  }
  return null;
}
