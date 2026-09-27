import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

Widget view(EditorController c, {bool locked = false, bool active = true}) =>
    MaterialApp(
      home: Scaffold(
        body: PlanchetteEditor(
          controller: c,
          editingLocked: locked,
          isActive: active,
        ),
      ),
    );

EditorController controller() {
  final c = EditorController(
    displayPath: 'notes.txt',
    initialText: 'text',
    saveDocument: (_, _) async => 'digest',
  );
  addTearDown(c.dispose);
  return c;
}

bool readOnly(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('planchette.document')))
    .readOnly;

void main() {
  testWidgets('a host lock survives the view mounting and rebuilding', (
    tester,
  ) async {
    final c = controller()..editingLocked = true;

    await tester.pumpWidget(view(c));
    await tester.pumpWidget(view(c, active: false));

    expect(c.editingLocked, isTrue);
    expect(readOnly(tester), isTrue);
    expect(c.canSave, isFalse);
    expect(await c.save(), isNull);
  });

  testWidgets('the view lock holds while set and releases on its own', (
    tester,
  ) async {
    final c = controller();

    await tester.pumpWidget(view(c, locked: true));
    expect(c.editingLocked, isTrue);
    expect(c.canSave, isFalse);

    await tester.pumpWidget(view(c));
    expect(c.editingLocked, isFalse);
    expect(readOnly(tester), isFalse);
  });

  testWidgets('each owner clears only its own lock', (tester) async {
    final c = controller()..editingLocked = true;
    await tester.pumpWidget(view(c, locked: true));

    await tester.pumpWidget(view(c));
    expect(c.editingLocked, isTrue, reason: 'the host still holds it');

    await tester.pumpWidget(view(c, locked: true));
    c.editingLocked = false;
    expect(c.editingLocked, isTrue, reason: 'the view still holds it');

    await tester.pumpWidget(view(c));
    expect(c.editingLocked, isFalse);
  });

  testWidgets('a controller leaving the view takes no view lock with it', (
    tester,
  ) async {
    final first = controller();
    final second = controller();

    await tester.pumpWidget(view(first, locked: true));
    await tester.pumpWidget(view(second, locked: true));
    expect(first.editingLocked, isFalse);
    expect(second.editingLocked, isTrue);

    await tester.pumpWidget(const SizedBox());
    expect(second.editingLocked, isFalse);
  });
}
