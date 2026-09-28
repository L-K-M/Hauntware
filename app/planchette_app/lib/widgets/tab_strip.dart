import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// What the strip shows for one document.
typedef TabStripItem = ({
  int id,
  String name,
  String tooltip,
  bool dirty,
  bool closable,

  /// Bumped when an open lands on this already open tab, which then pulses
  /// so the user can see where the open went.
  int flashRequest,
});

/// The window's single chrome row: document tabs with a new-tab button, and
/// the file actions at the trailing edge. The active tab joins the editor
/// surface below it and carries an accent; a dirty tab shows a dot where its
/// close button appears on hover. Middle-click closes a tab, a mouse wheel
/// scrolls the strip, and a newly active tab scrolls into view.
class TabStrip extends StatefulWidget {
  const TabStrip({
    super.key,
    required this.tabs,
    required this.activeId,
    required this.enabled,
    required this.busy,
    required this.onSelect,
    required this.onClose,
    required this.onNew,
    required this.onOpen,
    required this.onSave,
    required this.newTooltip,
    required this.openTooltip,
    required this.saveTooltip,
  });

  final List<TabStripItem> tabs;
  final int? activeId;
  final bool enabled;
  final bool busy;
  final void Function(int id) onSelect;
  final void Function(int id) onClose;
  final VoidCallback onNew;
  final VoidCallback onOpen;

  /// Null disables the Save button.
  final VoidCallback? onSave;
  final String newTooltip;
  final String openTooltip;
  final String saveTooltip;

  static const height = 38.0;

  @override
  State<TabStrip> createState() => _TabStripState();
}

class _TabStripState extends State<TabStrip> {
  final _scroll = ScrollController();
  final _keys = <int, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    _revealActiveAfterFrame();
  }

  @override
  void didUpdateWidget(TabStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ids = {for (final tab in widget.tabs) tab.id};
    _keys.removeWhere((id, _) => !ids.contains(id));
    if (oldWidget.activeId != widget.activeId ||
        oldWidget.tabs.length != widget.tabs.length ||
        _activeName(oldWidget) != _activeName(widget)) {
      _revealActiveAfterFrame();
    }
  }

  /// A renamed tab, after Save As, can grow past the strip's edge.
  static String? _activeName(TabStrip strip) {
    for (final tab in strip.tabs) {
      if (tab.id == strip.activeId) return tab.name;
    }
    return null;
  }

  double? _revealedWidth;
  TextScaler? _revealedScaler;

  /// Scrolls only as far as needed: past the trailing edge, then past the
  /// leading edge. Each call does nothing when the tab is already visible.
  void _revealActiveAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _keys[widget.activeId]?.currentContext;
      if (!mounted || context == null) return;
      for (final policy in const [
        ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      ]) {
        Scrollable.ensureVisible(context, alignmentPolicy: policy);
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // A narrower window or larger text can push the active tab out of view
      // without any change of selection.
      final scaler = MediaQuery.textScalerOf(context);
      if (constraints.maxWidth != _revealedWidth || scaler != _revealedScaler) {
        _revealedWidth = constraints.maxWidth;
        _revealedScaler = scaler;
        _revealActiveAfterFrame();
      }
      return _strip(context);
    },
  );

  Widget _strip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: SizedBox(
        height: TabStrip.height,
        child: Row(
          children: [
            Expanded(
              child: Listener(
                // A vertical wheel scrolls the horizontal strip. The resolver
                // hands each event to one handler, and the scroll view below
                // registers first whenever it scrolls itself (horizontal
                // swipes, Shift+wheel), so no delta is applied twice.
                onPointerSignal: (event) {
                  if (event is! PointerScrollEvent) return;
                  GestureBinding.instance.pointerSignalResolver.register(
                    event,
                    (event) {
                      final delta =
                          (event as PointerScrollEvent).scrollDelta.dy;
                      if (delta == 0 || !_scroll.hasClients) return;
                      final position = _scroll.position;
                      _scroll.jumpTo(
                        (position.pixels + delta).clamp(
                          position.minScrollExtent,
                          position.maxScrollExtent,
                        ),
                      );
                    },
                  );
                },
                child: SingleChildScrollView(
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(width: 6),
                      for (final tab in widget.tabs)
                        KeyedSubtree(
                          key: ValueKey('tab-${tab.id}'),
                          child: _Tab(
                            key: _keys.putIfAbsent(tab.id, GlobalKey.new),
                            item: tab,
                            active: tab.id == widget.activeId,
                            enabled: widget.enabled,
                            onSelect: () => widget.onSelect(tab.id),
                            onClose: () => widget.onClose(tab.id),
                          ),
                        ),
                      Center(
                        child: IconButton(
                          tooltip: widget.newTooltip,
                          visualDensity: VisualDensity.compact,
                          iconSize: 18,
                          onPressed: widget.enabled ? widget.onNew : null,
                          icon: const Icon(Icons.add),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (widget.busy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            IconButton(
              tooltip: widget.openTooltip,
              visualDensity: VisualDensity.compact,
              iconSize: 20,
              onPressed: widget.enabled ? widget.onOpen : null,
              icon: const Icon(Icons.folder_open_outlined),
            ),
            IconButton(
              tooltip: widget.saveTooltip,
              visualDensity: VisualDensity.compact,
              iconSize: 20,
              onPressed: widget.onSave,
              icon: const Icon(Icons.save_outlined),
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

class _Tab extends StatefulWidget {
  const _Tab({
    super.key,
    required this.item,
    required this.active,
    required this.enabled,
    required this.onSelect,
    required this.onClose,
  });

  final TabStripItem item;
  final bool active;
  final bool enabled;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  /// Long enough to notice between two glances, short enough not to linger.
  static const _flashDuration = Duration(milliseconds: 700);

  bool _flashing = false;

  /// The last flash request this tab reacted to. Initialised from the item,
  /// not lazily: a tab that mounts with an old request has nothing new to
  /// point at, and a lazy read inside didUpdateWidget would already see the
  /// new value and never flash.
  late int _seenFlash;
  Timer? _flashTimer;

  @override
  void initState() {
    super.initState();
    _seenFlash = widget.item.flashRequest;
  }

  @override
  void didUpdateWidget(_Tab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.item.flashRequest == _seenFlash) return;
    _seenFlash = widget.item.flashRequest;
    if (MediaQuery.disableAnimationsOf(context)) return;
    _flashTimer?.cancel();
    // No setState: this element builds right after didUpdateWidget, the frame
    // the pulse should first appear in. Only the timer needs a new frame.
    _flashing = true;
    _flashTimer = Timer(_flashDuration, () {
      if (mounted) setState(() => _flashing = false);
    });
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    super.dispose();
  }

  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final canClose = widget.enabled && item.closable;
    // A hovered or focused tab offers its close button, and so does a clean
    // active tab; otherwise a dirty tab, the active one included, shows a dot
    // in the same place, and a clean one shows nothing.
    final offerClose = _hovered || _focused || (widget.active && !item.dirty);
    final trailing = SizedBox.square(
      dimension: 24,
      child: offerClose
          ? IconButton(
              key: ValueKey('close-${item.id}'),
              tooltip: 'Close ${item.name}',
              padding: EdgeInsets.zero,
              iconSize: 14,
              onPressed: canClose ? widget.onClose : null,
              icon: const Icon(Icons.close),
            )
          : item.dirty
          ? Center(
              key: ValueKey('dirty-${item.id}'),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
            )
          : null,
    );
    // The tab is one button for assistive technology, labelled here; its
    // close button stays a separate node so it can be found and pressed.
    return Semantics(
      selected: widget.active,
      button: true,
      label: item.dirty ? '${item.name}, unsaved changes' : item.name,
      onTap: widget.enabled ? widget.onSelect : null,
      child: FocusableActionDetector(
        enabled: widget.enabled,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onSelect();
              return null;
            },
          ),
        },
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        child: Tooltip(
          message: item.tooltip,
          waitDuration: const Duration(milliseconds: 600),
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.enabled ? widget.onSelect : null,
              // A middle click closes on release, like any click.
              onTertiaryTapUp: canClose ? (_) => widget.onClose() : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                constraints: const BoxConstraints(minWidth: 96, maxWidth: 220),
                padding: const EdgeInsets.only(left: 12, right: 4),
                decoration: BoxDecoration(
                  color: _flashing
                      ? scheme.secondaryContainer
                      : widget.active
                      ? scheme.surface
                      : _hovered
                      ? scheme.surfaceContainerHighest
                      : Colors.transparent,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(8),
                  ),
                  border: Border(
                    top: BorderSide(
                      width: 2,
                      color: widget.active
                          ? scheme.primary
                          : Colors.transparent,
                    ),
                  ),
                ),
                foregroundDecoration: _focused
                    ? BoxDecoration(
                        border: Border.all(color: scheme.primary, width: 2),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(8),
                        ),
                      )
                    : null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      // Announced through the tab's own label above.
                      child: ExcludeSemantics(
                        child: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 13,
                            fontWeight: widget.active
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: widget.active
                                ? scheme.onSurface
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    trailing,
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
