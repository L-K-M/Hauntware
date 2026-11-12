import 'dart:collection';

import 'package:flutter/services.dart';

/// What produced a buffer change, which decides how it groups into undo
/// steps.
enum EditOrigin {
  /// Typing, deleting or an input method's commit. Consecutive one
  /// character inserts or deletes at the caret merge into one step.
  typing,

  /// A command's write: a paste, a text tool, Find/Replace, a line
  /// command or a format conversion. Always a step of its own.
  command,
}

/// The editor's undo and redo history.
///
/// Each step stores what changed rather than a copy of the document: the
/// replaced range with its old and new text, plus the selection before and
/// after, so a one-character edit costs a few bytes whatever the size of
/// the document. Steps are dropped oldest first once the text they hold
/// passes [budgetBytes].
///
/// Typing groups the way Flutter's own text field history did, refined to
/// word boundaries: one-character inserts (or deletes) that continue at
/// the caret within [typingPause] of each other form one step, and a step
/// ends when the caret moves, the kind of edit changes, a new word starts
/// after whitespace, or a command writes.
final class EditHistory {
  EditHistory({
    this.budgetBytes = defaultBudgetBytes,
    this.typingPause = defaultTypingPause,
  });

  /// How much text the history may hold, counted at two bytes per UTF-16
  /// code unit plus a fixed cost per step. 16 MiB holds a whole-document
  /// rewrite of the largest file the editor loads (4 MB) or a very long
  /// typing session, while bounding what each open document keeps.
  static const defaultBudgetBytes = 16 * 1024 * 1024;

  /// The longest gap between keystrokes that still continues a step:
  /// Flutter's own undo throttle, so typing groups as it did before.
  static const defaultTypingPause = Duration(milliseconds: 500);

  /// What a step costs beyond its text: the objects and selections that
  /// carry it, rounded up.
  static const _stepOverheadBytes = 96;

  /// Edits up to this many UTF-16 code units are keystrokes: a character,
  /// a surrogate pair, or a typed bracket with the closer pair completion
  /// added.
  static const _keystrokeLength = 2;

  final int budgetBytes;
  final Duration typingPause;

  final _undo = ListQueue<_Step>();
  final _redo = <_Step>[];
  int _bytes = 0;

  /// Whether the newest undo step may still take typing.
  bool _open = false;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// The bytes the history holds now, as [budgetBytes] counts them.
  int get storedBytes => _bytes;

  /// The undo steps held, oldest first evicted.
  int get undoDepth => _undo.length;

  /// Forgets every step, as a load or reload does: undo must not reach back
  /// into the previous text.
  void clear() {
    _undo.clear();
    _redo.clear();
    _bytes = 0;
    _open = false;
  }

  /// Ends the step typing would continue, so the next edit starts a new one.
  void seal() => _open = false;

  /// Records the change from [before] to [after]. Nothing is recorded when
  /// the texts are equal. A new edit clears redo.
  void record({
    required String before,
    required String after,
    required TextSelection selectionBefore,
    required TextSelection selectionAfter,
    required EditOrigin origin,
    required DateTime at,
  }) {
    final edit = _Edit.between(before, after);
    if (edit == null) return;
    final selectedBefore = selectionBefore.isValid
        ? selectionBefore
        : TextSelection.collapsed(offset: edit.start + edit.removed.length);
    final selectedAfter = selectionAfter.isValid
        ? selectionAfter
        : TextSelection.collapsed(offset: edit.start + edit.inserted.length);
    for (final step in _redo) {
      _bytes -= step.bytes;
    }
    _redo.clear();

    final kind = origin == EditOrigin.typing ? edit.typingKind : null;
    if (kind != null && _merge(edit, kind, selectedBefore, selectedAfter, at)) {
      _evict();
      return;
    }
    final step = _Step(
      edits: [edit],
      selectionBefore: selectedBefore,
      selectionAfter: selectedAfter,
      kind: kind,
      lastAt: at,
    );
    _undo.addLast(step);
    _bytes += step.bytes;
    _open = kind != null;
    _evict();
  }

  /// Reverts the newest step in [current], which must be the text the
  /// history last recorded, and returns the value to show; null when there
  /// is nothing to undo. A [current] the step does not match means the
  /// history lost track of the buffer: it is cleared rather than applied.
  TextEditingValue? undo(String current) {
    if (_undo.isEmpty) return null;
    final step = _undo.removeLast();
    _open = false;
    var text = current;
    for (final edit in step.edits.reversed) {
      final reverted = edit.revert(text);
      if (reverted == null) {
        clear();
        return null;
      }
      text = reverted;
    }
    _redo.add(step);
    return TextEditingValue(
      text: text,
      selection: _clamp(step.selectionBefore, text.length),
    );
  }

  /// Reapplies the step [undo] last reverted; null when there is none.
  TextEditingValue? redo(String current) {
    if (_redo.isEmpty) return null;
    final step = _redo.removeLast();
    _open = false;
    var text = current;
    for (final edit in step.edits) {
      final applied = edit.apply(text);
      if (applied == null) {
        clear();
        return null;
      }
      text = applied;
    }
    _undo.addLast(step);
    return TextEditingValue(
      text: text,
      selection: _clamp(step.selectionAfter, text.length),
    );
  }

  bool _merge(
    _Edit edit,
    _TypingKind kind,
    TextSelection selectionBefore,
    TextSelection selectionAfter,
    DateTime at,
  ) {
    if (!_open || _undo.isEmpty) return false;
    final step = _undo.last;
    if (at.difference(step.lastAt) >= typingPause) return false;
    if (selectionBefore != step.selectionAfter) return false;
    if (kind == _TypingKind.delete) {
      if (step.kind != _TypingKind.delete) return false;
    } else {
      // Typing over a selection starts an insert step; plain inserts
      // continue it. A replacement never continues a step.
      if (edit.removed.isNotEmpty || step.kind != _TypingKind.insert) {
        return false;
      }
      if (_startsWord(step.edits.last.inserted, edit.inserted)) return false;
    }
    _bytes -= step.bytes;
    final joined = step.edits.last.join(edit);
    if (joined != null) {
      step.edits.last = joined;
    } else {
      step.edits.add(edit);
    }
    step
      ..selectionAfter = selectionAfter
      ..lastAt = at;
    _bytes += step.bytes;
    return true;
  }

  /// Whether [next] begins a word after the whitespace [previous] ends in:
  /// undo then takes back one word at a time.
  static bool _startsWord(String previous, String next) {
    if (previous.isEmpty || next.isEmpty) return false;
    return _isSpace(previous.codeUnitAt(previous.length - 1)) &&
        !_isSpace(next.codeUnitAt(0));
  }

  static bool _isSpace(int unit) =>
      unit == 0x20 || unit == 0x09 || unit == 0x0a || unit == 0x0d;

  /// Drops the oldest steps until the history fits [budgetBytes]. The
  /// newest step always stays, however large, so the last edit (a whole
  /// document tool run, say) can be undone.
  void _evict() {
    while (_bytes > budgetBytes && _undo.length > 1) {
      _bytes -= _undo.removeFirst().bytes;
    }
  }

  static TextSelection _clamp(TextSelection selection, int length) =>
      selection.copyWith(
        baseOffset: selection.baseOffset.clamp(0, length),
        extentOffset: selection.extentOffset.clamp(0, length),
      );
}

enum _TypingKind {
  /// A keystroke's insert, or typing over a selection.
  insert,

  /// A keystroke's delete, backward or forward.
  delete,
}

/// [removed] at [start] replaced by [inserted].
final class _Edit {
  const _Edit(this.start, this.removed, this.inserted);

  /// The smallest edit that turns [before] into [after], or null when they
  /// are equal: the text between their common prefix and common suffix.
  static _Edit? between(String before, String after) {
    if (identical(before, after)) return null;
    final shorter = before.length < after.length ? before.length : after.length;
    var prefix = 0;
    while (prefix < shorter &&
        before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
      prefix++;
    }
    if (prefix == before.length && prefix == after.length) return null;
    var suffix = 0;
    while (suffix < shorter - prefix &&
        before.codeUnitAt(before.length - 1 - suffix) ==
            after.codeUnitAt(after.length - 1 - suffix)) {
      suffix++;
    }
    return _Edit(
      prefix,
      before.substring(prefix, before.length - suffix),
      after.substring(prefix, after.length - suffix),
    );
  }

  final int start;
  final String removed;
  final String inserted;

  int get bytes => (removed.length + inserted.length) * 2;

  /// How a typed edit groups, or null for one too large to be a keystroke.
  _TypingKind? get typingKind {
    if (inserted.isEmpty) {
      return removed.length <= EditHistory._keystrokeLength
          ? _TypingKind.delete
          : null;
    }
    return inserted.length <= EditHistory._keystrokeLength
        ? _TypingKind.insert
        : null;
  }

  /// The text with this edit taken back, or null when [text] does not hold
  /// [inserted] where this edit left it.
  String? revert(String text) {
    final end = start + inserted.length;
    if (end > text.length || !text.startsWith(inserted, start)) return null;
    return text.replaceRange(start, end, removed);
  }

  /// The text with this edit made again, or null when [text] does not hold
  /// [removed] where it was.
  String? apply(String text) {
    final end = start + removed.length;
    if (end > text.length || !text.startsWith(removed, start)) return null;
    return text.replaceRange(start, end, inserted);
  }

  /// This edit followed by [next] as one edit, when [next] continues it:
  /// an insert right after this one's inserted text, a backspace right
  /// before it, or a forward delete at the same place.
  _Edit? join(_Edit next) {
    if (next.removed.isEmpty && next.start == start + inserted.length) {
      return _Edit(start, removed, inserted + next.inserted);
    }
    if (next.inserted.isEmpty && inserted.isEmpty) {
      if (next.start + next.removed.length == start) {
        return _Edit(next.start, next.removed + removed, '');
      }
      if (next.start == start) {
        return _Edit(start, removed + next.removed, '');
      }
    }
    return null;
  }
}

/// One undo step: the edits it made, in order.
final class _Step {
  _Step({
    required this.edits,
    required this.selectionBefore,
    required this.selectionAfter,
    required this.kind,
    required this.lastAt,
  });

  final List<_Edit> edits;
  final TextSelection selectionBefore;
  TextSelection selectionAfter;

  /// The typing this step groups, or null for a step typing never joins.
  final _TypingKind? kind;
  DateTime lastAt;

  int get bytes {
    var total = EditHistory._stepOverheadBytes;
    for (final edit in edits) {
      total += edit.bytes;
    }
    return total;
  }
}
