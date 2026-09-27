import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

CodeEditingController controllerWith(
  String text,
  int start, [
  int? end,
]) => CodeEditingController()
  ..value = TextEditingValue(
    text: text,
    selection: TextSelection(
      baseOffset: start,
      extentOffset: end ?? start,
    ),
  );

void main() {
  group('indent', () {
    test('inserts a tab at a collapsed caret', () {
      final c = controllerWith('ab\ncd', 2);
      c.indent();
      expect(c.text, 'ab\t\ncd');
      expect(c.selection, const TextSelection.collapsed(offset: 3));
      c.dispose();
    });

    test('inserts a tab at the start of the document', () {
      final c = controllerWith('ab', 0);
      c.indent();
      expect(c.text, '\tab');
      expect(c.selection, const TextSelection.collapsed(offset: 1));
      c.dispose();
    });

    test('indents every line a selection touches', () {
      final c = controllerWith('one\ntwo\nthree', 2, 6);
      c.indent();
      expect(c.text, '\tone\n\ttwo\nthree');
      expect(
        c.selection,
        const TextSelection(baseOffset: 0, extentOffset: 10),
      );
      c.dispose();
    });

    test('skips a trailing line when the selection ends at its start', () {
      final c = controllerWith('one\ntwo', 0, 4);
      c.indent();
      expect(c.text, '\tone\ntwo');
      expect(c.selection, const TextSelection(baseOffset: 0, extentOffset: 5));
      c.dispose();
    });

    test('is a no-op on an invalid selection', () {
      final c = controllerWith('ab', 0)
        ..selection = const TextSelection(baseOffset: -1, extentOffset: -1);
      c.indent();
      expect(c.text, 'ab');
      c.dispose();
    });

    test('keeps a backward selection pointing at its anchor', () {
      final c = controllerWith('one\ntwo\nthree', 8, 2);
      c.indent();
      expect(c.text, '\tone\n\ttwo\nthree');
      expect(
        c.selection,
        const TextSelection(baseOffset: 10, extentOffset: 0),
      );
      c.dispose();
    });
  });

  group('outdent', () {
    test('lifts a tab from the caret line', () {
      final c = controllerWith('\tone\ntwo', 2);
      c.outdent();
      expect(c.text, 'one\ntwo');
      expect(c.selection, const TextSelection.collapsed(offset: 1));
      c.dispose();
    });

    test('clamps a caret inside the stripped run to the line start', () {
      final c = controllerWith('    one', 2);
      c.outdent();
      expect(c.text, 'one');
      expect(c.selection, const TextSelection.collapsed(offset: 0));
      c.dispose();
    });

    test('lifts up to four leading spaces', () {
      final c = controllerWith('    one\n  two\n three', 5, 12);
      c.outdent();
      expect(c.text, 'one\ntwo\n three');
      c.dispose();
    });

    test('lifts a tab before a space run rather than the spaces', () {
      final c = controllerWith('\t  one', 3);
      c.outdent();
      expect(c.text, '  one');
      c.dispose();
    });

    test('is a no-op when no touched line is indented', () {
      final c = controllerWith('one\ntwo', 1, 5);
      c.outdent();
      expect(c.text, 'one\ntwo');
      expect(c.selection, const TextSelection(baseOffset: 1, extentOffset: 5));
      c.dispose();
    });

    test('keeps the touched lines selected', () {
      final c = controllerWith('\tone\n\ttwo\nthree', 2, 8);
      c.outdent();
      expect(c.text, 'one\ntwo\nthree');
      expect(c.selection, const TextSelection(baseOffset: 0, extentOffset: 8));
      c.dispose();
    });
  });
}
