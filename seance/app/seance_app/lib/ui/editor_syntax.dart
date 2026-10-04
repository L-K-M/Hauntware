// Shared highlighting implementation; the host keeps its own color palette.
import 'package:flutter/material.dart';
import 'package:planchette_editor/planchette_editor.dart';

export 'package:planchette_editor/planchette_editor.dart';

EditorSyntaxTheme seanceEditorSyntaxTheme(Brightness brightness) =>
    brightness == Brightness.dark ? _dark : _light;

const _dark = EditorSyntaxTheme(
  comment: Color(0xFF6B6880),
  string: Color(0xFF7FD88F),
  number: Color(0xFFE6C177),
  keyword: Color(0xFFC49BE8),
  meta: Color(0xFF7AA2F7),
  matchBackground: Color(0x66E6C177),
  searchScopeBackground: Color(0x22E6C177),
  matchForeground: Color(0xFFF4F2FA),
  activeMatchBackground: Color(0xFFB9AFEE),
  activeMatchForeground: Color(0xFF15141B),
);

const _light = EditorSyntaxTheme(
  comment: Color(0xFF6B6880),
  string: Color(0xFF2E6B36),
  number: Color(0xFF7A5A00),
  keyword: Color(0xFF8A3FA8),
  meta: Color(0xFF2B4FBF),
  matchBackground: Color(0x80F5D89B),
  searchScopeBackground: Color(0x33F5D89B),
  matchForeground: Color(0xFF2A2733),
  activeMatchBackground: Color(0xFFB9AFEE),
  activeMatchForeground: Color(0xFF15141B),
);
