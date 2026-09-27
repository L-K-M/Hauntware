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
}
