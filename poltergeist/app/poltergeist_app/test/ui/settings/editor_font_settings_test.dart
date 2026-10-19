import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart' show EditorLigatures;
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/editor_font.dart';
import 'package:poltergeist_app/services/settings_models.dart';
import 'package:poltergeist_app/ui/settings/editor_font_settings.dart';

/// The Settings window's model: a write lands only when the app answers.
final class _SlowModel extends ChangeNotifier implements EditorFontModel {
  _SlowModel([this._value = EditorFont.standard]);

  EditorFont _value;
  final writes = <(EditorFont, Completer<void>)>[];

  @override
  EditorFont get value => _value;

  @override
  Future<void> setFont(EditorFont font) {
    final done = Completer<void>();
    writes.add((font, done));
    return done.future;
  }

  /// The app's answer: the snapshot moves the font, or the write fails.
  void answer({Object? error}) {
    final (font, done) = writes.removeAt(0);
    if (error != null) {
      done.completeError(error);
      return;
    }
    _value = font;
    notifyListeners();
    done.complete();
  }
}

void main() {
  late _SlowModel model;

  setUp(() => model = _SlowModel());
  tearDown(() => model.dispose());

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: EditorFontSection(model: model)),
    ),
  );

  String menu(WidgetTester tester) => tester.widget<Text>(
    find.descendant(
      of: find.byKey(const ValueKey('editor.font')),
      matching: find.byType(Text),
    ),
  ).data!;

  Future<void> choose(WidgetTester tester, String family) async {
    await tester.enterText(find.byKey(const ValueKey('font.search')), family);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('font.choice.$family')));
    await tester.tap(find.byKey(const ValueKey('font.apply')));
    await tester.pumpAndSettle();
  }

  bool ligatures(WidgetTester tester) => tester
      .widget<SwitchListTile>(find.byKey(const ValueKey('editor.ligatures')))
      .value;

  testWidgets('the menu lists the included fonts, the default marked', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('editor.font')));
    await tester.pumpAndSettle();

    for (final label in [
      'Iosevka Term',
      'Fira Code',
      'Maple Mono',
      'Geist Mono',
      'Monaspace Radon',
    ]) {
      await tester.enterText(find.byKey(const ValueKey('font.search')), label);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('font.choice.$label')), findsOneWidget);
    }

    expect(model.writes, isEmpty);
    await choose(tester, 'Fira Code');
    expect(model.writes.single.$1, const EditorFont(family: 'Fira Code'));
    // The app has not answered: the menu shows the choice anyway.
    expect(menu(tester), 'Fira Code');

    model.answer();
    await tester.pump();
    expect(menu(tester), 'Fira Code');
  });

  testWidgets('the default stores no family', (tester) async {
    model = _SlowModel(const EditorFont(family: 'Maple Mono'));
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('editor.font')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('font.choice.')));
    await tester.tap(find.byKey(const ValueKey('font.apply')));
    await tester.pumpAndSettle();

    expect(model.writes.single.$1, EditorFont.standard);
  });

  testWidgets('choosing the font already shown writes nothing', (tester) async {
    model = _SlowModel(const EditorFont(family: 'Fira Code'));
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('editor.font')));
    await tester.pumpAndSettle();
    await choose(tester, 'Fira Code');
    expect(model.writes, isEmpty);

    // The rows still follow the model when it moves.
    model
      .._value = const EditorFont(family: 'Maple Mono')
      ..notifyListeners();
    await tester.pump();
    expect(menu(tester), 'Maple Mono');
  });

  testWidgets('a family stored another way stays selected', (tester) async {
    model = _SlowModel(const EditorFont(family: 'Menlo'));
    await pump(tester);

    expect(menu(tester), 'Menlo');
    expect(model.writes, isEmpty);
  });

  testWidgets('the switch turns ligatures off and keeps the family', (
    tester,
  ) async {
    model = _SlowModel(const EditorFont(family: 'Fira Code'));
    await pump(tester);
    expect(ligatures(tester), isTrue);

    await tester.tap(find.byKey(const ValueKey('editor.ligatures')));
    await tester.pump();

    expect(
      model.writes.single.$1,
      const EditorFont(family: 'Fira Code', ligatures: EditorLigatures.off),
    );
    expect(ligatures(tester), isFalse);
  });

  testWidgets('a failed write shows what the editors draw in', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('editor.ligatures')));
    await tester.pump();
    model.answer(error: StateError('link closed'));
    await tester.pump();

    expect(ligatures(tester), isTrue);
    expect(find.text('Bad state: link closed'), findsOneWidget);
    // Reported through the app's error reporter; drained so the framework
    // does not flag it as unexpected.
    expect(tester.takeException(), isA<StateError>());
    // The toast's timer.
    await tester.pump(const Duration(seconds: 5));
  });
}
