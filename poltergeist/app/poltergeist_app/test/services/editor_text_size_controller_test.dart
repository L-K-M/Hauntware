import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';
import 'package:poltergeist_app/services/editor_text_size_controller.dart';
import 'package:poltergeist_app/services/settings_models.dart';

/// The app's side of the editor text size: what every editor listens to,
/// and what Settings and View › Zoom write through.
void main() {
  EditorTextSizeController controller({
    int initial = EditorTextSize.standard,
    Future<void> Function(int size)? save,
  }) {
    final created = EditorTextSizeController(initial: initial, save: save);
    addTearDown(created.dispose);
    return created;
  }

  test('starts at the standard size, or the stored one clamped', () {
    expect(controller().value, EditorTextSize.standard);
    expect(controller(initial: 20).value, 20);
    expect(controller(initial: 99).value, EditorTextSize.maximum);
  });

  test('resizes, then saves', () async {
    final events = <String>[];
    late EditorTextSizeController sized;
    sized = controller(save: (size) async => events.add('save ${sized.value}'));
    sized.addListener(() => events.add('notify'));

    await sized.setTextSize(18);

    expect(events, ['notify', 'save 18']);
    expect(sized.value, 18);
  });

  test('clamps, and writing what is already there does nothing', () async {
    final saved = <int>[];
    final sized = controller(save: (size) async => saved.add(size));

    await sized.setTextSize(EditorTextSize.standard);
    await sized.setTextSize(500);

    expect(saved, [EditorTextSize.maximum]);
  });

  test('zoom steps through the shared sizes', () async {
    final sized = controller();

    await sized.zoom(EditorZoom.zoomIn);
    expect(sized.value, 16);
    await sized.zoom(EditorZoom.zoomOut);
    await sized.zoom(EditorZoom.zoomOut);
    expect(sized.value, 13);
    await sized.zoom(EditorZoom.actualSize);
    expect(sized.value, EditorTextSize.standard);
  });

  test('a failed write keeps the size on screen, and says so', () async {
    final sized = controller(save: (_) async => throw StateError('disk full'));

    await expectLater(sized.setTextSize(20), throwsA(isA<StateError>()));
    expect(sized.value, 20);
  });
}
