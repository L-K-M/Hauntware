import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shared file-browser navigation. Hosts retain their selection and file
/// operations; this vocabulary keeps platform chords and cursor bounds alike.
enum GhostFileListCommand {
  previous,
  next,
  first,
  last,
  pagePrevious,
  pageNext,
  open,
  parent,
  rename,
  selectAll,
  clearSelection,
  contextMenu,
}

@immutable
class GhostFileListKey {
  const GhostFileListKey(this.command, {this.extendSelection = false});

  final GhostFileListCommand command;
  final bool extendSelection;
}

/// Resolves exact chords, never treating Cmd-Up as an ordinary Up. Only
/// selection movement repeats: holding Open or Parent cannot race through
/// directories. Callers consume recognized repeats without invoking them.
/// Return renames on macOS only when the host offers rename; otherwise it
/// opens, as Enter does on the other platforms.
GhostFileListKey? ghostFileListKey(
  KeyEvent event,
  TargetPlatform platform, {
  bool canRename = false,
}) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
  final keys = HardwareKeyboard.instance;
  final key = event.logicalKey;
  final shift = keys.isShiftPressed;
  final control = keys.isControlPressed;
  final meta = keys.isMetaPressed;
  final alt = keys.isAltPressed;
  final mac = platform == TargetPlatform.macOS;

  if (!shift && (mac ? meta && !control && !alt : alt && !control && !meta)) {
    if (key == LogicalKeyboardKey.arrowUp) {
      return const GhostFileListKey(GhostFileListCommand.parent);
    }
    if (mac &&
        (key == LogicalKeyboardKey.arrowDown ||
            key == LogicalKeyboardKey.keyO)) {
      return const GhostFileListKey(GhostFileListCommand.open);
    }
  }
  if (!shift &&
      !alt &&
      (mac ? meta && !control : control && !meta) &&
      key == LogicalKeyboardKey.keyA) {
    return const GhostFileListKey(GhostFileListCommand.selectAll);
  }
  if (control || meta || alt) return null;

  final movement = switch (key) {
    LogicalKeyboardKey.arrowUp => GhostFileListCommand.previous,
    LogicalKeyboardKey.arrowDown => GhostFileListCommand.next,
    LogicalKeyboardKey.home => GhostFileListCommand.first,
    LogicalKeyboardKey.end => GhostFileListCommand.last,
    LogicalKeyboardKey.pageUp => GhostFileListCommand.pagePrevious,
    LogicalKeyboardKey.pageDown => GhostFileListCommand.pageNext,
    _ => null,
  };
  if (movement != null) {
    return GhostFileListKey(movement, extendSelection: shift);
  }
  if (key == LogicalKeyboardKey.f10 && shift) {
    return const GhostFileListKey(GhostFileListCommand.contextMenu);
  }
  if (shift) return null;
  final command = switch (key) {
    LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter =>
      mac && canRename
          ? GhostFileListCommand.rename
          : GhostFileListCommand.open,
    LogicalKeyboardKey.f2 when !mac && canRename => GhostFileListCommand.rename,
    LogicalKeyboardKey.backspace when !mac => GhostFileListCommand.parent,
    LogicalKeyboardKey.escape => GhostFileListCommand.clearSelection,
    LogicalKeyboardKey.contextMenu => GhostFileListCommand.contextMenu,
    _ => null,
  };
  return command == null ? null : GhostFileListKey(command);
}

/// Returns the bounded target of a selection move, or null for a verb or
/// empty listing. An absent cursor starts at the first row moving forward,
/// and at the last row moving backward, without skipping an item.
int? ghostFileListTargetIndex(
  GhostFileListCommand command, {
  required int? currentIndex,
  required int itemCount,
  int pageSize = 1,
}) {
  if (itemCount <= 0) return null;
  final current =
      currentIndex != null && currentIndex >= 0 && currentIndex < itemCount
      ? currentIndex
      : null;
  final page = pageSize < 1 ? 1 : pageSize;
  final target = switch (command) {
    GhostFileListCommand.previous =>
      current == null ? itemCount - 1 : current - 1,
    GhostFileListCommand.next => current == null ? 0 : current + 1,
    GhostFileListCommand.first => 0,
    GhostFileListCommand.last => itemCount - 1,
    GhostFileListCommand.pagePrevious =>
      current == null ? itemCount - 1 : current - page,
    GhostFileListCommand.pageNext => current == null ? 0 : current + page,
    _ => null,
  };
  return target?.clamp(0, itemCount - 1);
}

/// Keeps a fixed-extent listing's cursor visible without overscrolling when
/// its last row is only partly visible or the viewport is taller than it.
/// [leadingExtent] accounts for a header that scrolls above the first row.
void ghostRevealFileListIndex(
  ScrollController scroll,
  int index,
  double extent, {
  double leadingExtent = 0,
}) {
  if (!scroll.hasClients) return;
  final position = scroll.position;
  final top = leadingExtent + index * extent;
  final bottom = top + extent;
  final double target;
  if (top < position.pixels) {
    target = top;
  } else if (bottom > position.pixels + position.viewportDimension) {
    target = bottom - position.viewportDimension;
  } else {
    return;
  }
  scroll.jumpTo(
    target.clamp(position.minScrollExtent, position.maxScrollExtent),
  );
}
