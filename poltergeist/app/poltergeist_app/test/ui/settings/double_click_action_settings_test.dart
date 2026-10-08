import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/double_click_action.dart';
import 'package:poltergeist_app/services/double_click_action_controller.dart';
import 'package:poltergeist_app/services/editor_registry_controller.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_app/ui/settings/double_click_action_settings.dart';
import 'package:poltergeist_app/ui/settings/editor_settings.dart';

/// Settings → Editing's Opening files row (06 §8), in the Configure
/// Editors… dialog a runner without a Settings window shows.
void main() {
  Finder dropdown() => find.byKey(const ValueKey('editing.doubleClickAction'));

  DoubleClickAction shown(WidgetTester tester) =>
      tester.widget<DropdownButton<DoubleClickAction>>(dropdown()).value!;

  Future<void> pumpHost(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    ),
  );

  testWidgets('the Editing dialog opens with the double-click action', (
    tester,
  ) async {
    final action = DoubleClickActionController();
    addTearDown(action.dispose);
    final directory = Directory.systemTemp.createTempSync('pg-dca-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final registry = EditorRegistryController(
      store: SettingsStore(path: p.join(directory.path, 'settings.json')),
    );
    await pumpHost(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showEditorsSettingsDialog(
            context,
            controller: registry,
            doubleClickAction: action,
          ),
          child: const Text('open'),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(DoubleClickActionSection), findsOneWidget);
    expect(find.text('Opening files'), findsOneWidget);

    await tester.tap(dropdown());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Do nothing').last);
    await tester.pumpAndSettle();

    expect(action.value, DoubleClickAction.nothing);
    expect(shown(tester), DoubleClickAction.nothing);
  });

  testWidgets('a failed save keeps the choice the panes follow', (
    tester,
  ) async {
    final action = DoubleClickActionController(
      save: (_) async => throw StateError('disk full'),
    );
    addTearDown(action.dispose);
    await pumpHost(tester, DoubleClickActionSection(model: action));

    await tester.tap(dropdown());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit in Poltergeist').last);
    await tester.pumpAndSettle();

    expect(action.value, DoubleClickAction.edit);
    expect(shown(tester), DoubleClickAction.edit);
    expect(find.textContaining('disk full'), findsOneWidget);
    // Reported to the app's error sink as well.
    expect(tester.takeException(), isA<StateError>());
    // The toast's dismissal timer.
    await tester.pumpAndSettle(const Duration(seconds: 10));
  });
}
