// Extracted from Séance app/seance_app/lib/ui/top_toast.dart (@ 2e6d1f1) —
// Poltergeist's lib/ui/top_toast.dart is its port, identical but for
// comments.
import 'dart:async';

import 'package:flutter/material.dart';

/// How a top toast leaves the screen.
///
/// [automatic] preserves the original timed behavior. [persistent] notices
/// stay until their action is invoked or the user presses their close button.
enum TopToastDismissal { automatic, persistent }

/// Transient notices anchored to the TOP of the window. The Ghost apps
/// never use bottom SnackBars: the thing the user is watching — the panes,
/// the activity panel, the status bar — sits at the bottom of the screen,
/// and a bottom banner would cover it (02 §10).
///
/// Concurrent toasts stack downward instead of overlapping. Automatic toasts
/// dismiss after [duration]; persistent ones expose an explicit close button.
///
/// Pass the root [OverlayState] (capture it with `Overlay.of(context,
/// rootOverlay: true)` before closing any dialog) so the toast outlives the
/// widget that triggered it.
///
/// Identical actionless notices coalesce automatically. Supply a stable
/// [coalesceKey] to coalesce actionable notices intentionally; callbacks are
/// otherwise always kept distinct.
void showTopToast(
  OverlayState overlay, {
  required String message,
  Color? background,
  Duration duration = const Duration(seconds: 4),
  String? actionLabel,
  VoidCallback? onAction,
  TopToastDismissal dismissal = TopToastDismissal.automatic,
  String? coalesceKey,
}) {
  _ToastStack.of(overlay).add(
    _ToastData(
      message: message,
      background: background,
      duration: duration,
      actionLabel: actionLabel,
      onAction: onAction,
      dismissal: dismissal,
      coalesceKey: coalesceKey,
    ),
  );
}

/// Convenience wrapper for call sites that have a [BuildContext]: resolves the
/// root overlay so the toast survives the closing of dialogs and routes.
void showTopToastIn(
  BuildContext context, {
  required String message,
  Color? background,
  Duration duration = const Duration(seconds: 4),
  String? actionLabel,
  VoidCallback? onAction,
  TopToastDismissal dismissal = TopToastDismissal.automatic,
  String? coalesceKey,
}) {
  if (!context.mounted) return;
  showTopToast(
    Overlay.of(context, rootOverlay: true),
    message: message,
    background: background,
    duration: duration,
    actionLabel: actionLabel,
    onAction: onAction,
    dismissal: dismissal,
    coalesceKey: coalesceKey,
  );
}

class _ToastData {
  final String message;
  final Color? background;
  final Duration duration;
  final String? actionLabel;
  final VoidCallback? onAction;
  final TopToastDismissal dismissal;
  final String? coalesceKey;

  const _ToastData({
    required this.message,
    this.background,
    required this.duration,
    this.actionLabel,
    this.onAction,
    required this.dismissal,
    this.coalesceKey,
  });

  bool get hasAction => actionLabel != null || onAction != null;

  bool canCoalesceWith(_ToastData other) {
    final key = coalesceKey;
    if (key != null || other.coalesceKey != null) {
      return key != null && key == other.coalesceKey;
    }
    if (hasAction || other.hasAction) return false;
    return message == other.message &&
        background == other.background &&
        duration == other.duration &&
        dismissal == other.dismissal;
  }
}

class _ToastRecord {
  final int id;
  _ToastData data;
  int repetitions = 1;
  int revision = 0;
  bool dismissing = false;

  _ToastRecord(this.id, this.data);

  void coalesce(_ToastData replacement) {
    data = replacement;
    repetitions += 1;
    revision += 1;
  }
}

/// A deliberately callback-free copy of a notice which could not be shown.
/// Keeping this separate from [_ToastRecord] prevents expired actions from
/// retaining application state or appearing usable in history.
class _ToastHistoryItem {
  final int recordId;
  final _ToastData identity;
  final bool hadAction;
  final String message;
  final int repetitions;

  const _ToastHistoryItem({
    required this.recordId,
    required this.identity,
    required this.hadAction,
    required this.message,
    this.repetitions = 1,
  });

  _ToastHistoryItem incremented(_ToastData replacement) => _ToastHistoryItem(
    recordId: recordId,
    identity: _withoutAction(replacement),
    hadAction: replacement.hasAction,
    message: replacement.message,
    repetitions: repetitions + 1,
  );

  static _ToastData _withoutAction(_ToastData toast) => _ToastData(
    message: toast.message,
    background: toast.background,
    duration: toast.duration,
    dismissal: toast.dismissal,
    coalesceKey: toast.coalesceKey,
  );
}

/// One overlay entry per [OverlayState] holding a column of active toasts, so
/// simultaneous notices never paint on top of each other.
class _ToastStack {
  static const int _maximumVisible = 3;
  static const int _maximumPending = 20;
  static const int _maximumHistory = 50;
  static final Expando<_ToastStack> _stacks = Expando<_ToastStack>();

  static _ToastStack of(OverlayState overlay) =>
      _stacks[overlay] ??= _ToastStack(overlay);

  final OverlayState overlay;
  final List<_ToastRecord> _visible = [];
  final List<_ToastRecord> _pending = [];
  final List<_ToastHistoryItem> _history = [];
  int _nextId = 0;
  OverlayEntry? _entry;

  _ToastStack(this.overlay);

  void add(_ToastData toast) {
    // A toast for a dying overlay would never display; don't retain it (its
    // onAction closure can hold onto real state).
    if (!overlay.mounted) return;
    final existing = _findCoalescible(toast);
    if (existing != null) {
      existing.coalesce(toast);
      _updateHistory(existing);
      _entry?.markNeedsBuild();
      return;
    }

    final historyOnly = _findHistoryCoalescible(toast);
    if (historyOnly != null) {
      final index = _history.indexOf(historyOnly);
      _history[index] = historyOnly.incremented(toast);
      _entry?.markNeedsBuild();
      return;
    }

    final record = _ToastRecord(_nextId++, toast);
    if (_visible.length < _maximumVisible) {
      _visible.add(record);
    } else if (_requiresDelivery(toast)) {
      final replaceable = _visible.indexWhere(
        (candidate) => !_requiresDelivery(candidate.data),
      );
      if (replaceable >= 0) {
        _remember(_visible.removeAt(replaceable));
        _visible.add(record);
      } else if (_pending.length < _maximumPending) {
        _pending.add(record);
        _remember(record);
      } else {
        _remember(record);
      }
    } else {
      _remember(record);
    }

    if (_entry == null) {
      final entry = OverlayEntry(
        builder: (context) => _ToastColumn(
          toasts: [
            for (final record in _visible)
              _ToastPresentation.fromRecord(record),
          ],
          history: List.of(_history),
          onDismissStarted: _dismissStarted,
          onDismiss: remove,
        ),
      );
      _entry = entry;
      overlay.insert(entry);
    } else {
      _entry?.markNeedsBuild();
    }
  }

  _ToastRecord? _findCoalescible(_ToastData toast) {
    for (final record in [..._visible, ..._pending]) {
      if (!record.dismissing && record.data.canCoalesceWith(toast)) {
        return record;
      }
    }
    return null;
  }

  _ToastHistoryItem? _findHistoryCoalescible(_ToastData toast) {
    for (final item in _history.reversed) {
      final explicitKey = item.identity.coalesceKey;
      if (explicitKey != null || toast.coalesceKey != null) {
        if (explicitKey != null && explicitKey == toast.coalesceKey) {
          return item;
        }
        continue;
      }
      if (!item.hadAction &&
          !toast.hasAction &&
          item.identity.canCoalesceWith(toast)) {
        return item;
      }
    }
    return null;
  }

  static bool _requiresDelivery(_ToastData toast) =>
      toast.dismissal == TopToastDismissal.persistent || toast.hasAction;

  void _remember(_ToastRecord record) {
    _history.add(
      _ToastHistoryItem(
        recordId: record.id,
        identity: _ToastHistoryItem._withoutAction(record.data),
        hadAction: record.data.hasAction,
        message: record.data.message,
        repetitions: record.repetitions,
      ),
    );
    if (_history.length > _maximumHistory) {
      final pendingIds = _pending.map((record) => record.id).toSet();
      final removable = _history.indexWhere(
        (item) => !pendingIds.contains(item.recordId),
      );
      _history.removeAt(removable < 0 ? 0 : removable);
    }
  }

  void _updateHistory(_ToastRecord record) {
    final index = _history.indexWhere((item) => item.recordId == record.id);
    if (index < 0) return;
    final old = _history[index];
    _history[index] = _ToastHistoryItem(
      recordId: record.id,
      identity: _ToastHistoryItem._withoutAction(record.data),
      hadAction: record.data.hasAction,
      message: record.data.message,
      repetitions: old.repetitions + 1,
    );
  }

  void _dismissStarted(int id) {
    for (final record in _visible) {
      if (record.id == id) {
        record.dismissing = true;
        return;
      }
    }
  }

  void remove(int id) {
    final index = _visible.indexWhere((record) => record.id == id);
    if (index < 0) return;
    _visible.removeAt(index);
    if (_pending.isNotEmpty) {
      final promoted = _pending.removeAt(0);
      _history.removeWhere((item) => item.recordId == promoted.id);
      _visible.add(promoted);
    }
    if (_visible.isEmpty) {
      _pending.clear();
      _history.clear();
      final entry = _entry;
      _entry = null;
      if (entry != null) {
        if (entry.mounted) entry.remove();
        entry.dispose();
      }
    } else {
      _entry?.markNeedsBuild();
    }
  }
}

class _ToastColumn extends StatelessWidget {
  final List<_ToastPresentation> toasts;
  final List<_ToastHistoryItem> history;
  final void Function(int) onDismissStarted;
  final void Function(int) onDismiss;

  const _ToastColumn({
    required this.toasts,
    required this.history,
    required this.onDismissStarted,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final hiddenCount = history.fold<int>(
      0,
      (total, item) => total + item.repetitions,
    );
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.5,
          ),
          child: SingleChildScrollView(
            hitTestBehavior: HitTestBehavior.deferToChild,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final toast in toasts)
                  _TopToast(
                    key: ValueKey(toast.id),
                    toast: toast,
                    onDismissStarted: () => onDismissStarted(toast.id),
                    onDismiss: () => onDismiss(toast.id),
                  ),
                if (hiddenCount > 0)
                  _ToastHistoryButton(history: history, count: hiddenCount),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToastPresentation {
  final int id;
  final _ToastData data;
  final int repetitions;
  final int revision;

  const _ToastPresentation({
    required this.id,
    required this.data,
    required this.repetitions,
    required this.revision,
  });

  factory _ToastPresentation.fromRecord(_ToastRecord record) =>
      _ToastPresentation(
        id: record.id,
        data: record.data,
        repetitions: record.repetitions,
        revision: record.revision,
      );
}

class _ToastHistoryButton extends StatelessWidget {
  final List<_ToastHistoryItem> history;
  final int count;

  const _ToastHistoryButton({required this.history, required this.count});

  @override
  Widget build(BuildContext context) {
    final moreLabel = MaterialLocalizations.of(context).moreButtonTooltip;
    return Semantics(
      button: true,
      label: '$moreLabel, $count',
      child: ExcludeSemantics(
        child: TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (context) => _ToastHistoryDialog(history: history),
          ),
          child: Text('+$count'),
        ),
      ),
    );
  }
}

class _ToastHistoryDialog extends StatelessWidget {
  final List<_ToastHistoryItem> history;

  const _ToastHistoryDialog({required this.history});

  @override
  Widget build(BuildContext context) {
    final maximumHeight = MediaQuery.sizeOf(context).height * 0.6;
    final desiredHeight = 56.0 + history.length * 72.0;
    final height = desiredHeight < maximumHeight
        ? desiredHeight
        : maximumHeight;
    return AlertDialog(
      content: SizedBox(
        width: 560,
        height: height,
        child: Column(
          children: [
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final item in history)
                    ListTile(
                      title: Text(item.message),
                      trailing: item.repetitions > 1
                          ? Text('×${item.repetitions}')
                          : null,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopToast extends StatefulWidget {
  final _ToastPresentation toast;
  final VoidCallback onDismissStarted;
  final VoidCallback onDismiss;
  const _TopToast({
    super.key,
    required this.toast,
    required this.onDismissStarted,
    required this.onDismiss,
  });

  @override
  State<_TopToast> createState() => _TopToastState();
}

class _TopToastState extends State<_TopToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..forward();

  // Owned by the widget state so tree teardown cancels it; a bare
  // Future.delayed would trip widget tests over a pending timer.
  Timer? _dismissTimer;
  final Stopwatch _timerElapsed = Stopwatch();
  late Duration _remaining;
  bool _dismissing = false;
  bool _hovered = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _resetLifetime();
  }

  @override
  void didUpdateWidget(_TopToast oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.toast.revision != oldWidget.toast.revision) _resetLifetime();
  }

  bool get _paused => _hovered || _focused;

  void _resetLifetime() {
    _dismissTimer?.cancel();
    _timerElapsed
      ..stop()
      ..reset();
    _remaining = widget.toast.data.duration;
    _resumeLifetime();
  }

  void _pauseLifetime() {
    if (!_timerElapsed.isRunning) return;
    _dismissTimer?.cancel();
    _timerElapsed.stop();
    _remaining -= _timerElapsed.elapsed;
    if (_remaining.isNegative) _remaining = Duration.zero;
    _timerElapsed.reset();
  }

  void _resumeLifetime() {
    if (_dismissing ||
        _paused ||
        widget.toast.data.dismissal == TopToastDismissal.persistent) {
      return;
    }
    _timerElapsed
      ..reset()
      ..start();
    _dismissTimer = Timer(_remaining, _dismiss);
  }

  void _setHovered(bool value) {
    if (_hovered == value) return;
    if (!_paused) _pauseLifetime();
    _hovered = value;
    if (!_paused) _resumeLifetime();
  }

  void _setFocused(bool value) {
    if (_focused == value) return;
    if (!_paused) _pauseLifetime();
    _focused = value;
    if (!_paused) _resumeLifetime();
  }

  /// Fade the card back out before removing it — the entrance animates, and
  /// a toast vanishing instantly from under a tap reads as a glitch.
  void _dismiss() {
    if (_dismissing) return;
    _dismissing = true;
    widget.onDismissStarted();
    _dismissTimer?.cancel();
    _timerElapsed.stop();
    _anim.reverse().whenCompleteOrCancel(() {
      // Skip the removal when the tree is already tearing down (the cancel
      // path); the stack dies with its overlay.
      if (mounted) widget.onDismiss();
    });
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _timerElapsed.stop();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final toast = widget.toast.data;
    final scheme = Theme.of(context).colorScheme;
    final bg = toast.background ?? scheme.inverseSurface;
    final fg = toast.background != null
        ? Colors.white
        : scheme.onInverseSurface;
    final accent = toast.background != null
        ? Colors.white
        : scheme.inversePrimary;
    final message = Flexible(
      child: ExcludeSemantics(
        child: Text(toast.message, style: TextStyle(color: fg)),
      ),
    );
    final controls = <Widget>[
      if (widget.toast.repetitions > 1)
        ExcludeSemantics(
          child: Text(
            '×${widget.toast.repetitions}',
            style: TextStyle(color: fg),
          ),
        ),
      if (toast.actionLabel != null)
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: accent,
            visualDensity: VisualDensity.compact,
          ),
          onPressed: () {
            if (_dismissing) return;
            try {
              toast.onAction?.call();
            } finally {
              _dismiss();
            }
          },
          child: Text(toast.actionLabel!),
        ),
      if (toast.dismissal == TopToastDismissal.persistent)
        IconButton(
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          color: accent,
          visualDensity: VisualDensity.compact,
          onPressed: _dismiss,
          icon: const Icon(Icons.close),
        ),
    ];
    final content = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 360) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ExcludeSemantics(
                    child: Text(toast.message, style: TextStyle(color: fg)),
                  ),
                  if (controls.isNotEmpty)
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: controls,
                      ),
                    ),
                ],
              );
            }
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                message,
                if (controls.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  ...controls,
                ],
              ],
            );
          },
        ),
      ),
    );
    return FadeTransition(
      opacity: _anim,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, -0.25),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut)),
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: MouseRegion(
              onEnter: (_) => _setHovered(true),
              onExit: (_) => _setHovered(false),
              child: Focus(
                onFocusChange: _setFocused,
                child: Semantics(
                  container: true,
                  liveRegion: true,
                  label: toast.message,
                  child: Material(
                    color: bg,
                    elevation: 6,
                    borderRadius: BorderRadius.circular(8),
                    child: toast.dismissal == TopToastDismissal.automatic
                        ? InkWell(
                            excludeFromSemantics: true,
                            borderRadius: BorderRadius.circular(8),
                            onTap: _dismiss,
                            child: content,
                          )
                        : content,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
