import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/app_lock_controller.dart';
import '../l10n/app_localizations.dart';

/// The app lock's screen (SAF-20) over everything [child] draws, the
/// routes and their dialogs included, while [lock] is locked. The covered
/// app stays mounted, so links and views keep their state, but it takes
/// no pointer, focus or semantics and its tickers stop.
///
/// It asks for device authentication by itself once each time the lock
/// engages while the app is in the foreground, at launch included;
/// "Unlock" asks again. The gate also reports the app's lifecycle to
/// [lock], which locks after its background timeout.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.lock, required this.child});

  final AppLockController lock;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> {
  late final AppLifecycleListener _lifecycle;

  /// Whether this locked spell already asked by itself.
  bool _asked = false;

  /// The last attempt's outcome while still locked; null before one.
  AppLockUnlock? _outcome;

  bool _unlocking = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    widget.lock.addListener(_onLock);
    unawaited(widget.lock.refreshAvailability());
    _askOnce();
  }

  @override
  void didUpdateWidget(AppLockGate old) {
    super.didUpdateWidget(old);
    if (old.lock == widget.lock) return;
    old.lock.removeListener(_onLock);
    widget.lock.addListener(_onLock);
    // The asking is per controller: a new one starts its own spell.
    _asked = false;
    _outcome = null;
    _askOnce();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    widget.lock.removeListener(_onLock);
    super.dispose();
  }

  void _onLifecycle(AppLifecycleState state) {
    widget.lock.onLifecycle(state);
    if (state == AppLifecycleState.resumed) _askOnce();
  }

  void _onLock() {
    if (!widget.lock.locked) {
      _asked = false;
      _outcome = null;
    }
    if (mounted) setState(() {});
    _askOnce();
  }

  /// Asks after this frame, once per locked spell, and only while the app
  /// is in the foreground: the system prompt cannot show otherwise.
  void _askOnce() {
    if (_asked || !widget.lock.locked) return;
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) return;
    _asked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_unlock()));
  }

  Future<void> _unlock() async {
    if (_unlocking || !mounted) return;
    setState(() => _unlocking = true);
    final outcome = await widget.lock.unlock();
    if (!mounted) return;
    setState(() {
      _unlocking = false;
      _outcome = outcome == AppLockUnlock.unlocked ? null : outcome;
    });
  }

  @override
  Widget build(BuildContext context) {
    final locked = widget.lock.locked;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Nothing beneath reaches the user or takes input: no pointer,
        // no focus (so no keys), no semantics, no animation.
        IgnorePointer(
          ignoring: locked,
          child: ExcludeFocus(
            excluding: locked,
            child: ExcludeSemantics(
              excluding: locked,
              child: TickerMode(enabled: !locked, child: widget.child),
            ),
          ),
        ),
        if (locked)
          AppLockScreen(
            outcome: _outcome,
            unlocking: _unlocking,
            onUnlock: () => unawaited(_unlock()),
          ),
      ],
    );
  }
}

/// What the locked app shows: why, and "Unlock". [outcome] is the last
/// attempt's failure, if any.
class AppLockScreen extends StatelessWidget {
  const AppLockScreen({
    super.key,
    required this.outcome,
    required this.unlocking,
    required this.onUnlock,
  });

  final AppLockUnlock? outcome;
  final bool unlocking;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final problem = switch (outcome) {
      AppLockUnlock.failed => l10n.appLockFailed,
      AppLockUnlock.unavailable => l10n.appLockUnavailable,
      AppLockUnlock.unlocked || null => null,
    };
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 16,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 48,
                    color: theme.colorScheme.primary,
                  ),
                  Semantics(
                    header: true,
                    child: Text(
                      l10n.appLockTitle,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                  Text(
                    l10n.appLockDetail,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (problem != null)
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        problem,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  FilledButton.icon(
                    autofocus: true,
                    onPressed: unlocking ? null : onUnlock,
                    icon: const Icon(Icons.fingerprint),
                    label: Text(l10n.appLockUnlock),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
