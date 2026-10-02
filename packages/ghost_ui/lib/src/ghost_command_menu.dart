import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ghost_chords.dart';

/// One command as a menu sees it: a snapshot resolved by the host — the
/// label already localized, [enabled] and [checked] already read — so the
/// shared renderers never reach back into host state. Hosts rebuild the
/// model whenever their source changes; the snapshot is as fresh as the
/// build that produced it.
final class GhostCommandSpec {
  const GhostCommandSpec({
    this.id,
    required this.label,
    this.enabled = true,
    this.checked,
    this.activators = const [],
    this.mnemonic,
    this.onSelected,
    this.tag,
  });

  /// The command's stable identifier; keys the in-window row
  /// (`menu.item.<id>`) when set. Null leaves the row unkeyed.
  final String? id;

  /// The resolved display label — never ARB/l10n lookups here; hosts own
  /// their localization.
  final String label;

  /// Whether the command applies right now; a disabled command renders
  /// dimmed and never fires.
  final bool enabled;

  /// Toggle state for checkable rows: a native menu checkmark and a
  /// [CheckboxMenuButton] in-window. Null means the command is not a
  /// toggle.
  final bool? checked;

  /// The command's chords, already resolved for the current platform.
  /// Rendered as a display-only hint and, on macOS, offered to the
  /// native menu via the serializer's shortcut rule.
  final List<ShortcutActivator> activators;

  /// The Alt-access letter on the in-window menu bar, Windows and Linux
  /// only. Null leaves the label unmarked; the native menu never sees it.
  final String? mnemonic;

  /// Runs the command on in-window activation (menu click, chord layer).
  /// The macOS serializer prefers its own `activate` callback, which
  /// also receives the bound key equivalent for Edit-menu retargeting.
  final VoidCallback? onSelected;

  /// The host's command object, for adapters that need more than the
  /// snapshot (Poltergeist's `RegisteredCommand`, Séance's tab command).
  final Object? tag;
}

/// One row inside a derived menu — the shared shape both backends render.
sealed class GhostMenuRow {
  const GhostMenuRow();
}

/// A command leaf row.
final class GhostCommandRow extends GhostMenuRow {
  const GhostCommandRow(this.command);
  final GhostCommandSpec command;
}

/// A named submenu grouping command rows ("Sort By", "Recent").
final class GhostSubmenuRow extends GhostMenuRow {
  GhostSubmenuRow({required this.title, required List<GhostCommandRow> items, this.mnemonic})
    : items = List.unmodifiable(items);

  final String title;

  /// The Alt-access letter on the in-window menu bar; see
  /// [GhostCommandSpec.mnemonic].
  final String? mnemonic;

  final List<GhostCommandRow> items;
}

/// A platform-provided native item — used only on macOS for the
/// application and window chrome.
final class GhostProvidedRow extends GhostMenuRow {
  const GhostProvidedRow(this.type);
  final PlatformProvidedMenuItemType type;
}

/// A top-level menu: a localized title plus divider-separated groups of
/// rows in render order.
final class GhostMenu {
  const GhostMenu({
    this.id,
    required this.title,
    this.mnemonic,
    required this.groups,
  });

  /// The host's menu identifier (its menu enum, a label, a window scope) —
  /// opaque to the renderers; used for `menu.<id>` keys and signatures.
  final Object? id;

  final String title;

  /// The Alt-access letter on the in-window menu bar.
  final String? mnemonic;

  /// Sections in order; the renderer inserts a divider between groups.
  final List<List<GhostMenuRow>> groups;
}

// -- Chord → item -------------------------------------------------------

/// The activator a native menu binds as the item's key equivalent.
///
/// A natively bound key equivalent intercepts the keystroke before any
/// in-window surface sees it, so only *modified* chords may bind — an
/// unmodified equivalent (Enter, Tab, a letter) would steal typing and
/// focus navigation.
MenuSerializableShortcut? ghostNativeShortcut(
  List<ShortcutActivator> activators,
) {
  for (final activator in activators) {
    if (activator is SingleActivator) {
      if (!activator.meta && !activator.control && !activator.alt) {
        continue;
      }
      return activator;
    }
    if (activator is CharacterActivator) {
      if (!activator.meta && !activator.control && !activator.alt) {
        continue;
      }
      return activator;
    }
  }
  return null;
}

/// Maps a field-owned macOS chord to the intent a focused text field
/// expects — the same intents the platform Edit verbs would carry, so a
/// natively bound ⌘A/⌘C/⌘X/⌘V/⌘Z/⌘⇧Z/⌘⌫ key equivalent can re-dispatch
/// to a focused [EditableText] instead of running the menu's command.
Intent? ghostEditingTextIntent(MenuSerializableShortcut shortcut) {
  if (shortcut is! SingleActivator) return null;
  if (!shortcut.meta || shortcut.control || shortcut.alt) return null;
  const cause = SelectionChangedCause.keyboard;
  return switch ((shortcut.trigger, shortcut.shift)) {
    (LogicalKeyboardKey.keyA, false) => const SelectAllTextIntent(cause),
    (LogicalKeyboardKey.keyC, false) => CopySelectionTextIntent.copy,
    (LogicalKeyboardKey.keyX, false) =>
      const CopySelectionTextIntent.cut(cause),
    (LogicalKeyboardKey.keyV, false) => const PasteTextIntent(cause),
    (LogicalKeyboardKey.keyZ, false) => const UndoTextIntent(cause),
    (LogicalKeyboardKey.keyZ, true) => const RedoTextIntent(cause),
    (LogicalKeyboardKey.backspace, false) =>
      const DeleteToLineBreakIntent(forward: false),
    _ => null,
  };
}

// -- macOS native serialization ----------------------------------------

/// Produces the native `onSelected` for a leaf row. Returning null keeps
/// the item inert; [shortcut] is the bound key equivalent (null when the
/// command has no native-safe chord), for Edit-menu retargeting.
typedef GhostMenuActivator =
    VoidCallback? Function(
      GhostCommandSpec spec,
      MenuSerializableShortcut? shortcut,
    );

/// The menu bar items for one menu's [groups]: each group a
/// [PlatformMenuItemGroup], command rows serialized with their native
/// key equivalent, submenus as nested [PlatformMenu]s.
///
/// [activate] overrides the click/key-equivalent callback — the native
/// path that needs the bound shortcut (Poltergeist's Edit-menu text
/// intent retargeting). It defaults to [GhostCommandSpec.onSelected].
/// [shortcutFor] picks the bound key equivalent; the default
/// [ghostNativeShortcut] binds only modifier chords.
List<PlatformMenuItem> ghostPlatformMenuGroups(
  List<List<GhostMenuRow>> groups, {
  GhostMenuActivator? activate,
  MenuSerializableShortcut? Function(GhostCommandSpec spec)? shortcutFor,
}) {
  MenuSerializableShortcut? shortcut(GhostCommandSpec spec) =>
      shortcutFor?.call(spec) ?? ghostNativeShortcut(spec.activators);
  VoidCallback? onSelected(
    GhostCommandSpec spec,
    MenuSerializableShortcut? bound,
  ) => spec.enabled ? activate?.call(spec, bound) ?? spec.onSelected : null;
  PlatformMenuItem leaf(GhostCommandSpec spec) {
    final bound = shortcut(spec);
    if (spec.checked case final checked?) {
      return CheckedPlatformMenuItem(
        label: spec.label,
        checked: checked,
        shortcut: bound,
        onSelected: onSelected(spec, bound),
      );
    }
    return PlatformMenuItem(
      label: spec.label,
      shortcut: bound,
      onSelected: onSelected(spec, bound),
    );
  }

  return [
    for (final group in groups)
      PlatformMenuItemGroup(
        members: [
          for (final row in group)
            switch (row) {
              GhostCommandRow(:final command) => leaf(command),
              GhostSubmenuRow(:final title, :final items) => PlatformMenu(
                label: title,
                menus: [
                  PlatformMenuItemGroup(
                    members: [for (final item in items) leaf(item.command)],
                  ),
                ],
              ),
              GhostProvidedRow(:final type) => PlatformProvidedMenuItem(
                type: type,
              ),
            },
        ],
      ),
  ];
}

/// [menus] as top-level [PlatformMenu]s, for a [PlatformMenuBar].
List<PlatformMenu> ghostPlatformMenus(
  List<GhostMenu> menus, {
  GhostMenuActivator? activate,
  MenuSerializableShortcut? Function(GhostCommandSpec spec)? shortcutFor,
}) => [
  for (final menu in menus)
    PlatformMenu(
      label: menu.title,
      menus: ghostPlatformMenuGroups(
        menu.groups,
        activate: activate,
        shortcutFor: shortcutFor,
      ),
    ),
];

/// Positional marker inside a signature; identity-stable across builds.
const _rowBoundary = Object();

/// Everything a native menu item can carry — structure, titles, each
/// command's enablement and bound key equivalent — flattened to scalars
/// and records so [listEquals] can compare two builds field-by-field.
/// A [PlatformMenuBar] host that memoizes its serialization compares two
/// signatures and skips the channel sync when nothing changed.
List<Object?> ghostMenuSignature(
  List<GhostMenu> menus, {
  MenuSerializableShortcut? Function(GhostCommandSpec spec)? shortcutFor,
}) => [
  for (final menu in menus) ...[
    menu.id,
    menu.title,
    for (final group in menu.groups) ...[
      _rowBoundary,
      for (final row in group)
        ..._rowSignature(row, shortcutFor ?? _defaultShortcut),
    ],
  ],
];

MenuSerializableShortcut? _defaultShortcut(GhostCommandSpec spec) =>
    ghostNativeShortcut(spec.activators);

Iterable<Object?> _rowSignature(
  GhostMenuRow row,
  MenuSerializableShortcut? Function(GhostCommandSpec spec) shortcutFor,
) sync* {
  switch (row) {
    case GhostCommandRow(:final command):
      yield (
        command.id,
        command.label,
        command.enabled,
        command.checked,
        shortcutFor(command),
      );
    case GhostSubmenuRow(:final title, :final items):
      yield _rowBoundary;
      yield title;
      for (final item in items) {
        yield* _rowSignature(item, shortcutFor);
      }
    case GhostProvidedRow(:final type):
      yield type;
  }
}

// -- Checked items over the flutter/menu channel ------------------------

/// Adds AppKit checkmarks to Flutter's native menu transport.
///
/// Flutter serializes labels, shortcuts and enablement, but has no menu
/// item state field. The host's runner applies checks after Flutter
/// installs each menu, using the same generated IDs AppKit stores in
/// NSMenuItem.tag — over a per-app channel ([channelName], e.g.
/// `poltergeist/menu_checks`) with a native peer the host keeps
/// (Poltergeist's `MenuChecks.swift`).
final class CheckedPlatformMenuDelegate extends DefaultPlatformMenuDelegate {
  CheckedPlatformMenuDelegate({required String channelName})
    : super(channel: _CheckedMenuChannel(MethodChannel(channelName)));
}

/// A native checkable row; [checked] is a snapshot, like its label and
/// shortcut.
final class CheckedPlatformMenuItem extends PlatformMenuItem {
  const CheckedPlatformMenuItem({
    required super.label,
    required this.checked,
    super.shortcut,
    super.onSelected,
  });

  final bool checked;

  @override
  Iterable<Map<String, Object?>> toChannelRepresentation(
    PlatformMenuDelegate delegate, {
    required MenuItemSerializableIdGenerator getId,
  }) => [
    {...PlatformMenuItem.serialize(this, delegate, getId), 'checked': checked},
  ];
}

final class _CheckedMenuChannel extends OptionalMethodChannel {
  const _CheckedMenuChannel(this._checks) : super('flutter/menu');

  final MethodChannel _checks;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    final result = await super.invokeMethod<T>(method, arguments);
    if (method == 'Menu.setMenus') {
      final states = <String, bool>{};
      void collect(List<dynamic> items) {
        for (final item in items.cast<Map<dynamic, dynamic>>()) {
          if (item['checked'] case final bool checked) {
            states['${item['id']}'] = checked;
          }
          if (item['children'] case final List<dynamic> children) {
            collect(children);
          }
        }
      }

      collect((arguments as Map<dynamic, dynamic>)['0'] as List<dynamic>);
      // Waiting for Flutter's reply guarantees that the new NSMenu exists.
      // IDs increase across pushes, so a delayed earlier reply cannot alter
      // the checkmarks in a newer menu or another workspace's menu.
      await _checks.invokeMethod<void>('setChecked', states);
    }
    return result;
  }
}

// -- In-window (Flutter) rendering --------------------------------------

/// A menu label marked for [MenuAcceleratorLabel]: an `&` before the
/// mnemonic's occurrence — at the start of a word when the letter starts
/// one, so "Save &As" beats "S&ave As" — with any literal `&` escaped so
/// the marker stays unambiguous. A label that has lost its mnemonic letter
/// (renamed, localized) comes back unmarked rather than underlining a
/// character the user cannot see.
String menuAcceleratorLabel(String label, String mnemonic) {
  final escaped = label.replaceAll('&', '&&');
  final letter = mnemonic.toLowerCase();
  if (letter.isEmpty) return escaped;
  final letters = escaped.toLowerCase();
  var at = -1;
  for (var i = 0; i < letters.length; i++) {
    if (letters.codeUnitAt(i) != letter.codeUnitAt(0)) continue;
    final start = i == 0 || !_isLetter(escaped.codeUnitAt(i - 1));
    if (at < 0) at = i;
    if (start) {
      at = i;
      break;
    }
  }
  if (at < 0) return escaped;
  return '${escaped.substring(0, at)}&${escaped.substring(at)}';
}

bool _isLetter(int codeUnit) =>
    (codeUnit >= 0x41 && codeUnit <= 0x5a) ||
    (codeUnit >= 0x61 && codeUnit <= 0x7a);

/// The trailing shortcut hint a menu row shows: the command's first
/// activator — the chord layer's own binding, so hint and dispatch
/// cannot drift — spelled by the formatter, and set in the secondary
/// text colour so the label leads. Display only: the chord layer
/// dispatches.
class GhostShortcutHint extends StatelessWidget {
  const GhostShortcutHint(this.activator, {super.key, this.enabled = true, this.color});

  /// The hint for [spec]'s first activator, or null when it has none.
  static GhostShortcutHint? forSpec(GhostCommandSpec spec, {Color? color}) {
    if (spec.activators.isEmpty) return null;
    return GhostShortcutHint(
      spec.activators.first,
      enabled: spec.enabled,
      color: color,
    );
  }

  final ShortcutActivator activator;

  /// A disabled row dims its hint with its label.
  final bool enabled;

  /// The secondary text colour; defaults to
  /// `ColorScheme.onSurfaceVariant`. Hosts with their own chrome tokens
  /// pass it here.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = formatShortcutActivator(activator, theme.platform);
    if (text == null) return const SizedBox.shrink();
    final effective = enabled
        ? color ?? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.onSurface.withValues(alpha: 0.38);
    return Text(
      text,
      style: TextStyle(
        color: effective,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// Runs a row's command on in-window activation. Hosts whose registry
/// route is a single runner pass it here instead of per-spec
/// [GhostCommandSpec.onSelected]; null leaves [onSelected] in charge.
typedef GhostRowActivate = void Function(GhostCommandSpec spec);

/// The row widgets for one group of a menu popup: command rows keyed
/// `menu.item.<id>` with a display-only shortcut hint and activation
/// through [activate] (or [GhostCommandSpec.onSelected] when it is
/// null); submenus nested one level.
///
/// [trailingFor] overrides the hint widget; the default is
/// [GhostShortcutHint.forSpec].
List<Widget> _menuRowWidgets(
  List<GhostMenuRow> rows, {
  GhostRowActivate? activate,
  Widget? Function(GhostCommandSpec spec)? trailingFor,
}) {
  Widget label(String text, String? mnemonic) => mnemonic == null
      ? Text(text)
      : MenuAcceleratorLabel(menuAcceleratorLabel(text, mnemonic));
  VoidCallback? onPressed(GhostCommandSpec spec) => spec.enabled
      ? activate == null
            ? spec.onSelected
            : () => activate(spec)
      : null;
  return [
    for (final row in rows)
      switch (row) {
        GhostCommandRow(:final command) => switch (command.checked) {
          null => MenuItemButton(
            key: command.id == null
                ? null
                : ValueKey('menu.item.${command.id}'),
            trailingIcon:
                trailingFor?.call(command) ??
                GhostShortcutHint.forSpec(command),
            onPressed: onPressed(command),
            child: label(command.label, command.mnemonic),
          ),
          // CheckboxMenuButton forwards its key to the MenuItemButton it
          // builds, which would put `menu.item.<id>` on two widgets; the
          // subtree carries it once, like the plain rows.
          final checked => KeyedSubtree(
            key: command.id == null
                ? null
                : ValueKey('menu.item.${command.id}'),
            child: CheckboxMenuButton(
              trailingIcon:
                  trailingFor?.call(command) ??
                  GhostShortcutHint.forSpec(command),
              value: checked,
              onChanged: onPressed(command) == null
                  ? null
                  : (_) => onPressed(command)!(),
              child: label(command.label, command.mnemonic),
            ),
          ),
        },
        GhostSubmenuRow(:final title, :final items, :final mnemonic) =>
          SubmenuButton(
            menuChildren: _menuRowWidgets(
              items,
              activate: activate,
              trailingFor: trailingFor,
            ),
            child: label(title, mnemonic),
          ),
        // Provided rows are macOS chrome; the model never emits them on
        // other platforms.
        GhostProvidedRow() => const SizedBox.shrink(),
      },
  ];
}

/// One menu's popup children: each group's rows, divider-separated.
/// [divider] defaults to the Ghost menu strip's inset divider.
List<Widget> _menuEntries(
  GhostMenu menu, {
  GhostRowActivate? activate,
  Widget? Function(GhostCommandSpec spec)? trailingFor,
  Widget divider = const Divider(height: 9, indent: 12, endIndent: 12),
}) => [
  for (var i = 0; i < menu.groups.length; i++) ...[
    if (i > 0) divider,
    ..._menuRowWidgets(
      menu.groups[i],
      activate: activate,
      trailingFor: trailingFor,
    ),
  ],
];

/// The top-level menu buttons of an in-window bar or ☰ anchor: one
/// [SubmenuButton] per menu, keyed `menu.<id>` when the menu has one.
List<Widget> ghostMenuBarChildren(
  List<GhostMenu> menus, {
  GhostRowActivate? activate,
  Widget? Function(GhostCommandSpec spec)? trailingFor,
  Widget divider = const Divider(height: 9, indent: 12, endIndent: 12),
}) => [
  for (final menu in menus)
    SubmenuButton(
      key: menu.id == null ? null : ValueKey('menu.${_menuId(menu.id!)}'),
      menuChildren: _menuEntries(
        menu,
        activate: activate,
        trailingFor: trailingFor,
        divider: divider,
      ),
      child: menu.mnemonic == null
          ? Text(menu.title)
          : MenuAcceleratorLabel(menuAcceleratorLabel(menu.title, menu.mnemonic!)),
    ),
];

/// The key suffix for a menu id: enums contribute their name, anything
/// else its own text.
String _menuId(Object id) => id is Enum ? id.name : '$id';
