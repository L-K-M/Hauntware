import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/sidebar_panel.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// The side panel's tabs run Files, Context, Git, Snippets, Assistant, and
/// Files opens first. The narrow drawer has no Files and opens on what its
/// button names: the Assistant once one is set up, else Snippets.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Directory? directory;
  AppServices? services;
  AppState? state;

  tearDown(() async {
    state?.dispose();
    state = null;
    await services?.probe.dispose();
    services = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    try {
      await directory?.delete(recursive: true);
    } on FileSystemException {
      // Deliberately ignored: the OS reaps system temp dirs.
    }
    directory = null;
  });

  Future<void> pumpPanel(
    WidgetTester tester, {
    required SidebarPanel panel,
    bool assistant = false,
  }) async {
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('seance-panel-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pathChannel, (_) async => directory!.path);
      FlutterSecureStorage.setMockInitialValues({});
      services = await AppServices.initialize();
      state = AppState(services!)..llmConfigured = assistant;
    });
    tester.view.physicalSize = const Size(380, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(platform: TargetPlatform.macOS),
        home: AppScope(
          state: state!,
          child: Scaffold(body: panel),
        ),
      ),
    );
    await tester.pump();
  }

  List<String> order(WidgetTester tester, List<String> labels) {
    final present = [
      for (final label in labels)
        if (find.byTooltip(label).evaluate().isNotEmpty) label,
    ];
    return present..sort(
      (a, b) => tester
          .getCenter(find.byTooltip(a))
          .dx
          .compareTo(tester.getCenter(find.byTooltip(b)).dx),
    );
  }

  bool isOpen(WidgetTester tester, String label) => tester
      .widget<Semantics>(
        find.descendant(
          of: find.byTooltip(label),
          matching: find.byWidgetPredicate(
            (widget) => widget is Semantics && widget.properties.label == label,
          ),
        ),
      )
      .properties
      .selected!;

  const labels = ['Assistant', 'Snippets', 'Files', 'Context', 'Git'];

  for (final assistant in [false, true]) {
    testWidgets(
      'the panel runs Files, Context, Git, Snippets, Assistant and opens '
      'Files (assistant set up: $assistant)',
      (tester) async {
        await pumpPanel(
          tester,
          panel: const SidebarPanel(),
          assistant: assistant,
        );
        expect(order(tester, labels), [
          'Files',
          'Context',
          'Git',
          'Snippets',
          'Assistant',
        ]);
        expect(isOpen(tester, 'Files'), isTrue);
        expect(isOpen(tester, 'Assistant'), isFalse);
      },
    );
  }

  for (final (assistant, opening) in [
    (false, 'Snippets'),
    (true, 'Assistant'),
  ]) {
    testWidgets('the drawer has no Files and opens $opening', (tester) async {
      await pumpPanel(
        tester,
        panel: const SidebarPanel(includeFiles: false),
        assistant: assistant,
      );
      expect(order(tester, labels), [
        'Context',
        'Git',
        'Snippets',
        'Assistant',
      ]);
      for (final label in ['Context', 'Git', 'Snippets', 'Assistant']) {
        expect(isOpen(tester, label), label == opening, reason: label);
      }
    });
  }
}
