import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/android_app.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/document_workspace.dart';

import 'services/document_workspace_test.dart'
    show FakeDialogs, MemoryDocuments;
import 'services/memory_settings.dart';

void main() {
  testWidgets(
    'Android starts without desktop channels and guards system Back',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'planchette-android-test-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const documents = MethodChannel('planchette/documents');
      messenger.setMockMethodCallHandler(
        documents,
        (call) async => switch (call.method) {
          'settingsPath' => '${directory.path}/settings.json',
          'recoveries' => <String>[],
          _ => throw StateError(
            'Unexpected Android startup call: ${call.method}',
          ),
        },
      );
      var exits = 0;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemNavigator.pop') exits++;
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(documents, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await tester.runAsync(runAndroidApp);
      await tester.pumpAndSettle();
      final app = tester.widget<PlanchetteApp>(find.byType(PlanchetteApp));
      final tab = app.workspace.active!;
      tab.editor.text.text = 'keep my edits';
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Save changes to “Untitled”?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(exits, 0);
      expect(tab.editor.text.text, 'keep my edits');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Don’t Save'));
      await tester.runAsync(app.settings.flush);
      await tester.pumpAndSettle();
      expect(exits, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets('Android commands fit a phone above the keyboard', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final workspace = DocumentWorkspace(
      store: MemoryDocuments(),
      dialogs: FakeDialogs(),
    );
    addTearDown(workspace.dispose);
    final tab = workspace.newDocument()!;
    await tester.pumpWidget(
      PlanchetteApp(workspace: workspace, settings: testSettings()),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MenuBar), findsNothing);
    await tester.tap(find.byTooltip('Commands'));
    await tester.pumpAndSettle();
    expect(find.text('Save As…'), findsOneWidget);
    expect(find.text('Settings…'), findsOneWidget);
    expect(find.text('Open Containing Folder'), findsNothing);
    expect(find.text('Open Folder…'), findsNothing);
    expect(find.text('Open Server…'), findsNothing);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.enterText(
      find.byKey(const ValueKey('planchette.palette.query')),
      'Settings',
    );
    await tester.pumpAndSettle();
    tester.view.resetViewInsets();
    await tester.tap(find.text('Settings…'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    final field = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.controller == tab.editor.text,
    );
    await tester.enterText(field, 'Android editing');
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    expect(tab.editor.text.text, 'Android editing');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));
}
