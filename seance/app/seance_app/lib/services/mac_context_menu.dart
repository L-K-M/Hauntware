import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SingleActivator;

import 'mac_commands.dart';

/// One row of a native context menu ([showMacContextMenu]): a command, a
/// submenu ([children]) or a separator.
@immutable
final class MacMenuItem {
  const MacMenuItem(
    this.title, {
    this.onSelected,
    this.checked = false,
    this.shortcut,
    this.children,
  }) : _separator = false;

  const MacMenuItem.separator()
    : title = '',
      onSelected = null,
      checked = false,
      shortcut = null,
      children = null,
      _separator = true;

  final String title;

  /// Null shows the row disabled.
  final VoidCallback? onSelected;
  final bool checked;

  /// The chord the menu bar runs the same command with, shown at the
  /// row's trailing edge; a context menu does not bind it.
  final SingleActivator? shortcut;
  final List<MacMenuItem>? children;
  final bool _separator;
}

/// Shows [items] as a native menu at the pointer, the way every Mac app's
/// context menus open, and runs the chosen row's callback after it closes.
/// False when the native side could not show it, so the caller can fall
/// back to its own menu.
Future<bool> showMacContextMenu(
  List<MacMenuItem> items, {
  MethodChannel channel = macMenuChannel,
}) async {
  final callbacks = <String, VoidCallback>{};
  List<Map<String, Object?>> encode(List<MacMenuItem> items) => [
    for (final item in items)
      if (item._separator)
        {'separator': true}
      else
        {
          if (item.onSelected case final callback?)
            'id': _register(callbacks, callback),
          'title': item.title,
          'enabled': item.onSelected != null || item.children != null,
          if (item.checked) 'checked': true,
          ...?_shortcut(item.shortcut),
          if (item.children case final children?) 'items': encode(children),
        },
  ];
  final String? chosen;
  try {
    chosen = await channel.invokeMethod<String>('popUpMenu', {
      'items': encode(items),
    });
  } catch (error) {
    debugPrint('Native context menu failed: $error');
    return false;
  }
  if (chosen != null) callbacks[chosen]?.call();
  return true;
}

String _register(Map<String, VoidCallback> callbacks, VoidCallback callback) {
  final id = '${callbacks.length}';
  callbacks[id] = callback;
  return id;
}

/// The key equivalent AppKit draws for [shortcut]: its character and
/// modifier names.
Map<String, Object?>? _shortcut(SingleActivator? shortcut) {
  if (shortcut == null) return null;
  final label = shortcut.trigger.keyLabel;
  if (label.isEmpty) return null;
  return {
    'key': label.toLowerCase(),
    'modifiers': [
      if (shortcut.meta) 'command',
      if (shortcut.shift) 'shift',
      if (shortcut.alt) 'option',
      if (shortcut.control) 'control',
    ],
  };
}
