import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/settings_models.dart';
import 'package:poltergeist_app/ui/settings/editor_text_size_settings.dart';

/// The Settings window's model: a write lands only when the app answers.
final class _SlowModel extends ChangeNotifier implements EditorTextSizeModel {
  int _value = 14;
  final writes = <(int, Completer<void>)>[];

  @override
  int get value => _value;

  @override
  Future<void> setTextSize(int size) {
    final done = Completer<void>();
    writes.add((size, done));
    return done.future;
  }

  /// The app's answer: the snapshot moves the size, or the write fails.
  void answer({Object? error}) {
    final (size, done) = writes.removeAt(0);
    if (error != null) {
      done.completeError(error);
      return;
    }
    _value = size;
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
      home: Scaffold(body: EditorTextSizeSection(model: model)),
    ),
  );

  Slider slider(WidgetTester tester) =>
      tester.widget<Slider>(find.byKey(const ValueKey('editor.textSize')));

  testWidgets('a released thumb stays put until the app catches up', (
    tester,
  ) async {
    await pump(tester);

    slider(tester).onChanged!(20);
    await tester.pump();
    slider(tester).onChangeEnd!(20);
    await tester.pump();
    // Released, but the app has not answered: no jump back to 14.
    expect(slider(tester).value, 20);

    model.answer();
    await tester.pump();
    expect(slider(tester).value, 20);

    // Caught up, the thumb follows the model again (a zoom in an editor).
    model
      .._value = 22
      ..notifyListeners();
    await tester.pump();
    expect(slider(tester).value, 22);
  });

  testWidgets('a failed write puts the thumb back where the editors are', (
    tester,
  ) async {
    await pump(tester);

    slider(tester).onChanged!(30);
    await tester.pump();
    slider(tester).onChangeEnd!(30);
    model.answer(error: StateError('link closed'));
    await tester.pump();

    expect(slider(tester).value, 14);
    expect(find.text('Bad state: link closed'), findsOneWidget);
    // Reported through the app's error reporter; drained so the framework
    // does not flag it as unexpected.
    expect(tester.takeException(), isA<StateError>());
    // The toast's timer.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a superseded write that fails leaves the thumb to the newer', (
    tester,
  ) async {
    await pump(tester);

    slider(tester).onChanged!(20);
    await tester.pump();
    slider(tester).onChanged!(22);
    await tester.pump();
    // The write for 20 fails while the one for 22 is still out.
    model.answer(error: StateError('link closed'));
    await tester.pump();

    expect(slider(tester).value, 22);
    expect(find.text('Bad state: link closed'), findsNothing);
    // Still reported, for the record.
    expect(tester.takeException(), isA<StateError>());

    model.answer();
    await tester.pump();
    expect(slider(tester).value, 22);
  });

  testWidgets('the newest write failing after a superseded one resets', (
    tester,
  ) async {
    await pump(tester);

    slider(tester).onChanged!(20);
    await tester.pump();
    slider(tester).onChanged!(22);
    await tester.pump();
    model.answer(error: StateError('link closed'));
    await tester.pump();
    expect(tester.takeException(), isA<StateError>());

    // The newest write fails too: it owns the thumb and the toast.
    model.answer(error: StateError('link closed'));
    await tester.pump();

    expect(slider(tester).value, 14);
    expect(find.text('Bad state: link closed'), findsOneWidget);
    expect(tester.takeException(), isA<StateError>());
    // The toast's timer.
    await tester.pump(const Duration(seconds: 5));
  });
}
