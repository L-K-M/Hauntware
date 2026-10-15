import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart' show EditorLigatures;
import 'package:poltergeist_app/services/editor_font.dart';
import 'package:poltergeist_app/services/editor_font_controller.dart';

/// The app's side of the editor font: what every editor listens to, and
/// what Settings writes through.
void main() {
  const fira = EditorFont(family: 'Fira Code');

  EditorFontController controller({
    EditorFont initial = EditorFont.standard,
    Future<void> Function(EditorFont font)? save,
  }) {
    final created = EditorFontController(initial: initial, save: save);
    addTearDown(created.dispose);
    return created;
  }

  test('starts at the default font, or the stored one', () {
    expect(controller().value, EditorFont.standard);
    expect(controller(initial: fira).value, fira);
  });

  test('redraws, then saves', () async {
    final events = <String>[];
    late EditorFontController font;
    font = controller(
      save: (_) async => events.add('save ${font.value.family}'),
    );
    font.addListener(() => events.add('notify'));

    await font.setFont(fira);

    expect(events, ['notify', 'save Fira Code']);
    expect(font.value, fira);
  });

  test('writing what is already there does nothing', () async {
    final saved = <EditorFont>[];
    final font = controller(save: (font) async => saved.add(font));

    await font.setFont(EditorFont.standard);
    await font.setFont(const EditorFont(ligatures: EditorLigatures.off));

    expect(saved, [const EditorFont(ligatures: EditorLigatures.off)]);
  });

  test('a failed write keeps the font on screen, and says so', () async {
    final font = controller(save: (_) async => throw StateError('disk full'));

    await expectLater(font.setFont(fira), throwsA(isA<StateError>()));
    expect(font.value, fira);
  });

  test('a blank family is the editor default', () {
    expect(EditorFont.standard.chosenFamily, isNull);
    expect(const EditorFont(family: '  ').chosenFamily, isNull);
    expect(const EditorFont(family: ' Fira Code ').chosenFamily, 'Fira Code');
  });
}
