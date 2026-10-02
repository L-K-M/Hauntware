import 'package:flutter/material.dart';

const _desktopRowExtent = 26.0;
const _desktopFontSize = 13.0;
const _menuRadius = 8.0;
const _minimumCornerScale = 1.0;
const _iconSize = 16.0;
const _viewportInset = 8.0;
const _panelElevation = 3.0;
const _rowPadding = EdgeInsets.symmetric(horizontal: 10);
const _panelPadding = EdgeInsets.symmetric(vertical: 4);

bool _desktop(TargetPlatform platform) => switch (platform) {
  TargetPlatform.macOS ||
  TargetPlatform.windows ||
  TargetPlatform.linux => true,
  _ => false,
};

/// Poltergeist's compact menu skin, shared by all three Ghost apps.
/// Hosts keep their palette and font; desktop panels stay rounded even
/// when a host theme makes its other surfaces square.
abstract final class GhostMenuTheme {
  static ThemeData apply(ThemeData theme, {double? cornerScale}) {
    if (!_desktop(theme.platform)) return theme;

    final shape = cornerScale == null
        ? theme.menuTheme.style?.shape?.resolve({}) ??
              const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(_menuRadius)),
              )
        : RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(
              _menuRadius *
                  cornerScale.clamp(_minimumCornerScale, double.infinity),
            ),
          );
    final text = theme.textTheme.bodyMedium!.copyWith(
      fontSize: _desktopFontSize,
    );
    return theme.copyWith(
      menuTheme: MenuThemeData(
        style: MenuStyle(
          shape: WidgetStatePropertyAll(shape),
          padding: const WidgetStatePropertyAll(_panelPadding),
        ),
      ),
      menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(
            Size(64, _desktopRowExtent),
          ),
          padding: const WidgetStatePropertyAll(_rowPadding),
          visualDensity: VisualDensity.standard,
          iconSize: const WidgetStatePropertyAll(_iconSize),
          textStyle: WidgetStatePropertyAll(text),
        ),
      ),
      popupMenuTheme: theme.popupMenuTheme.copyWith(
        shape: shape,
        menuPadding: _panelPadding,
        textStyle: text,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => text.copyWith(
            color: states.contains(WidgetState.disabled)
                ? theme.colorScheme.onSurface.withValues(alpha: 0.38)
                : theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

/// A popup-route row with the same metrics as a MenuAnchor row.
/// Keeping Flutter's route preserves dismissal, focus and keyboard traversal.
class GhostMenuItem<T> extends PopupMenuItem<T> {
  GhostMenuItem({
    super.key,
    required BuildContext context,
    required String label,
    IconData? icon,
    Color? iconColor,
    Widget? shortcut,
    super.value,
    super.onTap,
    super.enabled = true,
  }) : super(
         height: _desktop(Theme.of(context).platform)
             ? _desktopRowExtent
             : kMinInteractiveDimension,
         padding: _rowPadding,
         child: _MenuLabel(
           label: label,
           icon: icon,
           iconColor: iconColor,
           shortcut: shortcut,
           enabled: enabled,
         ),
       );
}

class _MenuLabel extends StatelessWidget {
  const _MenuLabel({
    required this.label,
    required this.enabled,
    this.icon,
    this.iconColor,
    this.shortcut,
  });

  final String label;
  final bool enabled;
  final IconData? icon;
  final Color? iconColor;
  final Widget? shortcut;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        if (icon != null) ...[
          Icon(
            icon,
            size: _iconSize,
            color: enabled
                ? iconColor ?? scheme.primary
                : scheme.onSurface.withValues(alpha: 0.38),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(child: Text(label)),
        if (shortcut != null) ...[
          const SizedBox(width: 24),
          DefaultTextStyle.merge(
            style: TextStyle(
              color: enabled
                  ? scheme.onSurfaceVariant
                  : scheme.onSurface.withValues(alpha: 0.38),
            ),
            child: shortcut!,
          ),
        ],
      ],
    );
  }
}

/// The inset separator used by the pane context menu.
class GhostMenuDivider extends PopupMenuEntry<Never> {
  const GhostMenuDivider({super.key});

  @override
  double get height => 9;

  @override
  bool represents(Never? value) => false;

  @override
  State<GhostMenuDivider> createState() => _GhostMenuDividerState();
}

class _GhostMenuDividerState extends State<GhostMenuDivider> {
  @override
  Widget build(BuildContext context) =>
      const Divider(height: 9, indent: 12, endIndent: 12);
}

/// Uses Flutter's localized actions and clipboard guards, changing only the
/// desktop presentation. Touch keeps its platform selection toolbar.
Widget ghostTextContextMenu(BuildContext context, EditableTextState field) {
  if (!_desktop(Theme.of(context).platform)) {
    return AdaptiveTextSelectionToolbar.editableText(editableTextState: field);
  }
  return Theme(
    data: GhostMenuTheme.apply(Theme.of(context)),
    child: _SelectionMenu(field: field),
  );
}

class _SelectionMenu extends StatelessWidget {
  const _SelectionMenu({required this.field});

  final EditableTextState field;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final apple = theme.platform == TargetPlatform.macOS;
    final items = field.contextMenuButtonItems;
    if (items.isEmpty) return const SizedBox.shrink();

    final top = MediaQuery.paddingOf(context).top + _viewportInset;
    // Stay inside EditableText's composited overlay. A nested MenuAnchor
    // cannot resolve its transform there; Flutter still owns outside taps.
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _viewportInset,
        top,
        _viewportInset,
        _viewportInset,
      ),
      child: CustomSingleChildLayout(
        delegate: DesktopTextSelectionToolbarLayoutDelegate(
          anchor:
              field.contextMenuAnchors.primaryAnchor -
              Offset(_viewportInset, top),
        ),
        child: IntrinsicWidth(
          child: Material(
            color: theme.colorScheme.surfaceContainer,
            shape: theme.menuTheme.style!.shape!.resolve({}),
            elevation: _panelElevation,
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: _panelPadding,
              // A toolbar click must retain the field's selection and input
              // connection, as Flutter's desktop selection buttons do.
              child: ExcludeFocus(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final item in items)
                      MenuItemButton(
                        requestFocusOnHover: false,
                        onPressed: item.onPressed,
                        leadingIcon: switch (_selectionIcon(item.type)) {
                          final icon? => Icon(
                            icon,
                            color: theme.colorScheme.primary,
                          ),
                          null => null,
                        },
                        trailingIcon: switch (_selectionKey(item.type)) {
                          final key? => Text(
                            apple ? '⌘$key' : 'Ctrl+$key',
                            style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          null => null,
                        },
                        child: Text(
                          AdaptiveTextSelectionToolbar.getButtonLabel(
                            context,
                            item,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

IconData? _selectionIcon(ContextMenuButtonType type) => switch (type) {
  ContextMenuButtonType.cut => Icons.content_cut,
  ContextMenuButtonType.copy => Icons.copy,
  ContextMenuButtonType.paste => Icons.content_paste,
  ContextMenuButtonType.selectAll => Icons.select_all,
  _ => null,
};

String? _selectionKey(ContextMenuButtonType type) => switch (type) {
  ContextMenuButtonType.cut => 'X',
  ContextMenuButtonType.copy => 'C',
  ContextMenuButtonType.paste => 'V',
  ContextMenuButtonType.selectAll => 'A',
  _ => null,
};
