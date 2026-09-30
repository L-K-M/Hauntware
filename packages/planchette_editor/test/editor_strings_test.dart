import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

void main() {
  test('the position readout counts in singular and plural', () {
    const strings = EditorStrings();
    expect(
      strings.documentPosition(1, 1, 1, 0),
      'Ln 1, Col 1 · 1 line · 0 bytes',
    );
    expect(
      strings.documentPosition(1, 2, 1, 1),
      'Ln 1, Col 2 · 1 line · 1 byte',
    );
    expect(
      strings.documentPosition(3, 4, 12, 345),
      'Ln 3, Col 4 · 12 lines · 345 bytes',
    );
  });

  test('every catalog tool names a palette description and keywords', () {
    const strings = EditorStrings();
    for (final tool in textToolCatalog) {
      expect(
        strings.textToolDescription(tool.id),
        isNotEmpty,
        reason: '${tool.id} has no palette description',
      );
      expect(
        strings.textToolKeywords(tool.id),
        isNotEmpty,
        reason: '${tool.id} has no palette keywords',
      );
    }
  });

  test('every declared option has a bar label', () {
    const strings = EditorStrings();
    for (final tool in textToolCatalog) {
      for (final option in tool.options) {
        expect(
          strings.textToolOptionName(tool.id, option.id),
          isNot(option.id),
          reason: '${tool.id}.${option.id} has no bar label',
        );
      }
    }
  });
}
