import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';
import 'package:poltergeist_app/services/editor_text_size_controller.dart';
import 'package:poltergeist_app/services/settings_models.dart';

/// The app's side of the editor text size: what every editor listens to,
/// and what Settings and View › Zoom write through.
void main() {
  test('starts at the standard size, or the stored one clamped', () {
    expect(EditorTextSizeController().value, EditorTextSize.standard);
    expect(EditorTextSizeController(initial: 20).value, 20);
    expect(EditorTextSizeController(initial: 99).value, EditorTextSize.maximum);
  });

  test('resizes, then saves', () async {
    final events = <String>[];
    late EditorTextSizeController controller;
    controller = EditorTextSizeController(
      save: (size) async => events.add('save ${controller.value}'),
    );
    controller.addListener(() => events.add('notify'));

    await controller.setTextSize(18);

    expect(events, ['notify', 'save 18']);
    expect(controller.value, 18);
  });

  test('clamps, and writing what is already there does nothing', () async {
    final saved = <int>[];
    final controller = EditorTextSizeController(
      save: (size) async => saved.add(size),
    );

    await controller.setTextSize(EditorTextSize.standard);
    await controller.setTextSize(500);

    expect(saved, [EditorTextSize.maximum]);
  });

  test('zoom steps through the shared sizes', () async {
    final controller = EditorTextSizeController();

    await controller.zoom(EditorZoom.zoomIn);
    expect(controller.value, 16);
    await controller.zoom(EditorZoom.zoomOut);
    await controller.zoom(EditorZoom.zoomOut);
    expect(controller.value, 13);
    await controller.zoom(EditorZoom.actualSize);
    expect(controller.value, EditorTextSize.standard);
  });

  test('a failed write keeps the size on screen, and says so', () async {
    final controller = EditorTextSizeController(
      save: (_) async => throw StateError('disk full'),
    );

    await expectLater(controller.setTextSize(20), throwsA(isA<StateError>()));
    expect(controller.value, 20);
  });
}
