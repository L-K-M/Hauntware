import 'package:planchette_core/planchette_core.dart' show LineDirection;

import 'editor_controller.dart';

/// The editing commands Planchette's Edit and Find menus offer, for
/// surfaces that list them without a menu bar. The text-tools browser shows
/// them after the tool groups, so a host's single header entry reaches
/// them too, including on a phone without a hardware keyboard.
///
/// Each command keeps its controller method's own guard; its requirement
/// only decides whether a row is offered as enabled.
enum EditorCommand {
  duplicateLines(_Requirement.editableText),
  moveLinesUp(_Requirement.editableText),
  moveLinesDown(_Requirement.editableText),
  deleteLines(_Requirement.editableText),
  joinLines(_Requirement.editableText),
  toggleComment(_Requirement.commentSyntax),
  selectLine(_Requirement.movableCaret),
  selectParagraph(_Requirement.movableCaret),
  selectEnclosingBrackets(_Requirement.movableCaret),
  insertLineAbove(_Requirement.editableText),
  insertLineBelow(_Requirement.editableText),
  copyLine(_Requirement.movableCaret),
  cutLine(_Requirement.editableText),
  incrementNumber(_Requirement.editableText),
  decrementNumber(_Requirement.editableText),
  pasteAndMatchIndentation(_Requirement.editableText),
  goToMatchingBracket(_Requirement.movableCaret),
  selectToMatchingBracket(_Requirement.movableCaret),
  findInSelection(_Requirement.selection);

  const EditorCommand(this._requirement);

  /// What the document must allow for the command to apply.
  final _Requirement _requirement;
}

/// The controller state an [EditorCommand] needs, mirroring the rules the
/// standalone app's menus enable their rows by.
enum _Requirement {
  /// An editable buffer: see [EditorController.canEditText].
  editableText,

  /// An editable buffer whose language has a comment marker: see
  /// [EditorController.canToggleComment].
  commentSyntax,

  /// A caret that may move. Selecting and copying edit nothing, so a
  /// locked document allows them: see [EditorController.canMoveCaret].
  movableCaret,

  /// A non-empty selection in a loaded document.
  selection,
}

/// Runs [EditorCommand]s against the controller's existing methods.
extension EditorCommandRunner on EditorController {
  /// Whether [command] applies now. Host and view locks both refuse the
  /// editing commands through [EditorController.canEditText].
  bool canRunCommand(EditorCommand command) => switch (command._requirement) {
    _Requirement.editableText => canEditText,
    _Requirement.commentSyntax => canToggleComment,
    _Requirement.movableCaret => canMoveCaret,
    _Requirement.selection => !isLoading && error == null && hasSelection,
  };

  /// Runs [command] and reports whether it applied: false when its
  /// guard refused or it found nothing to act on. The clipboard commands
  /// complete once the clipboard has answered.
  Future<bool> runCommand(EditorCommand command) async => switch (command) {
    EditorCommand.duplicateLines => duplicateLines(),
    EditorCommand.moveLinesUp => moveLines(LineDirection.up),
    EditorCommand.moveLinesDown => moveLines(LineDirection.down),
    EditorCommand.deleteLines => deleteLines(),
    EditorCommand.joinLines => joinLines(),
    EditorCommand.toggleComment => toggleComment(),
    EditorCommand.selectLine => selectLine(),
    EditorCommand.selectParagraph => selectParagraph(),
    EditorCommand.selectEnclosingBrackets => selectEnclosingBrackets(),
    EditorCommand.insertLineAbove => insertLineAbove(),
    EditorCommand.insertLineBelow => insertLineBelow(),
    EditorCommand.copyLine => await copyLine(),
    EditorCommand.cutLine => await cutLine(),
    EditorCommand.incrementNumber => incrementNumber(),
    EditorCommand.decrementNumber => decrementNumber(),
    EditorCommand.pasteAndMatchIndentation => await pasteAndMatchIndentation(),
    EditorCommand.goToMatchingBracket => goToMatchingBracket(),
    EditorCommand.selectToMatchingBracket => goToMatchingBracket(extend: true),
    EditorCommand.findInSelection => _findInSelection(),
  };

  bool _findInSelection() {
    if (!canRunCommand(EditorCommand.findInSelection)) return false;
    findInSelection();
    return true;
  }
}
