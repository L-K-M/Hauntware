import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart'
    show EditorTextSize, EditorZoom;
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// The built-in editor's text size in the app: the shared steps, applied to
/// every editor tab at once and kept on this device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late AppServices services;
  late AppState state;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-zoom-');
    messenger.setMockMethodCallHandler(
      _pathChannel,
      (call) async => directory.path,
    );
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
    state = AppState(services);
  });

  tearDown(() async {
    state.dispose();
    await services.probe.dispose();
    messenger.setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    await directory.delete(recursive: true);
  });

  test('zoom steps the shared sizes, notifies and persists', () async {
    var notified = 0;
    state.addListener(() => notified++);
    expect(services.settings.editorFontSize, EditorTextSize.standard);

    await state.zoomEditor(EditorZoom.zoomIn);
    expect(services.settings.editorFontSize, 16);
    expect(notified, 1);
    expect((await services.settingsStore.load()).editorFontSize, 16);

    await state.zoomEditor(EditorZoom.zoomOut);
    await state.zoomEditor(EditorZoom.zoomOut);
    expect(services.settings.editorFontSize, 13);

    await state.zoomEditor(EditorZoom.actualSize);
    expect(services.settings.editorFontSize, EditorTextSize.standard);
  });

  test('a size already set is a no-op, and the range holds', () async {
    var notified = 0;
    state.addListener(() => notified++);

    await state.setEditorFontSize(EditorTextSize.standard);
    expect(notified, 0);

    await state.setEditorFontSize(400);
    expect(services.settings.editorFontSize, EditorTextSize.maximum);
    await state.zoomEditor(EditorZoom.zoomIn);
    expect(notified, 1);
  });
}
