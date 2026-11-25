import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/l10n/editor_localizations_en.dart';
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
      // Find-bar tools render their options as the bar's own controls.
      if (tool.usesFindBar) continue;
      for (final option in tool.options) {
        expect(
          strings.textToolOptionName(tool.id, option.id),
          isNot(option.id),
          reason: '${tool.id}.${option.id} has no bar label',
        );
      }
    }
  });

  group('text tool copy', () {
    const strings = EditorStrings();

    TextToolReport report(TextTool tool, TextToolOutcome outcome) =>
        TextToolReport(
          tool: tool,
          outcome: outcome,
          ranOn: TextToolRanOn.document,
        );

    TextToolChanged changed(int changed, int scope) => TextToolChanged(
      const LineEdit('', 0, 0),
      changed: changed,
      scope: scope,
    );

    test('a tool without its own copy counts what changed, in plural', () {
      final tool = TextTool(
        id: 'hostTool',
        group: TextToolGroup.values.first,
        scope: TextToolScope.values.first,
        run: (_) => const TextToolUnchanged(),
      );
      expect(
        strings.textToolNotice(report(tool, changed(1, 1))),
        'hostTool: changed 1 of 1 unit in the whole document.',
      );
      expect(
        strings.textToolNotice(report(tool, changed(2, 5))),
        'hostTool: changed 2 of 5 units in the whole document.',
      );
    });

    test('Trim Trailing Whitespace previews the lines it will trim', () {
      final tool = textToolById('trimTrailingWhitespace')!;
      expect(
        strings.textToolPreview(report(tool, changed(1, 9))),
        'will trim 1 line',
      );
      expect(
        strings.textToolPreview(report(tool, changed(3, 9))),
        'will trim 3 lines',
      );
    });
  });

  group('EditorStrings.of', () {
    testWidgets('reads the package catalog when its delegate is installed', (
      tester,
    ) async {
      EditorStrings? seen;
      await tester.pumpWidget(
        Localizations(
          locale: const Locale('en'),
          delegates: const [
            _MarkedCatalogDelegate(),
            GlobalWidgetsLocalizations.delegate,
          ],
          child: Builder(
            builder: (context) {
              seen = EditorStrings.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pump();

      expect(seen, isA<LocalizedEditorStrings>());
      expect(seen!.findHint, '[catalog find hint]');
    });

    testWidgets('falls back to the English defaults without the delegate', (
      tester,
    ) async {
      EditorStrings? seen;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            seen = EditorStrings.of(context);
            return const SizedBox();
          },
        ),
      );

      expect(seen, isNot(isA<LocalizedEditorStrings>()));
      expect(seen!.findHint, 'Find in file');
    });
  });
}

class _MarkedCatalog extends EditorLocalizationsEn {
  _MarkedCatalog();

  @override
  String get editorFindHint => '[catalog find hint]';
}

class _MarkedCatalogDelegate
    extends LocalizationsDelegate<EditorLocalizations> {
  const _MarkedCatalogDelegate();

  @override
  bool isSupported(Locale locale) => locale.languageCode == 'en';

  @override
  Future<EditorLocalizations> load(Locale locale) async => _MarkedCatalog();

  @override
  bool shouldReload(_MarkedCatalogDelegate old) => false;
}
