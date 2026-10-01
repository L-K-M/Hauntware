import 'dart:convert';

import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

const cleanup = TextSaveOptions(
  trailingWhitespace: TrailingWhitespacePolicy.trim,
  finalNewline: FinalNewlinePolicy.ensure,
);

void main() {
  test('save cleanup is off by default', () {
    expect(prepareTextForSave('a  ', 1, 1, const TextSaveOptions()), isNull);
  });

  test('cleanup maps a backward selection and keeps CRLF breaks', () {
    final edit = prepareTextForSave(
      'a  \r\nb\t',
      7,
      1,
      cleanup,
      lineEnding: LineEnding.crlf,
    )!;
    expect(edit.text, 'a\r\nb\r\n');
    expect(edit.selectionBase, 4);
    expect(edit.selectionExtent, 1);
  });

  test('empty documents stay empty; existing final breaks are retained', () {
    for (final source in ['', 'a\n', 'a\r\n', 'a\r', 'a\n\n']) {
      expect(prepareTextForSave(source, 0, 0, cleanup), isNull, reason: source);
    }
  });

  test('only trailing ASCII spaces and tabs are removed', () {
    final edit = prepareTextForSave('  a\u00a0 \t\nb\t', 0, 0, cleanup)!;
    expect(edit.text, '  a\u00a0\nb\n');
  });

  test(
    'metadata byte count follows guarded saves for Unicode and mixed EOL',
    () {
      const source = 'é\r\nx\ry\n';
      for (final ending in LineEnding.values) {
        for (final bom in Utf8Bom.values) {
          final metadata = TextDocumentMetadata(
            lineEnding: ending,
            utf8Bom: bom,
          );
          final folded = 'é\nx\ny\n';
          final disk = ending == LineEnding.crlf
              ? folded.replaceAll('\n', '\r\n')
              : folded;
          final prefix = bom == Utf8Bom.present ? 3 : 0;
          expect(
            textDocumentByteCount(source, metadata),
            utf8.encode(disk).length + prefix,
          );
          expect(
            textDocumentByteCount(
              source,
              metadata,
              normalization: TextNormalization.preserve,
            ),
            utf8.encode(source).length + prefix,
          );
        }
      }
    },
  );

  test(
    'Normalize Line Endings ignores the live selection and maps the caret',
    () {
      final tool = textToolById('normalizeLineEndings')!;
      const source = 'a\r\nb\rc\n';
      final range = resolveTextToolRange(tool, source, 5, 4);
      expect(range.ranOn, TextToolRanOn.document);
      for (final ending in LineEnding.values) {
        final result =
            tool.run(
                  TextToolRun(
                    text: source,
                    base: range.base,
                    extent: range.extent,
                    caret: range.caret,
                    ranOn: range.ranOn,
                    options: const {},
                    context: TextToolContext(
                      fold: (s) => s.toLowerCase(),
                      indentation: const Indentation.spaces(),
                      lineEnding: ending,
                    ),
                  ),
                )
                as TextToolChanged;
        expect(
          result.edit.text,
          ending == LineEnding.lf ? 'a\nb\nc\n' : 'a\r\nb\r\nc\r\n',
        );
        expect(result.changed, 2);
        expect(result.scope, 3);
        expect(result.edit.selectionBase, ending == LineEnding.lf ? 3 : 4);
        expect(result.edit.selectionBase, result.edit.selectionExtent);
      }
    },
  );
}
